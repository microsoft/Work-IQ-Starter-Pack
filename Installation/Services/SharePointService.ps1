$script:SharePointContentGroup = "WorkIQ Starter Pack"
function Get-ContentTypeDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        $ContentType
    )

    if ($ContentType.DisplayName) { return $ContentType.DisplayName }
    return $ContentType.InternalName
}
function Add-SiteListsAndLibraries {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $lists = @($Site.Content.Lists | Where-Object { $_ })
    $libraries = @($Site.Content.Libraries | Where-Object { $_ })
    if ($lists.Count -eq 0 -and $libraries.Count -eq 0) {
        return
    }

    try {
        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($Site.URL)"
        $connection = Connect-PnPOnline -Url $siteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection
        Write-InstallLogAction -Message "Provisioning lists and libraries for site '$($Site.URL)'."

        Add-SiteTermSets -Connection $connection -Site $Site -Lists $lists -Libraries $libraries
        Add-SiteColumns -Connection $connection -Site $Site -Lists $lists -Libraries $libraries
        Add-SiteContentTypes -Connection $connection -Site $Site -Lists $lists -Libraries $libraries

        # Tabs go in the channel created from content.json (first channel, else General).
        $tabTarget = $null
        if ($Site.EnableMicrosoftTeams) {
            try {
                $teamId = (Invoke-RestMethod -Uri "$graphBaseUrl/groups?`$filter=mailNickname eq '$($Site.URL)'&`$select=id" -Headers $headers -Method Get).value | Select-Object -First 1 -ExpandProperty id
                $channelName = if ($Site.Channels -and $Site.Channels[0].Title) { $Site.Channels[0].Title } else { "General" }
                $tabTarget = @{ TeamId = $teamId; ChannelId = (Get-TeamChannelId -TeamId $teamId -ChannelName $channelName) }
            }
            catch {
                Write-InstallLogAction -Message "Could not resolve channel for tabs on site '$($Site.URL)': $($_.Exception.Message)" -Level Warning
            }
        }
        $tabHost = "https://$($Config.Settings.TenantPrefix).sharepoint.com"

        foreach ($list in $lists) {
            try {
                $pnpList = Add-SiteList -Connection $connection -Site $Site -Definition $list
                Add-ListColumns -Connection $connection -Site $Site -List $pnpList -Definition $list
                Add-ListContentTypes -Connection $connection -Site $Site -List $pnpList -Definition $list
                Add-ListViews -Connection $connection -Site $Site -List $pnpList -Definition $list
                Add-ListItems -Connection $connection -Site $Site -List $pnpList -Definition $list
                if ($tabTarget) {
                    $listUrl = $tabHost + (Get-PnPProperty -ClientObject $pnpList -Property RootFolder -Connection $connection).ServerRelativeUrl
                    Add-ChannelTab -TeamId $tabTarget.TeamId -ChannelId $tabTarget.ChannelId -DisplayName $list.Title -WebUrl $listUrl -Kind List -SiteUrl $siteUrl
                }
            }
            catch {
                Write-InstallLogAction -Message "Failed to provision list '$($list.Title)' on site '$($Site.URL)': $($_.Exception.Message)" -Level Error
            }
        }

        foreach ($library in $libraries) {
            try {
                $pnpLibrary = Add-SiteList -Connection $connection -Site $Site -Definition $library
                Add-ListColumns -Connection $connection -Site $Site -List $pnpLibrary -Definition $library
                Add-ListContentTypes -Connection $connection -Site $Site -List $pnpLibrary -Definition $library
                Add-ListViews -Connection $connection -Site $Site -List $pnpLibrary -Definition $library
                Add-LibraryDocuments -Connection $connection -Site $Site -Library $pnpLibrary -Definition $library
                if ($tabTarget) {
                    $libraryUrl = $tabHost + (Get-PnPProperty -ClientObject $pnpLibrary -Property RootFolder -Connection $connection).ServerRelativeUrl
                    Add-ChannelTab -TeamId $tabTarget.TeamId -ChannelId $tabTarget.ChannelId -DisplayName $library.Title -WebUrl $libraryUrl -Kind Library -SiteUrl $siteUrl
                }
            }
            catch {
                Write-InstallLogAction -Message "Failed to provision library '$($library.Title)' on site '$($Site.URL)': $($_.Exception.Message)" -Level Error
            }
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to provision lists and libraries for site '$($Site.URL)': $($_.Exception.Message)" -Level Error
    }
}
function Get-SiteColumnDefinitions {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Lists,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Libraries
    )

    $columns = [ordered]@{}
    foreach ($definition in @($Lists) + @($Libraries)) {
        $candidates = @($definition.Columns) + @($definition.ContentTypes | ForEach-Object { $_.Columns })
        foreach ($column in ($candidates | Where-Object { $_ })) {
            if (-not $columns.Contains($column.InternalName)) {
                $columns[$column.InternalName] = $column
            }
            elseif ($columns[$column.InternalName].Type -ne $column.Type) {
                Write-InstallLogAction -Message "Column '$($column.InternalName)' is defined as both '$($columns[$column.InternalName].Type)' and '$($column.Type)' on site '$($Site.URL)'; keeping '$($columns[$column.InternalName].Type)'." -Level Warning
            }
        }
    }

    return $columns.Values
}

function Confirm-TermStoreAdministrator {
    param(
        [Parameter(Mandatory = $true)]
        $Connection
    )

    # The term store is tenant-wide, so only check once per install run
    # if ($script:TermStoreAdminChecked) {
    #     return
    # }
    # $script:TermStoreAdminChecked = $true

    $upn = Get-CurrentUserUpn

    try {
        $loginName = "i:0#.f|membership|$upn"

        $siteUrl = $Connection.Url.TrimEnd('/')
        # Default resource is Graph; the termStore endpoint needs a token for the SharePoint host
        $token = Get-PnPAccessToken -ResourceTypeName SharePoint -Connection $Connection
        $headers = @{ Authorization = "Bearer $token"; Accept = "application/json" }

        $current = Invoke-RestMethod -Method Get -Uri "$siteUrl/_api/v2.1/termStore?select=administrators" -Headers $headers
        $admins = @($current.administrators)

        $isAdmin = @($admins | Where-Object { $_.user.userPrincipalName -ieq $loginName }).Count -gt 0
        if ($isAdmin) {
            Write-InstallLogAction -Message "$upn is already a Term Store Administrator."
            return
        }

        # PATCH replaces the administrators list, so send the existing admins plus the new one
        $admins += @{
            user = @{
                email             = $upn
                userPrincipalName = $loginName
                displayName       = $upn
            }
        }
        $body = @{ administrators = $admins } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Method Patch -Uri "$siteUrl/_api/v2.1/termStore?select=*,administrators" -Headers $headers -ContentType "application/json" -Body $body | Out-Null
        Write-InstallLogAction -Message "Added $upn as a Term Store Administrator."
    }
    catch {
        $detail = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
        Write-InstallLogAction -Message "Failed to verify or add $upn as a Term Store Administrator: $detail" -Level Warning
    }
}

function Add-SiteTermSets {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Lists,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Libraries
    )

    $taxonomyColumns = Get-SiteColumnDefinitions -Site $Site -Lists $Lists -Libraries $Libraries |
        Where-Object { $_.Type -eq "TaxonomyFieldType" -and $_.TermSet }
    if (-not $taxonomyColumns) {
        return
    }

    Confirm-TermStoreAdministrator -Connection $Connection

    $groupName = $script:SharePointContentGroup
    try {
        $termGroup = Get-PnPTermGroup -Identity $groupName -Connection $Connection -ErrorAction SilentlyContinue
        if (-not $termGroup) {
            $termGroup = New-PnPTermGroup -Name $groupName -Connection $Connection
            Write-InstallLogAction -Message "Created term group '$groupName'."
        }
        else {
            Write-InstallLogAction -Message "Term group '$groupName' already exists, skipping creation."
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to ensure term group '$groupName': $($_.Exception.Message)" -Level Error
        return
    }

    foreach ($column in $taxonomyColumns) {
        try {
            $termSet = Get-PnPTermSet -Identity $column.TermSet -TermGroup $groupName -Connection $Connection -ErrorAction SilentlyContinue
            if (-not $termSet) {
                $termSet = New-PnPTermSet -Name $column.TermSet -TermGroup $groupName -Owner (Get-CurrentUserUpn) -Connection $Connection
                Write-InstallLogAction -Message "Created term set '$($column.TermSet)'."
            }
            else {
                Write-InstallLogAction -Message "Term set '$($column.TermSet)' already exists, skipping creation."
            }

            # Give the term store a moment to propagate the new term group/set before adding terms.
            Start-Sleep -Seconds 30
            $existingTerms = @(Get-PnPTerm -TermSet $column.TermSet -TermGroup $groupName -Connection $Connection -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            foreach ($termName in @($column.Terms | Where-Object { $_ })) {
                if ($existingTerms -contains $termName) {
                    continue
                }
                New-PnPTerm -Name $termName -TermSet $termSet.Id -TermGroup $termGroup.Id -Connection $Connection | Out-Null
                Write-InstallLogAction -Message "Added term '$termName' to term set '$($column.TermSet)'."
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to provision term set '$($column.TermSet)': $($_.Exception.Message)" -Level Error
        }
    }
}

function Remove-SiteTermGroup {
    $groupName = $script:SharePointContentGroup
    try {
        $termGroup = Get-PnPTermGroup -Identity $groupName -ErrorAction SilentlyContinue
        if (-not $termGroup) {
            Write-InstallLogAction -Message "Term group '$groupName' does not exist, skipping deletion."
            return
        }

        # Remove-PnPTermGroup only works on empty groups, so delete the term sets first.
        foreach ($termSet in @(Get-PnPTermSet -TermGroup $groupName -ErrorAction SilentlyContinue)) {
            Remove-PnPTermSet -Identity $termSet.Id -TermGroup $groupName -Force
            Write-InstallLogAction -Message "Removed term set '$($termSet.Name)'."
        }

        Remove-PnPTermGroup -Identity $groupName -Force
        Write-InstallLogAction -Message "Removed term group '$groupName'."
    }
    catch {
        Write-InstallLogAction -Message "Failed to remove term group '$groupName': $($_.Exception.Message)" -Level Warning
    }
}

function Add-SiteColumns {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Lists,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Libraries
    )

    foreach ($column in (Get-SiteColumnDefinitions -Site $Site -Lists $Lists -Libraries $Libraries)) {
        try {
            $existingField = Get-PnPField -Identity $column.InternalName -Connection $Connection -ErrorAction SilentlyContinue
            if ($existingField) {
                Write-InstallLogAction -Message "Site column '$($column.InternalName)' already exists on site '$($Site.URL)', skipping creation."
                continue
            }

            $displayName = if ($column.DisplayName) { $column.DisplayName } else { $column.InternalName }
            Write-InstallLogAction -Message "Creating site column '$displayName' with internal name '$($column.InternalName)'."

            if ($column.Type -eq "TaxonomyFieldType") {
                Add-PnPTaxonomyField -DisplayName $displayName -InternalName $column.InternalName `
                    -TermSetPath "$($script:SharePointContentGroup)|$($column.TermSet)" `
                    -Group $script:SharePointContentGroup -Connection $Connection | Out-Null
            }
            else {
                $fieldParams = @{
                    DisplayName  = $displayName
                    InternalName = $column.InternalName
                    Type         = $column.Type
                    Group        = $script:SharePointContentGroup
                    Connection   = $Connection
                }
                if ($column.Type -eq "Choice" -and $column.Choices) {
                    $fieldParams.Choices = @($column.Choices)
                }
                Add-PnPField @fieldParams | Out-Null
            }

            Write-InstallLogAction -Message "Created site column '$($column.InternalName)' ($($column.Type)) on site '$($Site.URL)'."
        }
        catch {
            Write-InstallLogAction -Message "Failed to create site column '$($column.InternalName)' on site '$($Site.URL)': $($_.Exception.Message)" -Level Error
        }
    }
}

function Add-SiteContentTypes {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Lists,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Libraries
    )

    $contentTypes = [ordered]@{}
    foreach ($definition in @($Lists) + @($Libraries)) {
        $parentName = if ($definition.Template -eq "DocumentLibrary") { "Document" } else { "Item" }
        foreach ($contentType in @($definition.ContentTypes | Where-Object { $_ })) {
            if (-not $contentTypes.Contains($contentType.InternalName)) {
                $contentTypes[$contentType.InternalName] = [PSCustomObject]@{ Definition = $contentType; Parent = $parentName }
            }
        }
    }

    foreach ($entry in $contentTypes.Values) {
        $contentTypeName = Get-ContentTypeDisplayName -ContentType $entry.Definition
        try {
            $siteContentType = Get-PnPContentType -Identity $contentTypeName -Connection $Connection -ErrorAction SilentlyContinue
            if ($siteContentType) {
                Write-InstallLogAction -Message "Site content type '$contentTypeName' already exists on site '$($Site.URL)', skipping creation."
            }
            else {
                $parentContentType = Get-PnPContentType -Identity $entry.Parent -Connection $Connection
                $siteContentType = Add-PnPContentType -Name $contentTypeName -ParentContentType $parentContentType `
                    -Group $script:SharePointContentGroup -Connection $Connection
                Write-InstallLogAction -Message "Created site content type '$contentTypeName' (key '$($entry.Definition.InternalName)') on site '$($Site.URL)'."
            }

            $existingFieldNames = @(Get-PnPProperty -ClientObject $siteContentType -Property Fields -Connection $Connection | ForEach-Object { $_.InternalName })
            foreach ($column in @($entry.Definition.Columns | Where-Object { $_ })) {
                if ($existingFieldNames -contains $column.InternalName) {
                    continue
                }
                Add-PnPFieldToContentType -Field $column.InternalName -ContentType $contentTypeName -Connection $Connection
                Write-InstallLogAction -Message "Added column '$($column.InternalName)' to site content type '$contentTypeName'."
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to provision site content type '$contentTypeName' on site '$($Site.URL)': $($_.Exception.Message)" -Level Error
        }
    }
}

function Add-SiteList {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    $list = Get-PnPList -Identity $Definition.Title -Connection $Connection -ErrorAction SilentlyContinue
    if ($list) {
        Write-InstallLogAction -Message "'$($Definition.Title)' already exists on site '$($Site.URL)', skipping creation."
    }
    else {
        $list = New-PnPList -Title $Definition.Title -Template $Definition.Template -Connection $Connection
        Write-InstallLogAction -Message "Created $($Definition.Template) '$($Definition.Title)' on site '$($Site.URL)'."
    }

    # Content types must be enabled on the list before any can be attached to it.
    if (@($Definition.ContentTypes | Where-Object { $_ }).Count -gt 0 -and -not $list.ContentTypesEnabled) {
        Set-PnPList -Identity $list -EnableContentTypes $true -Connection $Connection | Out-Null
        Write-InstallLogAction -Message "Enabled content types on '$($Definition.Title)'."
    }

    return $list
}

# Columns that sit directly on a list (rather than in a content type) are added by reference
# to the site column, so a list never gets its own copy of a column definition.
function Add-ListColumns {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $List,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    foreach ($column in @($Definition.Columns | Where-Object { $_ })) {
        try {
            $existingField = Get-PnPField -List $List -Identity $column.InternalName -Connection $Connection -ErrorAction SilentlyContinue
            if ($existingField) {
                Write-InstallLogAction -Message "Column '$($column.InternalName)' already exists on '$($Definition.Title)', skipping."
                continue
            }

            Add-PnPField -List $List -Field $column.InternalName -AddToDefaultView -Connection $Connection | Out-Null
            Write-InstallLogAction -Message "Added column '$($column.InternalName)' to '$($Definition.Title)'."
        }
        catch {
            Write-InstallLogAction -Message "Failed to add column '$($column.InternalName)' to '$($Definition.Title)': $($_.Exception.Message)" -Level Error
        }
    }
}

function Add-ListContentTypes {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $List,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    $contentTypeDefinitions = @($Definition.ContentTypes | Where-Object { $_ })
    if ($contentTypeDefinitions.Count -eq 0) {
        return
    }

    $attachedNames = @(Get-PnPContentType -List $List -Connection $Connection -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    foreach ($contentType in $contentTypeDefinitions) {
        $contentTypeName = Get-ContentTypeDisplayName -ContentType $contentType
        try {
            if ($attachedNames -contains $contentTypeName) {
                Write-InstallLogAction -Message "Content type '$contentTypeName' is already assigned to '$($Definition.Title)', skipping."
            }
            else {
                Add-PnPContentTypeToList -List $List -ContentType $contentTypeName -Connection $Connection
                Write-InstallLogAction -Message "Assigned content type '$contentTypeName' to '$($Definition.Title)'."
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to assign content type '$contentTypeName' to '$($Definition.Title)': $($_.Exception.Message)" -Level Error
        }
    }

    # Make the first custom content type the default, then drop the built-in one so users only see the custom types.
    $builtInName = if ($Definition.Template -eq "DocumentLibrary") { "Document" } else { "Item" }
    try {
        $firstName = Get-ContentTypeDisplayName -ContentType $contentTypeDefinitions[0]
        $currentNames = @(Get-PnPContentType -List $List -Connection $Connection -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        if ($currentNames -contains $firstName) {
            Set-PnPDefaultContentTypeToList -List $List -ContentType $firstName -Connection $Connection
            Write-InstallLogAction -Message "Set '$firstName' as the default content type on '$($Definition.Title)'."
            if ($currentNames -contains $builtInName) {
                Remove-PnPContentTypeFromList -List $List -ContentType $builtInName -Connection $Connection
                Write-InstallLogAction -Message "Removed the '$builtInName' content type from '$($Definition.Title)'."
            }
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to set the default content type or remove '$builtInName' on '$($Definition.Title)': $($_.Exception.Message)" -Level Warning
    }

    # Surface the content types' columns in the default view so they show up for users.
    try {
        $defaultView = Get-PnPView -List $List -Connection $Connection | Where-Object { $_.DefaultView } | Select-Object -First 1
        if ($defaultView) {
            # ViewFields comes back as a single collection object, so enumerate it into plain field names.
            $viewFieldCollection = Get-PnPProperty -ClientObject $defaultView -Property ViewFields -Connection $Connection
            $viewFields = [string[]]@(foreach ($viewField in $viewFieldCollection) { [string]$viewField })
            $missingFields = @($contentTypeDefinitions | ForEach-Object { $_.Columns } | Where-Object { $_ -and ($viewFields -notcontains $_.InternalName) } | ForEach-Object { $_.InternalName } | Select-Object -Unique)
            if ($missingFields.Count -gt 0) {
                Set-PnPView -List $List -Identity $defaultView.Id -Fields ($viewFields + $missingFields) -Connection $Connection | Out-Null
            }
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to update the default view on '$($Definition.Title)': $($_.Exception.Message)" -Level Error
    }
}

function Add-ListViews {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $List,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    foreach ($view in @($Definition.Views | Where-Object { $_ })) {
        try {
            $existingView = Get-PnPView -List $List -Identity $view.Title -Connection $Connection -ErrorAction SilentlyContinue
            if ($existingView) {
                Write-InstallLogAction -Message "View '$($view.Title)' already exists on '$($Definition.Title)', skipping creation."
                continue
            }

            # Default to the title plus every column defined on the list/library.
            $fields = if ($view.Fields) {
                @($view.Fields)
            }
            else {
                $titleField = if ($Definition.Template -eq "DocumentLibrary") { "LinkFilename" } else { "Title" }
                @($titleField) + @(@($Definition.Columns) + @($Definition.ContentTypes | ForEach-Object { $_.Columns }) | Where-Object { $_ } | ForEach-Object { $_.InternalName } | Select-Object -Unique)
            }

            $viewParams = @{
                List       = $List
                Title      = $view.Title
                Fields     = $fields
                Connection = $Connection
            }
            if ($view.Query) {
                $viewParams.Query = $view.Query
            }
            Add-PnPView @viewParams | Out-Null
            Write-InstallLogAction -Message "Created view '$($view.Title)' on '$($Definition.Title)'."
        }
        catch {
            Write-InstallLogAction -Message "Failed to create view '$($view.Title)' on '$($Definition.Title)': $($_.Exception.Message)" -Level Error
        }
    }
}

# Sample items are matched on Title, so re-running never duplicates an item that is already there.
function Add-ListItems {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $List,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    $items = @($Definition.Items | Where-Object { $_ })
    if ($items.Count -eq 0) {
        return
    }

    $existingTitles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Get-PnPListItem -List $List -Fields "Title" -PageSize 500 -Connection $Connection | ForEach-Object {
        [void]$existingTitles.Add([string]$_.FieldValues["Title"])
    }

    $userColumns = @(@($Definition.Columns) + @($Definition.ContentTypes | ForEach-Object { $_.Columns }) | Where-Object { $_ -and $_.Type -eq "User" } | ForEach-Object { $_.InternalName })
    $added = 0
    $skipped = 0

    foreach ($item in $items) {
        try {
            if ($existingTitles.Contains([string]$item.Title)) {
                $skipped++
                continue
            }

            $values = @{}
            foreach ($property in $item.PSObject.Properties) {
                if ($null -eq $property.Value -or $property.Value -eq "") {
                    continue
                }
                if ($userColumns -contains $property.Name) {
                    # The person has to exist in the site's user information list before they can be set.
                    New-PnPUser -LoginName $property.Value -Connection $Connection | Out-Null
                }
                $values[$property.Name] = $property.Value
            }

            Add-PnPListItem -List $List -Values $values -Connection $Connection | Out-Null
            $added++
        }
        catch {
            Write-InstallLogAction -Message "Failed to add item '$($item.Title)' to '$($Definition.Title)': $($_.Exception.Message)" -Level Error
        }
    }

    Write-InstallLogAction -Message "Sample data for '$($Definition.Title)': added $added item(s), skipped $skipped that already existed."
}

# Sample documents are matched on file name within the library's root folder.
function Add-LibraryDocuments {
    param(
        [Parameter(Mandatory = $true)]
        $Connection,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Library,
        [Parameter(Mandatory = $true)]
        $Definition
    )

    $documents = @($Definition.Documents | Where-Object { $_ })
    if ($documents.Count -eq 0) {
        return
    }

    $rootFolder = Get-PnPProperty -ClientObject $Library -Property RootFolder -Connection $Connection
    $firstContentType = $Definition.ContentTypes | Where-Object { $_ } | Select-Object -First 1
    $contentTypeName = if ($firstContentType) { [string](Get-ContentTypeDisplayName -ContentType $firstContentType) } else { $null }
    $added = 0
    $skipped = 0

    foreach ($document in $documents) {
        try {
            $localPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$document"))
            $fileName = [System.IO.Path]::GetFileName($localPath)

            if (-not (Test-Path -Path $localPath)) {
                Write-InstallLogAction -Message "Sample document '$document' was not found on disk, skipping." -Level Warning
                continue
            }

            $existingFile = Get-PnPFile -Url "$($rootFolder.ServerRelativeUrl)/$fileName" -Connection $Connection -ErrorAction SilentlyContinue
            if ($existingFile) {
                $skipped++
                continue
            }

            $uploadParams = @{
                Path       = $localPath
                Folder     = $rootFolder.ServerRelativeUrl
                Connection = $Connection
            }
            if ($contentTypeName) {
                $uploadParams.ContentType = $contentTypeName
            }
            Add-PnPFile @uploadParams | Out-Null
            $added++
        }
        catch {
            Write-InstallLogAction -Message "Failed to upload '$document' to '$($Definition.Title)': $($_.Exception.Message)" -Level Error
        }
    }

    Write-InstallLogAction -Message "Sample documents for '$($Definition.Title)': uploaded $added file(s), skipped $skipped that already existed."
}

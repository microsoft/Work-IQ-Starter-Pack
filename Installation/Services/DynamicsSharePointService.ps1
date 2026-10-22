param([scriptblock]$AccessTokenProvider)

# Dynamics 365 and SharePoint integration services.

function Wait-DynamicsSharePointAccountIntegration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    while ($true) {
        $configured = Test-DynamicsSharePointIntegration -Config $Config
        $accountEnabled = $false
        if ($configured) {
            $environmentUrl = $Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/')
            $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
            $metadata = Invoke-RestMethod -Uri "$environmentUrl/api/data/v9.2/EntityDefinitions(LogicalName='account')?`$select=IsDocumentManagementEnabled" -Headers @{Authorization="Bearer $token";Accept='application/json'} -Method Get -ErrorAction Stop
            $accountEnabled = $metadata.IsDocumentManagementEnabled -eq $true
        }
        if ($configured -and $accountEnabled) { return $true }
        Write-InstallLogAction -Message "Configure SharePoint integration for D365 Sales & CS environment '$($Config.Settings.DynamicsEnvironmentUrl)' and select the Account table in Document Management Settings. See https://learn.microsoft.com/en-us/power-platform/admin/enable-sharepoint-document-management-specific-entities" -Level Warning
        do {
            $answer = (Read-Host 'After configuring SharePoint integration and enabling document management for the Account table, enter "ok" to continue or "cancel" to skip SharePoint document deployment (ok/cancel)').Trim().ToLowerInvariant()
        } while ($answer -notin @('ok', 'cancel'))
        if ($answer -eq 'cancel') {
            Write-InstallLogAction -Message 'SharePoint document deployment was canceled. Continuing with the remaining installation steps.'
            return $false
        }
        Write-InstallLogAction -Message 'Rechecking SharePoint integration and Account document management...'
    }
}

function Initialize-DynamicsSharePointDocuments {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = (Join-Path $PSScriptRoot '../../Content/contentDynamics.json'),
        [string]$DocumentsPath = (Join-Path $PSScriptRoot '../../Content/Documents/Demo4/SharePoint_Documents/Accounts'),
        [switch]$RemoveDocuments)

    if ($RemoveDocuments -and $AccessTokenProvider) {
        Remove-DynamicsSharePointDocumentsRest -Config $Config -ContentPath $ContentPath -DocumentsPath $DocumentsPath -TokenProvider $AccessTokenProvider
        return
    }
    $baseUrl = "$($Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/'))/api/data/v9.2"
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$($Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/'))/user_impersonation" } else { Get-PnPAccessToken -Scopes "$($Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/'))/user_impersonation" -ErrorAction Stop }
    $headers = @{Authorization="Bearer $token";Accept='application/json'}
    function Invoke-DocumentRequest {
        param([string]$Step, [hashtable]$Request)
        try { Invoke-RestMethod @Request -ErrorAction Stop }
        catch {
            $details = $_.ErrorDetails.Message
            if (-not $details -and $_.Exception.Response.Content) {
                try { $details = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
            }
            throw "${Step}: $($_.Exception.Message) Dataverse response: $details"
        }
    }
    # Follow collection pages without sending credentials outside this organization.
    function Get-DocumentRows {
        param([string]$Url)
        do {
            $uri = [Uri]::new([Uri]"$baseUrl/", $Url)
            if ($uri.GetLeftPart([UriPartial]::Authority) -ne ([Uri]$baseUrl).GetLeftPart([UriPartial]::Authority)) { throw 'Unexpected Dataverse pagination origin.' }
            $page = Invoke-DocumentRequest -Step "Read document locations ($($uri.AbsolutePath))" -Request @{Uri=$uri.AbsoluteUri;Headers=$headers;Method='Get'}
            $page.value | Where-Object { $null -ne $_ }
            $Url = $page.'@odata.nextLink'
        } while ($Url)
    }
    function Ensure-DocumentLocation {
        param([string]$ParentId, [string]$ParentSet, [string]$RelativeUrl, [string]$Name,
            [string]$RecordId, [string]$LogicalName, [string]$EntitySet)
        $filterText = "statecode eq 0 and _parentsiteorlocation_value eq $ParentId and relativeurl eq '$($RelativeUrl.Replace("'","''"))'"
        if ($RecordId) { $filterText += " and _regardingobjectid_value eq $RecordId" }
        else { $filterText += ' and _regardingobjectid_value eq null' }
        $filter = [Uri]::EscapeDataString($filterText)
        $locations = @(Get-DocumentRows "$baseUrl/sharepointdocumentlocations?`$select=sharepointdocumentlocationid&`$filter=$filter")
        if ($locations.Count -gt 1) { throw "Multiple document locations match '$Name'." }
        if ($locations.Count) { return [string]$locations[0].sharepointdocumentlocationid }
        $locationId = [Guid]::NewGuid().ToString()
        $parentNavigation = if ($ParentSet -eq 'sharepointsites') { 'parentsiteorlocation_sharepointsite@odata.bind' } else { 'parentsiteorlocation_sharepointdocumentlocation@odata.bind' }
        $body = @{sharepointdocumentlocationid=$locationId;name=$Name;relativeurl=$RelativeUrl}
        $body[$parentNavigation] = "/$ParentSet($ParentId)"
        if ($RecordId) { $body["regardingobjectid_$LogicalName@odata.bind"] = "/$EntitySet($RecordId)" }
        Invoke-DocumentRequest -Step "Create Dataverse document location '$Name' (relative URL '$RelativeUrl')" -Request @{
            Uri="$baseUrl/sharepointdocumentlocations";Headers=$headers;Method='Post'
            ContentType='application/json; charset=utf-8';Body=[Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json))
        } | Out-Null
        return $locationId
    }
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    $tables = @(@{Logical='account';Set='accounts';Collection='Accounts';Folder='Account'})
    $accountFiles = @{}
    foreach ($table in $tables) {
        if (-not $RemoveDocuments) {
        $metadata = Invoke-RestMethod -Uri "$baseUrl/EntityDefinitions(LogicalName='$($table.Logical)')?`$select=IsDocumentManagementEnabled" -Headers $headers -Method Get -ErrorAction Stop
        if ($metadata.IsDocumentManagementEnabled -ne $true) { throw "Document management is not enabled for '$($table.Logical)'. Enable it in D365 Sales & CS Document Management Settings, then rerun sp_mini." }
        Write-InstallLogAction -Message "Document management is enabled for '$($table.Logical)'."
        }
        foreach ($record in $content.($table.Collection)) {
            $id = [Guid]::Parse($record.Id).ToString()
            $localFolder = Join-Path $DocumentsPath $id
            if (-not (Test-Path -LiteralPath $localFolder -PathType Container)) {
                Write-InstallLogAction -Message "Skipping Account '$($record.Name)' ($id): local document folder '$localFolder' does not exist." -Level Warning
                continue
            }
            $files = @(Get-ChildItem -LiteralPath $localFolder -File -ErrorAction Stop | Where-Object { $_.Name -notlike '~$*' })
            if (-not $files.Count) {
                Write-InstallLogAction -Message "Skipping Account '$($record.Name)' ($id): local document folder is empty." -Level Warning
                continue
            }
            $accountFiles[$id] = $files
            if ([string]::IsNullOrWhiteSpace($record.Name)) { throw "Demo record '$id' has no name." }
            if (-not $RemoveDocuments) { Invoke-RestMethod -Uri "$baseUrl/$($table.Set)($id)?`$select=$($table.Logical)id" -Headers $headers -Method Get -ErrorAction Stop | Out-Null }
        }
    }
    $sites = @(Get-DocumentRows "$baseUrl/sharepointsites?`$select=sharepointsiteid,absoluteurl&`$filter=statecode eq 0 and servicetype eq 0 and isdefault eq true")
    if ($sites.Count -ne 1) { throw 'Expected exactly one active default SharePoint site in Dataverse.' }
    $site = $sites[0]
    $siteUri = [Uri]$site.absoluteurl
    if (-not $siteUri.IsAbsoluteUri -or $siteUri.Scheme -ne 'https' -or $siteUri.Host -ne "$($Config.Settings.TenantPrefix).sharepoint.com" -or $siteUri.UserInfo -or $siteUri.Query -or $siteUri.Fragment) { throw 'The default Dataverse SharePoint site must be an HTTPS site in the selected tenant.' }
    $siteId = [Guid]::Parse($site.sharepointsiteid).ToString()
    Write-InstallLogAction -Message "Default Dataverse SharePoint site: $($site.absoluteurl)."
    $connection = $null
    function Invoke-IntegrationSiteRest {
        param([string]$Path, [string]$Method = 'Get', [string]$FilePath)
        $siteToken = & $AccessTokenProvider "https://$($siteUri.Host)/.default"
        $request = @{
            Uri = "$($site.absoluteurl.TrimEnd('/'))/_api/web/$Path"
            Headers = @{ Authorization = "Bearer $siteToken"; Accept = 'application/json;odata=nometadata' }
            Method = $Method
            ErrorAction = 'Stop'
        }
        if ($FilePath) { $request.InFile = $FilePath; $request.ContentType = 'application/octet-stream' }
        Invoke-RestMethod @request
    }
    function Get-IntegrationFolderRest {
        param([string]$Url)
        $path = [uri]::EscapeDataString($Url.Replace("'", "''"))
        Invoke-IntegrationSiteRest -Path "GetFolderByServerRelativePath(decodedUrl='$path')?`$expand=Folders"
    }
    function Ensure-IntegrationFolderRest {
        param([string]$Url)
        $path = [uri]::EscapeDataString($Url.Replace("'", "''"))
        try { $null = Get-IntegrationFolderRest -Url $Url }
        catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            $null = Invoke-IntegrationSiteRest -Path "folders/AddUsingPath(decodedUrl='$path')" -Method Post
        }
    }
    if (-not $AccessTokenProvider) {
        $connection = Connect-PnPOnline -Url $site.absoluteurl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection -ErrorAction Stop
    }
    try {
        if ($AccessTokenProvider) {
            $web = Invoke-IntegrationSiteRest -Path '?$select=ServerRelativeUrl'
            $lists = Invoke-IntegrationSiteRest -Path 'lists?$expand=RootFolder'
            $libraries = @($lists.value | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden })
            $siteRoot = Get-IntegrationFolderRest -Url $web.ServerRelativeUrl
        }
        else {
            $web = Get-PnPWeb -Includes ServerRelativeUrl -Connection $connection -ErrorAction Stop
            $libraries = @(Get-PnPList -Includes RootFolder -Connection $connection -ErrorAction Stop | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden })
            $siteRoot = Get-PnPFolder -Url $web.ServerRelativeUrl -Includes Folders -Connection $connection -ErrorAction Stop
        }
        # Dynamics can provision entity libraries at the site root, or entity
        # folders inside Documents. Locate existing singular names in either layout.
        $availableFolders = @($siteRoot.Folders)
        foreach ($library in @($libraries | Where-Object { $_.RootFolder.Name -in @('Shared Documents','Documents') })) {
            $documentRoot = if ($AccessTokenProvider) { Get-IntegrationFolderRest -Url $library.RootFolder.ServerRelativeUrl } else { Get-PnPFolder -Url $library.RootFolder.ServerRelativeUrl -Includes Folders -Connection $connection -ErrorAction Stop }
            $availableFolders += @($documentRoot.Folders)
        }
        foreach ($table in $tables) {
            $roots = @($availableFolders | Where-Object { $_.Name -eq $table.Folder } | Sort-Object ServerRelativeUrl -Unique)
            if ($roots.Count -ne 1) { throw "Expected exactly one existing '$($table.Folder)' folder or library in the default SharePoint site; found $($roots.Count). Check D365 Sales & CS Document Management Settings." }
            $table.RootPath = $roots[0].ServerRelativeUrl.Substring($web.ServerRelativeUrl.TrimEnd('/').Length).TrimStart('/')
            Write-InstallLogAction -Message "Using existing '$($table.Folder)' folder: $($roots[0].ServerRelativeUrl)."
        }
        foreach ($table in $tables) {
            $rootPath = $table.RootPath
            # Each location stores one path segment relative to its parent.
            $parentId = $siteId
            $parentSet = 'sharepointsites'
            foreach ($segment in @($rootPath.Split('/') | Where-Object { -not $RemoveDocuments })) {
                $parentId = Ensure-DocumentLocation -ParentId $parentId -ParentSet $parentSet -RelativeUrl $segment -Name $segment
                $parentSet = 'sharepointdocumentlocations'
            }
            foreach ($record in $content.($table.Collection)) {
                $id = [Guid]::Parse($record.Id).ToString()
                if (-not $accountFiles.ContainsKey($id)) { continue }
                $folderPath = "$rootPath/$id"
                if ($RemoveDocuments) {
                    foreach ($file in $accountFiles[$id]) {
                        $fileUrl = "$($web.ServerRelativeUrl.TrimEnd('/'))/$folderPath/$($file.Name)"
                        $remoteFile = Get-PnPFile -Url $fileUrl -AsFileObject -Connection $connection -ErrorAction Stop
                        if ($null -ne $remoteFile -and $remoteFile.Exists) {
                            Remove-PnPFile -ServerRelativeUrl $fileUrl -Recycle -Force -Connection $connection -ErrorAction Stop
                            Write-InstallLogAction -Message "Recycled D365 Sales & CS SharePoint document '$fileUrl'." -Level Success
                        }

                    }
                    continue
                }
                try {
                    if ($AccessTokenProvider) { Ensure-IntegrationFolderRest -Url "$($web.ServerRelativeUrl.TrimEnd('/'))/$folderPath" }
                    else { Resolve-PnPFolder -SiteRelativePath $folderPath -Connection $connection -ErrorAction Stop | Out-Null }
                }
                catch { throw "Create SharePoint folder '$folderPath': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
                foreach ($file in $accountFiles[$id]) {
                    try {
                        if ($AccessTokenProvider) {
                            $folderUrl = [uri]::EscapeDataString(("$($web.ServerRelativeUrl.TrimEnd('/'))/$folderPath").Replace("'", "''"))
                            $fileName = [uri]::EscapeDataString($file.Name.Replace("'", "''"))
                            $null = Invoke-IntegrationSiteRest -Path "GetFolderByServerRelativePath(decodedUrl='$folderUrl')/Files/AddUsingPath(decodedUrl='$fileName',overwrite=true)" -Method Post -FilePath $file.FullName
                        }
                        else { Add-PnPFile -Folder $folderPath -Path $file.FullName -Connection $connection -ErrorAction Stop | Out-Null }
                    }
                    catch { throw "Upload '$folderPath/$($file.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
                    Write-InstallLogAction -Message "Uploaded '$($file.Name)' for Account '$($record.Name)'."
                }
                Ensure-DocumentLocation -ParentId $parentId -ParentSet $parentSet -RelativeUrl $id -Name "$($table.Collection) - $($record.Name)" -RecordId $id -LogicalName $table.Logical -EntitySet $table.Set | Out-Null
                Write-InstallLogAction -Message "Linked Account '$($record.Name)' ($id) to '$folderPath'; uploaded $($accountFiles[$id].Count) document(s)." -Level Success
            }
        }
    }
    # Disconnect-PnPOnline only supports the current connection, not -Connection.
    # Release this explicit connection; sp_mini closes its current connection.
    finally { $connection = $null }
}

function Remove-DynamicsSharePointDocumentsRest {
    [CmdletBinding()]
    param($Config, [string]$ContentPath, [string]$DocumentsPath, [scriptblock]$TokenProvider)
    $environment = $Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/')
    $dataverseHeaders = @{ Authorization = "Bearer $(& $TokenProvider "$environment/user_impersonation")"; Accept = 'application/json' }
    $sites = @()
    $url = "$environment/api/data/v9.2/sharepointsites?`$select=sharepointsiteid,absoluteurl&`$filter=statecode eq 0 and servicetype eq 0 and isdefault eq true"
    do {
        if (([uri]$url).GetLeftPart([UriPartial]::Authority) -ne $environment) { throw 'Unexpected Dataverse pagination origin.' }
        $page = Invoke-RestMethod -Uri $url -Headers $dataverseHeaders -Method Get -ErrorAction Stop
        $sites += @($page.value)
        $url = $page.'@odata.nextLink'
    } while ($url)
    if ($sites.Count -ne 1) { throw 'Expected exactly one active default SharePoint site in Dataverse.' }
    $siteUri = [uri]$sites[0].absoluteurl
    $hostName = "$($Config.Settings.TenantPrefix).sharepoint.com"
    if (-not $siteUri.IsAbsoluteUri -or $siteUri.Scheme -ne 'https' -or $siteUri.Host -ne $hostName -or $siteUri.UserInfo -or $siteUri.Query -or $siteUri.Fragment) { throw 'The default Dataverse SharePoint site must be an HTTPS site in the selected tenant.' }
    $siteUrl = $siteUri.AbsoluteUri.TrimEnd('/')
    $sharePointHeaders = @{ Authorization = "Bearer $(& $TokenProvider "https://$hostName/.default")"; Accept = 'application/json;odata=nometadata' }
    function Invoke-CleanupSharePointRequest {
        param([string]$Path, [string]$Method = 'Get')
        Invoke-RestMethod -Uri "$siteUrl/_api/web/$Path" -Headers $sharePointHeaders -Method $Method -ErrorAction Stop
    }
    function Get-CleanupSharePointRows {
        param([string]$Path)
        $nextUrl = "$siteUrl/_api/web/$Path"
        do {
            if (-not $nextUrl.StartsWith("$siteUrl/_api/", [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected SharePoint pagination origin.' }
            $page = Invoke-RestMethod -Uri $nextUrl -Headers $sharePointHeaders -Method Get -ErrorAction Stop
            $page.value
            $nextUrl = $page.'odata.nextLink'
        } while ($nextUrl)
    }
    function Get-CleanupFolderPath {
        param([string]$ServerRelativeUrl)
        "GetFolderByServerRelativePath(decodedUrl='$([uri]::EscapeDataString($ServerRelativeUrl.Replace("'", "''")))')"
    }
    $web = Invoke-CleanupSharePointRequest -Path '?$select=ServerRelativeUrl'
    $root = Get-CleanupFolderPath -ServerRelativeUrl $web.ServerRelativeUrl
    $folders = @(Get-CleanupSharePointRows -Path "$root/Folders?`$select=Name,ServerRelativeUrl")
    $libraries = @(Get-CleanupSharePointRows -Path 'lists?$select=BaseTemplate,Hidden,RootFolder/Name,RootFolder/ServerRelativeUrl&$expand=RootFolder')
    foreach ($library in ($libraries | Where-Object { $_.BaseTemplate -eq 101 -and -not $_.Hidden -and $_.RootFolder.Name -in @('Shared Documents', 'Documents') })) {
        $libraryPath = Get-CleanupFolderPath -ServerRelativeUrl $library.RootFolder.ServerRelativeUrl
        $folders += @(Get-CleanupSharePointRows -Path "$libraryPath/Folders?`$select=Name,ServerRelativeUrl")
    }
    $roots = @($folders | Where-Object Name -eq 'Account' | Sort-Object ServerRelativeUrl -Unique)
    if ($roots.Count -ne 1) { throw "Expected exactly one existing 'Account' folder or library; found $($roots.Count)." }
    $rootUrl = $roots[0].ServerRelativeUrl.TrimEnd('/')
    if (-not $rootUrl.StartsWith($web.ServerRelativeUrl.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Account folder is outside the selected SharePoint web.' }
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    foreach ($account in $content.Accounts) {
        $id = [guid]::Parse($account.Id).ToString()
        $folderUrl = "$rootUrl/$id"
        $folderPath = Get-CleanupFolderPath -ServerRelativeUrl $folderUrl
        try {
            $null = Invoke-CleanupSharePointRequest -Path "$folderPath/recycle()" -Method Post
            Write-InstallLogAction -Message "Recycled D365 Sales & CS SharePoint account folder '$folderUrl' and its contents." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
            } else { throw }
        }
    }
}

function Test-DynamicsSharePointIntegration {
    <#
    .SYNOPSIS
    Checks for active SharePoint document-management sites configured in Dynamics.
    .DESCRIPTION
    Returns a Boolean and logs the configured active SharePoint sites and their
    last validation status. This is a configuration check, not a live SharePoint
    connectivity test or a check of document management on individual tables.
    .EXAMPLE
    Test-DynamicsSharePointIntegration -Config $config
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)]$Config)

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw 'DynamicsEnvironmentUrl must be an HTTPS environment root URL.'
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $tenantPrefix = ([string]$Config.Settings.TenantPrefix).Trim() -replace '\.onmicrosoft\.com$', ''
    if ($tenantPrefix -notmatch '^[a-zA-Z0-9-]+$') { throw 'Settings.TenantPrefix must contain a valid tenant prefix.' }
    Write-InstallLogAction -Message "Tenant SharePoint URL: https://$tenantPrefix.sharepoint.com"
    Write-InstallLogAction -Message "Checking SharePoint integration configuration in '$environmentUrl'..."
    try {
        $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
        $requestHeaders = @{Authorization="Bearer $token";Accept='application/json';'OData-Version'='4.0';'OData-MaxVersion'='4.0'}
        # Exclude OneDrive and Teams site records: only service type 0 is SharePoint.
        $filter = [Uri]::EscapeDataString('statecode eq 0 and servicetype eq 0')
        $url = "$environmentUrl/api/data/v9.2/sharepointsites?`$select=sharepointsiteid,name,absoluteurl,validationstatus,isdefault&`$filter=$filter"
        $sites = @()
        do {
            $uri = [Uri]::new([Uri]"$environmentUrl/", $url)
            if ($uri.GetLeftPart([UriPartial]::Authority) -ne $environmentUrl) { throw 'SharePoint-site pagination URL points outside the D365 Sales & CS environment.' }
            $response = Invoke-RestMethod -Uri $uri.AbsoluteUri -Headers $requestHeaders -Method Get -ErrorAction Stop
            $sites += @($response.value | Where-Object { $_ })
            $url = $response.'@odata.nextLink'
        } while ($url)
        if (-not $sites.Count) {
            Write-InstallLogAction -Message 'No active SharePoint document-management sites are configured in D365 Sales & CS.' -Level Warning
            return $false
        }
        Write-InstallLogAction -Message "SharePoint integration is configured with $($sites.Count) active site(s)." -Level Success
        $validationLabels = @{1='Not validated';2='In progress';3='Invalid';4='Valid';5='Could not validate'}
        foreach ($site in $sites) {
            $status = $validationLabels[[int]$site.validationstatus]
            if (-not $status) { $status = 'Unknown' }
            Write-InstallLogAction -Message "SharePoint site: '$($site.name)' ($($site.absoluteurl)); last validation: $status; default: $($site.isdefault)."
        }
        return $true
    }
    catch { throw "Failed to check D365 Sales & CS SharePoint integration: $($_.Exception.Message) $($_.ErrorDetails.Message)" }
}

function Import-SiteDocuments {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($site in $Config.Sites) {
        if (-not $site.Content -or -not $site.Content.Documents -or $site.Content.Documents.Count -eq 0) {
            continue
        }

        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
        $siteConnection = Connect-PnPOnline -Url $siteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection

        foreach ($file in $site.Content.Documents) {
            try {
                Import-SiteDocument -SiteUrl $siteUrl -File $file -Connection $siteConnection
                Write-Host "Imported '$($file.Title)' into site '$($site.URL)'."
            }
            catch {
                Write-Host "Failed to import '$($file.Title)' into site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

function Import-SiteDocument {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,
        [Parameter(Mandatory = $true)]
        $File,
        [Parameter(Mandatory = $true)]
        $Connection
    )

    $localPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$($File.Path)"))

    # Get the library and hydrate the RootFolder property
    $documentsLibrary = Get-PnPList -Identity "Documents" -Connection $Connection
    $rootFolder = Get-PnPProperty -ClientObject $documentsLibrary -Property RootFolder

    # This is going into a Teams General channel so get the folder
    $generalFolder = Resolve-PnPFolder -SiteRelativePath "$($rootFolder.Name)/General" -Connection $Connection

    #Upload the file save the object so we can update metadata later
    $uploadedFile = Add-PnPFile -Path $localPath -Folder $generalFolder.ServerRelativeUrl -Connection $Connection
    $null = Get-PnPProperty -ClientObject $uploadedFile -Property ListItemAllFields -Connection $Connection
    $itemId = $uploadedFile.ListItemAllFields.Id

    # Ensure the users exist in the current site
    $createdByUser = New-PnPUser -LoginName $File.CreatedBy -Connection $Connection
    $modifiedByUser = if ($File.ModifiedBy -eq $File.CreatedBy) { $createdByUser } else { New-PnPUser -LoginName $File.ModifiedBy -Connection $Connection }

    # Today (offset days) - offsets are negative, so this lands the timestamp in the past.
    $createdDate = (Get-Date).AddDays($File.CreatedOffset).ToString("yyyy-MM-dd HH:mm:ss")
    $modifiedDate = (Get-Date).AddDays($File.ModifiedOffset).ToString("yyyy-MM-dd HH:mm:ss")

    # People fields need to be in this format [{'Key':'i:0#.f|membership|<user-email>'}]
    $authorFieldValue = "[{'Key':'$($createdByUser.LoginName)'}]"
    $editorFieldValue = "[{'Key':'$($modifiedByUser.LoginName)'}]"

    $body = @{
        formValues         = @(
            @{ FieldName = "Title"; FieldValue = $File.Title }
            @{ FieldName = "Created"; FieldValue = $createdDate }
            @{ FieldName = "Modified"; FieldValue = $modifiedDate }
            @{ FieldName = "Author"; FieldValue = $authorFieldValue }
            @{ FieldName = "Editor"; FieldValue = $editorFieldValue }
        )
        bNewDocumentUpdate = $true
    } | ConvertTo-Json -Depth 5

    $url = "$SiteUrl/_api/web/lists/getbytitle('$($documentsLibrary.Title)')/items($itemId)/ValidateUpdateListItem"

    try {
        #ensure access tokens are correct and call ValidateUpdateListItem to update the metadata fields. This is required because Add-PnPFile does not allow setting these fields directly.
        $accessToken = Get-PnPAccessToken -ResourceTypeName SharePoint -Connection $Connection
        $headers = @{
            Authorization  = "Bearer $accessToken"
            "Content-Type" = "application/json;odata=verbose"
            Accept         = "application/json;odata=verbose"
        }
        $response = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $body
        $response
    }
    catch {
        Write-Host "URL: $url" -ForegroundColor Yellow
        Write-Host "Request body: $body" -ForegroundColor Yellow
        Write-Host "Response: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        throw
    }
}

function Add-TeamsChatMessages {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $MigrationHeaders
    )

    foreach ($site in $Config.Sites) {
        if (-not $site.Content -or -not $site.Content.Chats -or $site.Content.Chats.Count -eq 0) {
            continue
        }

        try {
            $teamId = Get-SiteGroupId -Site $site
            $channelId = Get-GeneralChannelId -TeamId $teamId

            $messages = foreach ($chat in $site.Content.Chats) {
                foreach ($message in $chat.Messages) {
                    $timestamp = (Get-Date).Date.AddDays($message.Offset).Add([TimeSpan]::Parse($message.Time))
                    [PSCustomObject]@{
                        Timestamp = $timestamp
                        Sender    = $message.Sender
                        Message   = $message.Message
                        ChatTitle = $chat.Title
                    }
                }
            }
            $messages = $messages | Sort-Object -Property Timestamp

            Import-TeamsChatMessages -TeamId $teamId -ChannelId $channelId -Messages $messages -Config $Config -MigrationHeaders $MigrationHeaders
            Write-Host "Imported $($messages.Count) chat messages into the General channel of site '$($site.URL)'."
        }
        catch {
            Write-Host "Failed to import chat messages into site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Get-GeneralChannelId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TeamId
    )

    $channel = (Invoke-RestMethod -Uri "$graphBaseUrl/teams/$TeamId/channels?`$filter=displayName eq 'General'" -Headers $headers -Method Get).value | Select-Object -First 1

    if (-not $channel) {
        throw "The General channel for team '$TeamId' could not be found."
    }

    return $channel.id
}

function Resolve-TeamsChatSender {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SenderName,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $SenderCache
    )

    if ($SenderCache.ContainsKey($SenderName)) {
        return $SenderCache[$SenderName]
    }

    $matchedUser = $Config.Users | Where-Object { "$($_.FirstName) $($_.LastName)" -eq $SenderName } | Select-Object -First 1

    if (-not $matchedUser) {
        throw "No user in config.json's Users list matches chat sender '$SenderName'."
    }

    $graphUser = Invoke-RestMethod -Uri "$graphBaseUrl/users/$($matchedUser.Email)?`$select=id,displayName" -Headers $headers -Method Get

    $identity = @{
        id                = $graphUser.id
        displayName       = $graphUser.displayName
        userIdentityType  = "aadUser"
    }

    $SenderCache[$SenderName] = $identity
    return $identity
}

function Import-TeamsChatMessages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TeamId,
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        [Parameter(Mandatory = $true)]
        $Messages,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        $MigrationHeaders
    )

    if ($Messages.Count -eq 0) {
        return
    }

    $migrationBaseUrl = "$graphBaseUrl/teams/$TeamId/channels/$ChannelId"
    $earliestTimestamp = $Messages[0].Timestamp.AddSeconds(-60).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

    Invoke-RestMethod -Uri "$migrationBaseUrl/startMigration" -Headers $MigrationHeaders -Method Post `
        -ContentType "application/json" -Body (@{ conversationCreationDateTime = $earliestTimestamp } | ConvertTo-Json)

    $senderCache = @{}

    try {
        $lastUsedTimestamp = [DateTime]::MinValue

        foreach ($message in $Messages) {
            $messageTimestamp = $message.Timestamp
            if ($messageTimestamp -le $lastUsedTimestamp) {
                $messageTimestamp = $lastUsedTimestamp.AddMilliseconds(1)
            }
            $lastUsedTimestamp = $messageTimestamp

            $senderIdentity = Resolve-TeamsChatSender -SenderName $message.Sender -Config $Config -SenderCache $senderCache

            $body = @{
                createdDateTime = $messageTimestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                from            = @{ user = $senderIdentity }
                body            = @{
                    contentType = "text"
                    content     = $message.Message
                }
            } | ConvertTo-Json -Depth 5

            Invoke-RestMethod -Uri "$migrationBaseUrl/messages" -Headers $MigrationHeaders -Method Post -ContentType "application/json" -Body $body
        }
    }
    finally {
        Invoke-RestMethod -Uri "$migrationBaseUrl/completeMigration" -Headers $MigrationHeaders -Method Post
    }
}

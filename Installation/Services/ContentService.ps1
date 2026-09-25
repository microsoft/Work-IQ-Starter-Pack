function Update-ContentPersonas {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        $DemoUsers,
        [Parameter(Mandatory = $true)]
        $RealUsers,
        [Parameter(Mandatory = $true)]
        [hashtable]$RealUserUpns
    )

    # content.json (SourcePath) is always the pristine demo content - it's never modified. This
    # always re-derives content.custom.json (OutputPath) from it fresh, so re-running the
    # installer with different real users never leaves stale swapped names behind.
    $contentText = Get-Content -Path $SourcePath -Raw

    # Emails and full names first - full name before first name, since "Serena Ribeiro" contains
    # "Serena" and swapping the first name first would break the full-name match.
    foreach ($index in $RealUserUpns.Keys) {
        $demoEmail = $DemoUsers[$index].Email
        $realEmail = $RealUsers[$index].Email
        if (-not [string]::IsNullOrWhiteSpace($demoEmail) -and -not [string]::IsNullOrWhiteSpace($realEmail)) {
            $contentText = $contentText.Replace($demoEmail, $realEmail)
        }

        $demoFullName = "$($DemoUsers[$index].FirstName) $($DemoUsers[$index].LastName)"
        $realFullName = "$($RealUsers[$index].FirstName) $($RealUsers[$index].LastName)"
        if (-not [string]::IsNullOrWhiteSpace($DemoUsers[$index].FirstName) -and -not [string]::IsNullOrWhiteSpace($RealUsers[$index].FirstName)) {
            $contentText = $contentText.Replace($demoFullName, $realFullName)
        }
    }

    # Bare first-name mentions in chat message text (e.g. "Serena, appreciate...") - word-bounded
    # so this doesn't match inside unrelated longer words.
    foreach ($index in $RealUserUpns.Keys) {
        $demoFirstName = $DemoUsers[$index].FirstName
        $realFirstName = $RealUsers[$index].FirstName
        if (-not [string]::IsNullOrWhiteSpace($demoFirstName) -and -not [string]::IsNullOrWhiteSpace($realFirstName)) {
            $contentText = $contentText -replace "\b$([regex]::Escape($demoFirstName))\b", $realFirstName
        }
    }

    # Validate the result is still well-formed JSON before writing it out.
    $null = $contentText | ConvertFrom-Json

    Set-Content -Path $OutputPath -Value $contentText
}

function Import-SiteDocuments {
    param(
        [Parameter(Mandatory = $true)]
        $ContentConfig,
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($site in $ContentConfig.Sites) {
        # Documents and MeetingTranscripts are both just files uploaded into the site's document
        # library - same shape (Title/Path/Created*/Modified*), same upload path - but each group
        # has its own target folder within the library.
        $groups = @("Documents", "MeetingTranscripts")
        $hasFiles = $groups | Where-Object { $site.Content -and $site.Content.$_ } | Select-Object -First 1
        if (-not $hasFiles) {
            continue
        }

        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
        $siteConnection = Connect-PnPOnline -Url $siteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection

        foreach ($group in $groups) {
            if (-not ($site.Content -and $site.Content.$group)) {
                continue
            }

            # MeetingTranscripts get their own folder - nested under General on Teams-enabled
            # sites (alongside the rest of the library content), or at the library root otherwise.
            $targetFolder = if ($group -eq "MeetingTranscripts") {
                if ($site.EnableMicrosoftTeams) { "General/Meeting Transcripts" } else { "Meeting Transcripts" }
            }
            else {
                "General"
            }

            foreach ($file in $site.Content.$group) {
                try {
                    Import-SiteDocument -SiteUrl $siteUrl -File $file -Connection $siteConnection -TargetFolder $targetFolder
                    Write-InstallLogAction -Message "Imported '$($file.Title)' into site '$($site.URL)'."
                }
                catch {
                    Write-Host "Failed to import '$($file.Title)' into site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
                }
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
        $Connection,
        [Parameter(Mandatory = $true)]
        [string]$TargetFolder
    )

    $localPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$($File.Path)"))

    # Get the library and hydrate the RootFolder property
    $documentsLibrary = Get-PnPList -Identity "Documents" -Connection $Connection
    $rootFolder = Get-PnPProperty -ClientObject $documentsLibrary -Property RootFolder

    # Resolve-PnPFolder creates any missing folders along the path, e.g. "General/Meeting Transcripts".
    $destinationFolder = Resolve-PnPFolder -SiteRelativePath "$($rootFolder.Name)/$TargetFolder" -Connection $Connection

    #Upload the file save the object so we can update metadata later
    $uploadedFile = Add-PnPFile -Path $localPath -Folder $destinationFolder.ServerRelativeUrl -Connection $Connection
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
            Write-InstallLogAction -Message "Imported $($messages.Count) chat messages into the General channel of site '$($site.URL)'."
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

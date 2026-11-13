param(
    [string]$ImportedPostsPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../.state/imported-posts.json'))
)

function Update-ContentPersonas {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [Parameter(Mandatory = $true)]
        [string]$TenantPrefix,
        $DemoUsers,
        $RealUsers,
        [hashtable]$RealUserUpns
    )

    # content.json only carries the <TENANTPREFIX> token; the real prefix comes from config.json.
    # The custom file written here is regenerated every run and is what provisioning reads.
    $contentText = (Get-Content -Path $SourcePath -Raw).Replace('<TENANTPREFIX>', $TenantPrefix)

    if (-not $RealUserUpns) {
        $RealUserUpns = @{}
    }

    $upnReplacements = @{}
    $selectedUpns = @(foreach ($index in ($RealUserUpns.Keys | Sort-Object { [int]$_ })) {
        $demoEmail = $DemoUsers[$index].Email.Replace('<TENANTPREFIX>', $TenantPrefix)
        $realEmail = $RealUsers[$index].Email
        if ([string]::IsNullOrWhiteSpace($demoEmail) -or [string]::IsNullOrWhiteSpace($realEmail)) {
            throw "A demo identity and a resolved user UPN are required for role index $index."
        }
        $upnReplacements[$demoEmail] = $realEmail
        $realEmail
    })
    if ($upnReplacements.Count) {
        # Replace all role identities in one pass so selecting another demo user's
        # UPN cannot cause cascading replacements between role slots.
        $upnPattern = ($upnReplacements.Keys | Sort-Object Length -Descending | ForEach-Object { [regex]::Escape($_) }) -join '|'
        $contentText = [regex]::Replace($contentText, $upnPattern, {
            param($match)
            $upnReplacements[$match.Value]
        }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    foreach ($index in $RealUserUpns.Keys) {
        $demoFullName = "$($DemoUsers[$index].FirstName) $($DemoUsers[$index].LastName)"
        $realFullName = "$($RealUsers[$index].FirstName) $($RealUsers[$index].LastName)"
        if (-not [string]::IsNullOrWhiteSpace($DemoUsers[$index].FirstName) -and -not [string]::IsNullOrWhiteSpace($RealUsers[$index].FirstName)) {
            $contentText = $contentText.Replace($demoFullName, $realFullName)
        }
    }

    foreach ($index in $RealUserUpns.Keys) {
        $demoFirstName = $DemoUsers[$index].FirstName
        $realFirstName = $RealUsers[$index].FirstName
        if (-not [string]::IsNullOrWhiteSpace($demoFirstName) -and -not [string]::IsNullOrWhiteSpace($realFirstName)) {
            $contentText = $contentText -replace "\b$([regex]::Escape($demoFirstName))\b", $realFirstName
        }
    }

    # Validate the result is still well-formed JSON before writing it out.
    $newContent = $contentText | ConvertFrom-Json
    # Store the resolved UPNs in role order; demo-user runs reset this to [].
    $newContent | Add-Member -NotePropertyName RealUserUpns -NotePropertyValue @($selectedUpns) -Force

    $previousIds = @{}
    if (Test-Path -LiteralPath $OutputPath) {
        try {
            $previousContent = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
            foreach ($site in $previousContent.Sites) {
                foreach ($thread in @($site.Content.EmailThreads)) {
                    if ($thread -and $thread.Path -and $thread.Messages) { $previousIds[$thread.Path] = @($thread.Messages) }
                }
            }
        }
        catch { Write-Verbose "Could not read the previous custom content file: $($_.Exception.Message)" }
    }

    if ($previousIds.Count -gt 0) {
        foreach ($site in $newContent.Sites) {
            foreach ($thread in @($site.Content.EmailThreads)) {
                if ($thread -and $previousIds.ContainsKey($thread.Path)) {
                    $thread | Add-Member -NotePropertyName Messages -NotePropertyValue $previousIds[$thread.Path] -Force
                }
            }
        }
    }

    $contentText = $newContent | ConvertTo-Json -Depth 20
    Set-Content -LiteralPath $OutputPath -Value $contentText -Encoding UTF8
}

function Get-EligibleSites {
    param(
        [Parameter(Mandatory = $true)]
        $ContentConfig,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [ValidateSet('M365', 'Dynamics')]
        [string]$InstallType
    )

    # Dynamics sites belong to the Dynamics content pack, every other site to the M365 pack.
    foreach ($site in $ContentConfig.Sites) {
        if ($InstallType -eq 'M365' -and $Config.Settings.InstallM365Content -eq $true) {
            $packSelected = -not [bool]$site.DynamicsContent
        }
        if ($InstallType -eq 'Dynamics' -and $Config.Settings.InstallDynamicsContent -eq $true) {
            $packSelected = [bool]$site.DynamicsContent
        }
        
        if ($packSelected) {
            $site
        }
        else {
            $packName = if ($isDynamicsSite) { "Dynamics" } else { "M365" }
            Write-InstallLogAction -Message "Skipping site '$($site.Title)': the $packName content pack was not selected."
        }
    }
}

function Import-SiteDocuments {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config
    )

    if (-not ($Site.Content -and $Site.Content.Documents)) {
        return
    }

    $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($Site.URL)"
    $siteConnection = Connect-PnPOnline -Url $siteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection

    $channelFolder = if ($Site.Channels -and $Site.Channels[0].Title) { $Site.Channels[0].Title } else { "General" }

    foreach ($file in $Site.Content.Documents) {
        try {
            Import-SiteDocument -SiteUrl $siteUrl -File $file -Connection $siteConnection -TargetFolder $channelFolder | Out-Null
            Write-InstallLogAction -Message "Imported '$($file.Title)' into site '$($Site.URL)'."
        }
        catch {
            Write-Host "Failed to import '$($file.Title)' into site '$($Site.URL)': $($_.Exception.Message)" -ForegroundColor Red
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
        [string]$TargetFolder,
        # Overrides the repo-relative $File.Path for rewritten copies (e.g. transcripts with the names swapped).
        [string]$LocalPath
    )

    $localPath = if ($LocalPath) { $LocalPath } else { [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$($File.Path)")) }

    # Get the library and hydrate the RootFolder property
    $documentsLibrary = Get-PnPList -Identity "Documents" -Connection $Connection
    $rootFolder = Get-PnPProperty -ClientObject $documentsLibrary -Property RootFolder

    # Resolve-PnPFolder creates any missing folders along the path, e.g. "General/Meeting Transcripts".
    $destinationFolder = Resolve-PnPFolder -SiteRelativePath "$($rootFolder.Name)/$TargetFolder" -Connection $Connection

    #Upload the file save the object so we can update metadata later
    $uploadedFile = Add-PnPFile -Path $localPath -Folder $destinationFolder.ServerRelativeUrl -Connection $Connection
    $null = Get-PnPProperty -ClientObject $uploadedFile -Property ListItemAllFields, UniqueId -Connection $Connection
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
        [PSCustomObject]@{ Response = $response; ServerRelativeUrl = $uploadedFile.ServerRelativeUrl; UniqueId = $uploadedFile.UniqueId }
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
        $Site,
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        $MigrationHeaders,
        # Shared across sites so every site's message timestamps are offset by the same amount.
        [TimeSpan]$RunJitter = [TimeSpan]::FromMilliseconds((Get-Date).Second * 1000 + (Get-Date).Millisecond),
        # Pre-built messages (e.g. the meeting transcript posts from Add-TeamMeetings) imported in the
        # same migration session, because a channel can only be migrated once.
        $ExtraMessages = @()
    )

    $hasChats = $Site.Content -and $Site.Content.Chats -and $Site.Content.Chats.Count -gt 0
    if (-not $hasChats -and @($ExtraMessages).Count -eq 0) {
        return
    }

    try {
        $team = Get-TeamByMailNickName -MailNickName $Site.URL
        if (-not $team) {
            throw "No Teams team found for site '$($Site.URL)'. Run Add-TeamSite first."
        }
        $teamId = $team.GroupId
        # Chats go in the site's first channel (see Add-TeamChannels), falling back to General when
        # the site defines none - the same channel the site's documents are uploaded to.
        $channelName = if ($Site.Channels -and $Site.Channels[0].Title) { $Site.Channels[0].Title } else { "General" }
        $channelId = Get-TeamChannelId -TeamId $teamId -ChannelName $channelName

        $chatMessages = foreach ($chat in @($Site.Content.Chats)) {
            foreach ($message in $chat.Messages) {
                $timestamp = (Get-Date).Date.AddDays($message.Offset).Add([TimeSpan]::Parse($message.Time)).Add($RunJitter)
                [PSCustomObject]@{
                    Timestamp = $timestamp
                    Sender    = $message.Sender
                    Message   = $message.Message
                    ChatTitle = $chat.Title
                    Members   = $chat.Members
                }
            }
        }
        $messages = @($chatMessages) + @($ExtraMessages) | Sort-Object -Property Timestamp

        $imported = Import-TeamsChatMessages -TeamId $teamId -ChannelId $channelId -Messages $messages -Settings $Settings -MigrationHeaders $MigrationHeaders
        if ($imported) {
            Write-InstallLogAction -Message "Imported $imported chat messages into the '$channelName' channel of site '$($Site.URL)'."
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to import chat messages into site '$($Site.URL)': $($_.Exception.Message)" -Level Error
    }
}

function Get-TeamChannelId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TeamId,
        [string]$ChannelName = "General"
    )

    $escapedName = $ChannelName.Replace("'", "''")
    $channel = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/teams/$TeamId/channels?`$filter=displayName eq '$escapedName'" -Headers $headers -Method Get).value | Select-Object -First 1

    if (-not $channel) {
        throw "The '$ChannelName' channel for team '$TeamId' could not be found."
    }

    return $channel.id
}

function Resolve-TeamsChatUserIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        $SenderCache
    )

    if ($SenderCache.ContainsKey($Name)) {
        return $SenderCache[$Name]
    }

    $matchedUser = $Settings.Users | Where-Object { "$($_.FirstName) $($_.LastName)" -eq $Name } | Select-Object -First 1

    if (-not $matchedUser) {
        $SenderCache[$Name] = $null
        return $null
    }

    $graphUser = Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$($matchedUser.Email)?`$select=id,displayName" -Headers $headers -Method Get

    $identity = @{
        id                = $graphUser.id
        displayName       = $graphUser.displayName
        userIdentityType  = "aadUser"
    }

    $SenderCache[$Name] = $identity
    return $identity
}

function Resolve-TeamsChatSender {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SenderName,
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        $SenderCache
    )

    $identity = Resolve-TeamsChatUserIdentity -Name $SenderName -Settings $Settings -SenderCache $SenderCache

    if (-not $identity) {
        throw "No user in settings.json's Users list matches chat sender '$SenderName'."
    }

    return $identity
}

function ConvertTo-TeamsChatMessageBody {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [Parameter(Mandatory = $false)]
        [string[]]$MentionCandidates,
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        $SenderCache
    )

    if (-not $MentionCandidates -or $MentionCandidates.Count -eq 0) {
        return @{ contentType = "text"; content = $Text; mentions = @() }
    }

    $escapedNames = $MentionCandidates | Sort-Object -Property Length -Descending | ForEach-Object { [regex]::Escape($_) }
    $pattern = "(?<![\w@])@(?:$($escapedNames -join '|'))\b"
    $regex = [regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $regexMatches = $regex.Matches($Text)
    if ($regexMatches.Count -eq 0) {
        return @{ contentType = "text"; content = $Text; mentions = @() }
    }

    $mentions = @()
    $mentionIndex = 0
    $html = New-Object System.Text.StringBuilder
    $lastPos = 0

    foreach ($match in $regexMatches) {
        $name = $match.Value.Substring(1)
        $identity = Resolve-TeamsChatUserIdentity -Name $name -Settings $Settings -SenderCache $SenderCache

        if (-not $identity) {
            Write-Host "Chat mention '@$name' has no matching entry in settings.json's Users list - leaving it as literal text." -ForegroundColor Yellow
            continue
        }

        $null = $html.Append([System.Net.WebUtility]::HtmlEncode($Text.Substring($lastPos, $match.Index - $lastPos)))
        $null = $html.Append("<at id=`"$mentionIndex`">$([System.Net.WebUtility]::HtmlEncode($identity.displayName))</at>")

        $mentions += @{
            id          = $mentionIndex
            mentionText = $identity.displayName
            mentioned   = @{ user = $identity }
        }

        $mentionIndex++
        $lastPos = $match.Index + $match.Length
    }

    if ($mentions.Count -eq 0) {
        return @{ contentType = "text"; content = $Text; mentions = @() }
    }

    $null = $html.Append([System.Net.WebUtility]::HtmlEncode($Text.Substring($lastPos)))

    return @{ contentType = "html"; content = $html.ToString(); mentions = $mentions }
}

# Which meeting posts were imported into which channel. The migration API can't de-duplicate and reading a
# channel's messages needs another permission, so the installer keeps its own record, keyed by channel id
# (a recreated channel has a new id and starts clean).
function Get-ImportedPostSubjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId
    )

    if (-not (Test-Path -LiteralPath $ImportedPostsPath)) {
        return @()
    }
    $state = Get-Content -LiteralPath $ImportedPostsPath -Raw | ConvertFrom-Json
    return @($state.$ChannelId)
}

function Add-ImportedPostSubjects {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        [string[]]$Subjects = @()
    )

    if ($Subjects.Count -eq 0) {
        return
    }
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $ImportedPostsPath) {
        $existing = Get-Content -LiteralPath $ImportedPostsPath -Raw | ConvertFrom-Json
        foreach ($property in $existing.PSObject.Properties) { $state[$property.Name] = @($property.Value) }
    }
    $state[$ChannelId] = @(@($state[$ChannelId]) + $Subjects | Where-Object { $_ } | Select-Object -Unique)
    $null = New-Item -Path (Split-Path $ImportedPostsPath) -ItemType Directory -Force
    $state | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ImportedPostsPath
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
        $Settings,
        [Parameter(Mandatory = $true)]
        $MigrationHeaders
    )

    if ($Messages.Count -eq 0) {
        return 0
    }

    $migrationBaseUrl = "$graphBaseUrl/teams/$TeamId/channels/$ChannelId"

    $channel = Invoke-GraphRestMethod -Uri "$migrationBaseUrl`?`$select=migrationMode,createdDateTime" -Headers $headers -Method Get

    if ($channel.migrationMode -eq "completed") {
        # A completed channel can be migrated into again (startMigration), but the API does not de-duplicate.
        # The chat history is only ever imported with the channel's first migration, so only the pre-rendered
        # meeting posts that are not recorded as imported yet are added now.
        $alreadyImported = Get-ImportedPostSubjects -ChannelId $ChannelId
        $Messages = @($Messages | Where-Object { $_.Html -and $_.ChatTitle -notin $alreadyImported })
        if ($Messages.Count -eq 0) {
            Write-InstallLogAction -Message "Channel '$ChannelId' on team '$TeamId' was already migrated and has all of its meeting posts - skipping."
            return 0
        }
        Write-InstallLogAction -Message "Channel '$ChannelId' on team '$TeamId' was already migrated - importing $($Messages.Count) missing meeting post(s)."
    }

    if ($channel.migrationMode -ne "inProgress") {
        $channelCreatedDateTime = ([DateTimeOffset]$channel.createdDateTime).UtcDateTime
        $earliestMessageTimestamp = $Messages[0].Timestamp.ToUniversalTime()
        $anchor = if ($channelCreatedDateTime -lt $earliestMessageTimestamp) { $channelCreatedDateTime } else { $earliestMessageTimestamp }
        $conversationCreationDateTime = $anchor.AddSeconds(-60).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

        $null = Invoke-GraphRestMethod -Uri "$migrationBaseUrl/startMigration" -Headers $MigrationHeaders -Method Post `
            -ContentType "application/json" -Body (@{ conversationCreationDateTime = $conversationCreationDateTime } | ConvertTo-Json)
    }

    $senderCache = @{}
    $topicStarterIds = @{}

    try {
        $lastUsedTimestamp = [DateTime]::MinValue

        foreach ($message in $Messages) {
            $messageTimestamp = $message.Timestamp
            if ($messageTimestamp -le $lastUsedTimestamp) {
                $messageTimestamp = $lastUsedTimestamp.AddMilliseconds(1)
            }
            $lastUsedTimestamp = $messageTimestamp

            $senderIdentity = Resolve-TeamsChatSender -SenderName $message.Sender -Settings $Settings -SenderCache $senderCache

            $isTopicStarter = -not $topicStarterIds.ContainsKey($message.ChatTitle)

            # Pre-rendered HTML (meeting transcript links) skips the @mention rendering.
            $renderedBody = if ($message.Html) {
                @{ contentType = "html"; content = $message.Html; mentions = @() }
            }
            else {
                ConvertTo-TeamsChatMessageBody -Text $message.Message -MentionCandidates $message.Members -Settings $Settings -SenderCache $senderCache
            }

            $bodyProperties = @{
                createdDateTime = $messageTimestamp.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                from            = @{ user = $senderIdentity }
                body            = @{
                    contentType = $renderedBody.contentType
                    content     = $renderedBody.content
                }
            }

            if ($renderedBody.mentions.Count -gt 0) {
                $bodyProperties.mentions = $renderedBody.mentions
            }

            if ($isTopicStarter) {
                $bodyProperties.subject = $message.ChatTitle
                $postUrl = "$migrationBaseUrl/messages"
            }
            else {
                $postUrl = "$migrationBaseUrl/messages/$($topicStarterIds[$message.ChatTitle])/replies"
            }

            $body = $bodyProperties | ConvertTo-Json -Depth 8

            $createdMessage = Invoke-GraphRestMethod -Uri $postUrl -Headers $MigrationHeaders -Method Post -ContentType "application/json" -Body $body

            if ($isTopicStarter) {
                $topicStarterIds[$message.ChatTitle] = $createdMessage.id
            }
        }

        # Only seal the migration once every message has actually been sent - completing it after a
        # partial failure would permanently lock in a half-imported channel.
        $null = Invoke-GraphRestMethod -Uri "$migrationBaseUrl/completeMigration" -Headers $MigrationHeaders -Method Post
        Add-ImportedPostSubjects -ChannelId $ChannelId -Subjects @($Messages | Where-Object { $_.Html } | ForEach-Object { $_.ChatTitle })
        return $Messages.Count
    }
    catch {
        Write-Host "Import-TeamsChatMessages failed for team '$TeamId', channel '$ChannelId': $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "Response: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
        throw
    }
}

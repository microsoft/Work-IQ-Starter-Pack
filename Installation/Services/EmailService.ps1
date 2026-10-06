$script:ImportedEmailCategory = "WorkIQStarterPack"

function Get-EmailThreadMessages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $DemoUsers,
        [Parameter(Mandatory = $true)]
        $ActiveUsers
    )

    $fullPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$Path"))
    if (-not (Test-Path $fullPath)) {
        throw "Email thread file not found: $fullPath"
    }

    $text = Get-Content -Path $fullPath -Raw
    for ($i = 0; $i -lt $DemoUsers.Count; $i++) {
        $demo = $DemoUsers[$i]
        $active = $ActiveUsers[$i]
        if ([string]::IsNullOrWhiteSpace($demo.FirstName) -or [string]::IsNullOrWhiteSpace($active.FirstName)) { continue }
        $text = $text.Replace("$($demo.FirstName) $($demo.LastName)", "$($active.FirstName) $($active.LastName)")
    }
    for ($i = 0; $i -lt $DemoUsers.Count; $i++) {
        $demo = $DemoUsers[$i]
        $active = $ActiveUsers[$i]
        if ([string]::IsNullOrWhiteSpace($demo.FirstName) -or [string]::IsNullOrWhiteSpace($active.FirstName)) { continue }
        $text = $text -replace "\b$([regex]::Escape($demo.FirstName))\b", $active.FirstName
    }

    $messages = @()
    foreach ($block in ($text -split '(?m)^\s*---\s*$')) {
        if ($block -notmatch '(?m)^\*\*From:\*\*') { continue }

        $headers = @{}
        foreach ($name in "From", "To", "Subject", "Date") {
            if ($block -match "(?m)^\*\*$name\:\*\*\s*(.+?)\s*$") { $headers[$name] = $Matches[1] }
        }
        if (-not ($headers.From -and $headers.To -and $headers.Subject -and $headers.Date)) {
            throw "A message in $Path is missing a From, To, Subject or Date header."
        }

        # Body is everything after the Date header line.
        $body = ($block -replace '(?s)^.*?\*\*Date:\*\*[^\r\n]*\r?\n', '').Trim()

        $messages += [PSCustomObject]@{
            From    = $headers.From
            To      = @($headers.To -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            Subject = $headers.Subject
            Time    = ([datetime]::Parse($headers.Date)).TimeOfDay
            Body    = $body
        }
    }

    return $messages
}

function ConvertTo-EmailHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $paragraphs = $Text -split '(\r?\n){2,}' | Where-Object { $_.Trim() -and $_ -notmatch '^\r?\n$' }
    $html = foreach ($paragraph in $paragraphs) {
        $encoded = [System.Net.WebUtility]::HtmlEncode($paragraph.Trim())
        $encoded = $encoded -replace '\*\*(.+?)\*\*', '<b>$1</b>'
        "<p>$($encoded -replace '\r?\n', '<br>')</p>"
    }
    return "<html><body>$($html -join '')</body></html>"
}

function Add-InboxMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MailboxEmail,
        [Parameter(Mandatory = $true)]
        $From,
        [Parameter(Mandatory = $true)]
        $Recipients,
        [Parameter(Mandatory = $true)]
        [string]$Subject,
        [Parameter(Mandatory = $true)]
        [string]$BodyHtml,
        [Parameter(Mandatory = $true)]
        [datetime]$SentDate,
        [Parameter(Mandatory = $true)]
        [hashtable]$MailHeaders,
        [string]$InternetMessageId,
        [string]$InReplyTo,
        [string]$References,
        [string]$ConversationTopic,
        [string]$ConversationIndex
    )

    $sentUtc = $SentDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $message = @{
        subject                        = $Subject
        body                           = @{ contentType = "html"; content = $BodyHtml }
        from                           = @{ emailAddress = @{ name = $From.Name; address = $From.Email } }
        sender                         = @{ emailAddress = @{ name = $From.Name; address = $From.Email } }
        toRecipients                   = @($Recipients | ForEach-Object { @{ emailAddress = @{ name = $_.Name; address = $_.Email } } })
        categories                     = @($script:ImportedEmailCategory)
        singleValueExtendedProperties  = @(
            # PidTagMessageFlags = MSGFLAG_READ with MSGFLAG_UNSENT cleared, so this is received mail, not a draft.
            @{ id = "Integer 0x0E07"; value = "1" }
            # PidTagMessageDeliveryTime / PidTagClientSubmitTime: the received and sent timestamps.
            @{ id = "SystemTime 0x0E06"; value = $sentUtc }
            @{ id = "SystemTime 0x0039"; value = $sentUtc }
        )
    }
    if ($InternetMessageId) { $message.internetMessageId = $InternetMessageId }
    if ($ConversationTopic) { $message.singleValueExtendedProperties += @{ id = "String 0x0070"; value = $ConversationTopic } }
    if ($ConversationIndex) { $message.singleValueExtendedProperties += @{ id = "Binary 0x0071"; value = $ConversationIndex } }
    if ($InReplyTo) { $message.singleValueExtendedProperties += @{ id = "String 0x1042"; value = $InReplyTo } }
    if ($References) { $message.singleValueExtendedProperties += @{ id = "String 0x1039"; value = $References } }
    $body = $message | ConvertTo-Json -Depth 10

    $uri = "$graphBaseUrl/users/$MailboxEmail/mailFolders/inbox/messages"
    $maxAttempts = 6
    $delaySeconds = 20
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $uri -Headers $MailHeaders -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
            return $response.id
        }
        catch {
            $statusCode = [int]$_.Exception.Response.StatusCode
            if ($statusCode -eq 404 -and $attempt -lt $maxAttempts) {
                Write-InstallLogAction -Message "Mailbox for $MailboxEmail isn't provisioned yet, retrying email import in $delaySeconds seconds (attempt $attempt/$maxAttempts)..." -Level Warning
                Start-Sleep -Seconds $delaySeconds
            }
            else {
                if ($_.ErrorDetails.Message) { Write-InstallLogAction -Message "Response: $($_.ErrorDetails.Message)" -Level Warning }
                throw
            }
        }
    }
}

function Remove-InboxMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MailboxEmail,
        [Parameter(Mandatory = $true)]
        [string]$MessageId,
        [Parameter(Mandatory = $true)]
        [hashtable]$MailHeaders
    )

    try {
        Invoke-RestMethod -Uri "$graphBaseUrl/users/$MailboxEmail/messages/$MessageId" -Headers $MailHeaders -Method Delete | Out-Null
    }
    catch {
        # Already deleted (or the mailbox is gone) - nothing left to remove.
        if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
    }
}

function Import-UserEmails {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContentPath,
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        $DemoUsers,
        [Parameter(Mandatory = $true)]
        [hashtable]$MailHeaders
    )

    Write-InstallLogAction -Message "Importing email threads from $ContentPath..."
    $contentConfig = Get-Content -Path $ContentPath -Raw | ConvertFrom-Json
    $users = @($Settings.Users)

    function Find-EmailUser([string]$Name) {
        $user = $users | Where-Object { "$($_.FirstName) $($_.LastName)" -eq $Name } | Select-Object -First 1
        if ($user) { return [PSCustomObject]@{ Name = $Name; Email = $user.Email } }
        return $null
    }

    $today = (Get-Date).Date
    foreach ($site in $contentConfig.Sites) {
        foreach ($thread in @($site.Content.EmailThreads)) {
            if (-not $thread) { continue }
            $recorded = $null
            try {
                $messages = @(Get-EmailThreadMessages -Path $thread.Path -DemoUsers $DemoUsers -ActiveUsers $users)

                # Re-provisioning: delete the copies from the previous run (IDs recorded below) first.
                $previous = @($thread.Messages | Where-Object { $_ })
                $stillPresent = @()
                foreach ($entry in $previous) {
                    try { Remove-InboxMessage -MailboxEmail $entry.Mailbox -MessageId $entry.MessageId -MailHeaders $MailHeaders }
                    catch {
                        $stillPresent += $entry
                        Write-InstallLogAction -Message "Could not delete previous email in $($entry.Mailbox): $($_.Exception.Message)" -Level Warning
                    }
                }
                if ($previous.Count -gt 0) {
                    Write-InstallLogAction -Message "Removed $($previous.Count - $stillPresent.Count) previously imported message(s) for '$($thread.Title)'."
                }
                $recorded = @($stillPresent)

                $firstDay = $today.AddDays([int]$thread.CreatedOffset)
                $lastDay = $today.AddDays([int]$thread.ModifiedOffset)
                $span = ($lastDay - $firstDay).TotalDays

                $topic = if ($messages.Count -gt 0) { ($messages[0].Subject -replace '^\s*((RE|FW|FWD):\s*)+', '').Trim() } else { '' }
                $indexBytes = New-Object byte[] 22
                [System.Random]::new().NextBytes($indexBytes)
                $indexBytes[0] = 1
                $parentMessageId = $null
                $references = @()

                $imported = 0
                for ($i = 0; $i -lt $messages.Count; $i++) {
                    $message = $messages[$i]
                    $fraction = if ($messages.Count -gt 1) { $i / ($messages.Count - 1) } else { 0 }
                    $sentDate = $firstDay.AddDays([math]::Round($span * $fraction)).Add($message.Time)

                    $sender = Find-EmailUser $message.From
                    $recipients = @($message.To | ForEach-Object { Find-EmailUser $_ } | Where-Object { $_ })
                    if (-not $sender -or $recipients.Count -eq 0) {
                        Write-InstallLogAction -Message "Skipped '$($message.Subject)' in '$($thread.Title)': could not match sender '$($message.From)' or recipients '$($message.To -join ', ')' to a user." -Level Warning
                        continue
                    }

                    $bodyHtml = ConvertTo-EmailHtml -Text $message.Body

                    $internetMessageId = "<$([guid]::NewGuid().ToString('N'))@workiqstarterpack.local>"
                    # Conversation index: 22-byte thread header, plus a 5-byte child block per reply.
                    if ($i -gt 0) {
                        $indexBytes += [byte[]]@(0, 0, 0, 0, [byte]($i -band 0xFF))
                    }
                    $inReplyTo = $parentMessageId
                    $referenceChain = $references -join ' '

                    foreach ($recipient in $recipients) {
                        $messageId = Add-InboxMessage -MailboxEmail $recipient.Email -From $sender -Recipients $recipients `
                            -Subject $message.Subject -BodyHtml $bodyHtml -SentDate $sentDate -MailHeaders $MailHeaders `
                            -InternetMessageId $internetMessageId -InReplyTo $inReplyTo -References $referenceChain `
                            -ConversationTopic $topic -ConversationIndex ([Convert]::ToBase64String($indexBytes))
                        $recorded += [PSCustomObject]@{ Mailbox = $recipient.Email; MessageId = $messageId }
                        Write-InstallLogAction -Message "Delivered '$($message.Subject)' from $($sender.Email) to $($recipient.Email) (sent $($sentDate.ToString('yyyy-MM-dd HH:mm')))."
                        $imported++
                    }

                    $parentMessageId = $internetMessageId
                    $references += $internetMessageId
                }
                Write-InstallLogAction -Message "Imported email thread '$($thread.Title)' ($($messages.Count) messages, $imported inbox deliveries)." -Level Success
            }
            catch {
                Write-InstallLogAction -Message "Failed to import email thread '$($thread.Title)': $($_.Exception.Message)" -Level Error
            }
            finally {
                # Save the IDs even after a partial failure so a re-run / cleanup can still delete what was delivered.
                if ($null -ne $recorded) {
                    $thread | Add-Member -NotePropertyName Messages -NotePropertyValue @($recorded) -Force
                    $contentConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $ContentPath
                }
            }
        }
    }
}

function Remove-ImportedEmails {
    param(
        $Settings,
        [string]$ContentPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$MailHeaders
    )

    if ($ContentPath -and (Test-Path $ContentPath)) {
        Write-InstallLogAction -Message "Removing imported emails by recorded message ID..."
        $contentConfig = Get-Content -Path $ContentPath -Raw | ConvertFrom-Json
        $removed = 0
        foreach ($site in $contentConfig.Sites) {
            foreach ($thread in @($site.Content.EmailThreads)) {
                foreach ($entry in @($thread.Messages | Where-Object { $_ })) {
                    try {
                        Remove-InboxMessage -MailboxEmail $entry.Mailbox -MessageId $entry.MessageId -MailHeaders $MailHeaders
                        $removed++
                    }
                    catch {
                        Write-InstallLogAction -Message "Failed to remove email $($entry.MessageId) from $($entry.Mailbox): $($_.Exception.Message)" -Level Warning
                    }
                }
            }
        }
        Write-InstallLogAction -Message "Removed $removed imported email(s) by ID."
    }

    if (-not $Settings) { return }
    Write-InstallLogAction -Message "Sweeping remaining imported emails (category '$script:ImportedEmailCategory')..."
    foreach ($user in $Settings.Users) {
        try {
            $uri = "$graphBaseUrl/users/$($user.Email)/messages?`$filter=categories/any(c:c eq '$script:ImportedEmailCategory')&`$select=id&`$top=50"
            $removed = 0
            while ($uri) {
                $page = Invoke-RestMethod -Uri $uri -Headers $MailHeaders -Method Get
                foreach ($message in $page.value) {
                    Invoke-RestMethod -Uri "$graphBaseUrl/users/$($user.Email)/messages/$($message.id)" -Headers $MailHeaders -Method Delete | Out-Null
                    $removed++
                }
                # Deleting shifts the result set, so re-query from the start until nothing is left.
                $uri = if ($page.value.Count -gt 0) { $uri } else { $null }
            }
            Write-InstallLogAction -Message "Removed $removed imported email(s) from $($user.Email)."
        }
        catch {
            Write-InstallLogAction -Message "Failed to remove imported emails for $($user.Email): $($_.Exception.Message)" -Level Error
        }
    }
}

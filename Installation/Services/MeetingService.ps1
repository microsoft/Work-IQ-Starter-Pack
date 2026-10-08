Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-DocxParagraphs {
    # The text of each paragraph in a .docx's word/document.xml.
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $reader = New-Object System.IO.StreamReader($zip.GetEntry("word/document.xml").Open())
        try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally {
        $zip.Dispose()
    }

    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace("w", "http://schemas.openxmlformats.org/wordprocessingml/2006/main")
    foreach ($paragraph in $xml.SelectNodes("//w:p", $ns)) {
        (@($paragraph.SelectNodes(".//w:t", $ns) | ForEach-Object { $_.InnerText }) -join "")
    }
}

function Read-MeetingTranscript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $attendees = @()
    $cues = @()

    foreach ($line in (Get-DocxParagraphs -Path $Path)) {
        if ($line -match '^Attendees:\s*(.+)$') {
            # "Name (Job Title), Name (Job Title)" -> names only
            $attendees = @([regex]::Matches($Matches[1], '(?:^|,\s*)([^,()]+?)\s*\([^)]*\)') | ForEach-Object { $_.Groups[1].Value.Trim() })
        }
        elseif ($line -match '^\[(\d{2}):(\d{2}):(\d{2})\]\s*([^:]+?):\s*(.*)$') {
            $cues += [PSCustomObject]@{
                Seconds = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
                Speaker = $Matches[4].Trim()
                Text    = $Matches[5].Trim()
            }
        }
    }

    [PSCustomObject]@{ Attendees = $attendees; Cues = $cues }
}

function Add-TeamMeetings {
    <#
    Creates each of the site's backdated meetings on the team's group calendar
    (POST /groups/{id}/events - delegated Group.ReadWrite.All), uploads its transcript Word document (.docx)
    next to the site's documents, and returns one channel message per meeting that links to it.
    Graph has no API to write a real Teams transcript, so the link is how the transcript is attached.
    The messages are imported by Add-TeamsChatMessages (-ExtraMessages) in the chats' migration session.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config,
        # Provisioned users (real users when the demo users were not provisioned).
        [Parameter(Mandatory = $true)]
        $Settings,
        # The demo personas the transcript documents are written with.
        [Parameter(Mandatory = $true)]
        $DemoUsers
    )

    if (-not $Site.Content -or -not $Site.Content.Meetings -or @($Site.Content.Meetings).Count -eq 0) {
        return @()
    }

    $messages = @()

    try {
        $team = Get-PnPTeamsTeam -Identity $Site.URL -ErrorAction SilentlyContinue
        if (-not $team) {
            throw "No Teams team found for site '$($Site.URL)'. Run Add-TeamSite first."
        }
        $groupId = $team.GroupId

        $channelFolder = if ($Site.Channels -and $Site.Channels[0].Title) { $Site.Channels[0].Title } else { "General" }
        $targetFolder = "$channelFolder/Meeting Transcripts"
        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($Site.URL)"
        $siteConnection = Connect-PnPOnline -Url $siteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection

        # Demo persona name -> provisioned user (matched by position in the users list).
        $nameMap = @{}
        $emailByName = @{}
        for ($i = 0; $i -lt $DemoUsers.Count; $i++) {
            $demoName = "$($DemoUsers[$i].FirstName) $($DemoUsers[$i].LastName)"
            $nameMap[$demoName] = "$($Settings.Users[$i].FirstName) $($Settings.Users[$i].LastName)"
            $emailByName[$demoName] = $Settings.Users[$i].Email
        }

        # Name swaps for the transcripts: full names, plus first names that are unique among the demo personas.
        $nameSwaps = @{}
        for ($i = 0; $i -lt $DemoUsers.Count; $i++) {
            $demoName = "$($DemoUsers[$i].FirstName) $($DemoUsers[$i].LastName)"
            if ($nameMap[$demoName] -ne $demoName) { $nameSwaps[$demoName] = $nameMap[$demoName] }
            $sharedFirstName = @($DemoUsers | Where-Object { $_.FirstName -eq $DemoUsers[$i].FirstName }).Count -gt 1
            if (-not $sharedFirstName -and $Settings.Users[$i].FirstName -ne $DemoUsers[$i].FirstName) {
                $nameSwaps[$DemoUsers[$i].FirstName] = $Settings.Users[$i].FirstName
            }
        }

        foreach ($meeting in $Site.Content.Meetings) {
            try {
                $transcriptPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../$($meeting.TranscriptPath)"))
                $transcript = Read-MeetingTranscript -Path $transcriptPath
                if ($transcript.Cues.Count -eq 0) {
                    throw "No timestamped lines found in '$($meeting.TranscriptPath)'."
                }

                # Offsets are negative, so the meeting lands in the past. Times are UTC.
                $start = (Get-Date).Date.AddDays($meeting.StartOffset).Add([TimeSpan]::Parse($meeting.StartTime))
                $end = $start.AddMinutes($meeting.DurationMinutes)
                $dateText = $start.ToString("dddd, MMMM d, yyyy")

                # 1. Transcript .docx in the channel's Meeting Transcripts folder.
                $fileEntry = [PSCustomObject]@{
                    Title          = $meeting.Title
                    CreatedOffset  = $meeting.StartOffset
                    CreatedBy      = $meeting.Organizer
                    ModifiedOffset = $meeting.StartOffset
                    ModifiedBy     = $meeting.Organizer
                }
                # Swap the demo persona names (full, then first-name-only mentions) for the provisioned users' names
                # (a no-op when the demo users were installed). One regex pass, so a replacement is never re-replaced.
                $tempFolder = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString())
                $null = New-Item -Path $tempFolder -ItemType Directory
                $tempFile = Join-Path -Path $tempFolder -ChildPath ([System.IO.Path]::GetFileName($transcriptPath))
                try {
                    Copy-Item -Path $transcriptPath -Destination $tempFile
                    if ($nameSwaps.Count -gt 0) {
                        $pattern = '\b(?:' + ((($nameSwaps.Keys | Sort-Object -Property Length -Descending) | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\b'
                        $zip = [System.IO.Compression.ZipFile]::Open($tempFile, [System.IO.Compression.ZipArchiveMode]::Update)
                        try {
                            $entry = $zip.GetEntry("word/document.xml")
                            $reader = New-Object System.IO.StreamReader($entry.Open())
                            try { $documentXml = $reader.ReadToEnd() } finally { $reader.Dispose() }
                            $entry.Delete()
                            $documentXml = [regex]::Replace($documentXml, $pattern, { param($m) $nameSwaps[$m.Value] }.GetNewClosure())
                            $newEntry = $zip.CreateEntry("word/document.xml")
                            $writer = New-Object System.IO.StreamWriter($newEntry.Open(), (New-Object System.Text.UTF8Encoding($false)))
                            try { $writer.Write($documentXml) } finally { $writer.Dispose() }
                        }
                        finally {
                            $zip.Dispose()
                        }
                    }
                    $uploaded = Import-SiteDocument -SiteUrl $siteUrl -File $fileEntry -Connection $siteConnection -TargetFolder $targetFolder -LocalPath $tempFile
                }
                finally {
                    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue
                }
                $transcriptUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com$($uploaded.ServerRelativeUrl)"

                # 2. The meeting itself, on the team's calendar.
                $attendees = @(foreach ($name in $transcript.Attendees) {
                        if ($emailByName.ContainsKey($name)) {
                            @{ emailAddress = @{ address = $emailByName[$name]; name = $nameMap[$name] }; type = "required" }
                        }
                    })
                $attendeeNames = @($transcript.Attendees | ForEach-Object { if ($nameMap.ContainsKey($_)) { $nameMap[$_] } else { $_ } })
                $encode = { param($text) [System.Net.WebUtility]::HtmlEncode($text) }
                $transcriptLink = "<a href=`"$transcriptUrl`">$(& $encode $meeting.Title) - transcript</a>"

                $escapedSubject = $meeting.Title.Replace("'", "''")
                $existing = (Invoke-RestMethod -Uri "$graphBaseUrl/groups/$groupId/events?`$filter=subject eq '$escapedSubject'&`$select=id,subject" -Headers $headers -Method Get).value | Select-Object -First 1

                if ($existing) {
                    Write-InstallLogAction -Message "Meeting '$($meeting.Title)' already exists on the '$($Site.URL)' calendar - skipping creation."
                    $calendarEvent = Invoke-RestMethod -Uri "$graphBaseUrl/groups/$groupId/events/$($existing.id)?`$select=id,onlineMeeting,onlineMeetingUrl" -Headers $headers -Method Get
                }
                else {
                    $eventBody = @{
                        subject                = $meeting.Title
                        body                   = @{
                            contentType = "html"
                            content     = "<p>Attendees: $(& $encode ($attendeeNames -join ', '))</p><p>Transcript: $transcriptLink</p>"
                        }
                        start                  = @{ dateTime = $start.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = "UTC" }
                        end                    = @{ dateTime = $end.ToString("yyyy-MM-ddTHH:mm:ss"); timeZone = "UTC" }
                        attendees              = $attendees
                        isOnlineMeeting        = $true
                        onlineMeetingProvider  = "teamsForBusiness"
                    } | ConvertTo-Json -Depth 8

                    $calendarEvent = Invoke-RestMethod -Uri "$graphBaseUrl/groups/$groupId/events" -Headers $headers -Method Post -ContentType "application/json" -Body $eventBody
                    if (-not $calendarEvent.id) {
                        throw "Graph returned no event id when creating the meeting."
                    }
                    Write-InstallLogAction -Message "Created meeting '$($meeting.Title)' ($dateText) on the '$($Site.URL)' calendar."
                }

                $joinUrl = if ($calendarEvent.onlineMeeting -and $calendarEvent.onlineMeeting.joinUrl) { $calendarEvent.onlineMeeting.joinUrl } else { $calendarEvent.onlineMeetingUrl }
                if (-not $joinUrl) {
                    Write-InstallLogAction -Message "No Teams join link was returned for '$($meeting.Title)' - group calendar events may not support online meetings." -Level Warning
                }

                # 3. The channel message that links the transcript, sent as the organizer just after the meeting ends.
                $organizerUser = $Settings.Users | Where-Object { $_.Email -eq $meeting.Organizer } | Select-Object -First 1
                if (-not $organizerUser) {
                    throw "The organizer '$($meeting.Organizer)' is not in the provisioned users list."
                }
                $joinHtml = if ($joinUrl) { "<p><a href=`"$joinUrl`">Join link</a></p>" } else { "" }
                $html = "<p><b>Meeting: $(& $encode $meeting.Title)</b> - $dateText, $($start.ToString('h:mm tt')) UTC</p>" +
                "<p>Attendees: $(& $encode ($attendeeNames -join ', '))</p>$joinHtml<p>Transcript: $transcriptLink</p>"

                $messages += [PSCustomObject]@{
                    Timestamp = $end.AddMinutes(2)
                    Sender    = "$($organizerUser.FirstName) $($organizerUser.LastName)"
                    Message   = "Meeting: $($meeting.Title)"
                    Html      = $html
                    ChatTitle = "Meeting: $($meeting.Title)"
                    Members   = @()
                }
            }
            catch {
                Write-InstallLogAction -Message "Failed to provision meeting '$($meeting.Title)' for site '$($Site.URL)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
            }
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to provision meetings for site '$($Site.URL)': $($_.Exception.Message)" -Level Error
    }

    return $messages
}

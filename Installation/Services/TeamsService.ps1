function Add-TeamSite {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config
    )

    # Returns $true when the team is ready, $false on failure so the caller can skip the site's other steps.
    try {
        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($Site.URL)"
        $existingTeam = Get-PnPTeamsTeam -Identity $Site.URL -ErrorAction SilentlyContinue

        if (-not $existingTeam) {
            $visibility = if ($Site.IsPublic) { "Public" } else { "Private" }
            $teamParams = @{
                DisplayName  = $Site.Title
                MailNickName = $Site.URL
                Description  = $Site.Description
                Visibility   = $visibility
            }

            New-PnPTeamsTeam @teamParams | Out-Null
            $groupId = Wait-ForTeamProvisioned -SiteUrl $siteUrl -MailNickName $Site.URL
            Add-TeamAccess -GroupId $groupId -Site $Site | Out-Null
            Add-TeamChannels -GroupId $groupId -Site $Site | Out-Null
            Write-InstallLogAction -Message "Created site '$($Site.Title)' at $siteUrl"
        }
        else {
            Write-InstallLogAction -Message "Team for site '$($Site.URL)' already exists, skipping creation."
            $groupId = $existingTeam.GroupId

            # Channels only need the team, so create any missing ones before waiting on the SharePoint site -
            # a slow or half-provisioned site must not leave a previously created team without its channels.
            Add-TeamChannels -GroupId $groupId -Site $Site | Out-Null
            try {
                $null = Wait-ForTeamProvisioned -SiteUrl $siteUrl -MailNickName $Site.URL
            }
            catch {
                Write-InstallLogAction -Message "Team '$($Site.URL)' exists but is not fully provisioned: $($_.Exception.Message)" -Level Warning
            }
            Remove-TeamAccess -GroupId $groupId -Site $Site | Out-Null
            Add-TeamAccess -GroupId $groupId -Site $Site | Out-Null
        }
        Remove-DefaultChannelTabs -GroupId $groupId -Site $Site
        return $true
    }
    catch {
        Write-InstallLogAction -Message "Failed to create team (Add-TeamSite). '$($Site.URL)': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Add-TeamChannels {
    param(
        [Parameter(Mandatory = $true)]
        $GroupId,
        [Parameter(Mandatory = $true)]
        $Site
    )

    foreach ($channel in $Site.Channels) {
        try {
            $existingChannel = Get-PnPTeamsChannel -Team $GroupId -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq $channel.Title }
            if ($existingChannel) {
                Write-InstallLogAction -Message "Channel '$($channel.Title)' already exists in site '$($Site.URL)', skipping creation."
                continue
            }

            Add-PnPTeamsChannel -Team $GroupId -DisplayName $channel.Title -Description $channel.Description | Out-Null
            Write-InstallLogAction -Message "Added channel '$($channel.Title)' to site '$($Site.URL)'."
        }
        catch {
            Write-InstallLogAction -Message "Failed to add channel '$($channel.Title)' to site '$($Site.URL)': $($_.Exception.Message)" -Level Error
        }
    }
}

function Remove-DefaultChannelTabs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GroupId,
        [Parameter(Mandatory = $true)]
        $Site
    )

    # Removes the default Notes (OneNote) and Loop ("Page") tabs from every channel of the team.
    try {
        $channels = (Invoke-RestMethod -Uri "$graphBaseUrl/teams/$GroupId/channels" -Headers $headers -Method Get).value
        foreach ($channel in $channels) {
            $tabsUri = "$graphBaseUrl/teams/$GroupId/channels/$($channel.id)/tabs"
            $tabs = (Invoke-RestMethod -Uri "$tabsUri`?`$expand=teamsApp" -Headers $headers -Method Get).value
            Write-InstallLogAction -Message "Tabs in channel '$($channel.displayName)' of site '$($Site.URL)': $(($tabs | ForEach-Object { "$($_.displayName) [app: $($_.teamsApp.displayName)]" }) -join '; ')"
            foreach ($tab in $tabs) {
                $appName = $tab.teamsApp.displayName
                if ($appName -notin @("OneNote", "Wiki", "Page") -and $tab.displayName -notin @("Notes", "Wiki", "Page")) {
                    continue
                }
                try {
                    Invoke-RestMethod -Uri "$tabsUri/$($tab.id)" -Headers $headers -Method Delete | Out-Null
                    Write-InstallLogAction -Message "Removed tab '$($tab.displayName)' from channel '$($channel.displayName)' in site '$($Site.URL)'."
                }
                catch {
                    Write-InstallLogAction -Message "Could not remove tab '$($tab.displayName)' from channel '$($channel.displayName)' in site '$($Site.URL)': $($_.Exception.Message)" -Level Warning
                }
            }
        }
    }
    catch {
        Write-InstallLogAction -Message "Failed to remove default tabs for site '$($Site.URL)': $($_.Exception.Message)" -Level Warning
    }
}

function Add-ChannelTab {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TeamId,
        [Parameter(Mandatory = $true)]
        [string]$ChannelId,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [Parameter(Mandatory = $true)]
        [string]$WebUrl,
        [Parameter(Mandatory = $true)]
        [ValidateSet("List", "Library")]
        [string]$Kind,
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )

    # Lists use the Lists Teams app; libraries use the SharePoint Teams app. Look the app up by name
    # in the app catalog rather than hard-coding an ID.
    $appName = if ($Kind -eq "List") { "Lists" } else { "SharePoint" }
    $tabsUri = "$graphBaseUrl/teams/$TeamId/channels/$ChannelId/tabs"

    try {
        $teamsAppId = (Invoke-RestMethod -Uri "$graphBaseUrl/appCatalogs/teamsApps?`$filter=displayName eq '$appName' and distributionMethod eq 'store'" -Headers $headers -Method Get).value |
            Select-Object -First 1 -ExpandProperty id
        if (-not $teamsAppId) {
            throw "The '$appName' Teams app was not found in the app catalog."
        }

        $existingTabs = (Invoke-RestMethod -Uri "$tabsUri`?`$expand=teamsApp" -Headers $headers -Method Get).value
        foreach ($existingTab in @($existingTabs | Where-Object { $_.displayName -eq $DisplayName })) {
            if ($existingTab.teamsApp.id -eq $teamsAppId) {
                Write-InstallLogAction -Message "Tab '$DisplayName' already exists in the channel, skipping."
                return
            }
            # Same name but a different app (e.g. created by an earlier run with the wrong app) - replace it.
            Invoke-RestMethod -Uri "$tabsUri/$($existingTab.id)" -Headers $headers -Method Delete | Out-Null
            Write-InstallLogAction -Message "Removed tab '$DisplayName' that used the wrong app ($($existingTab.teamsApp.displayName))."
        }

        $encodedUrl = [System.Uri]::EscapeDataString($WebUrl)
        $body = @{
            displayName          = $DisplayName
            "teamsApp@odata.bind" = "https://graph.microsoft.com/v1.0/appCatalogs/teamsApps/$teamsAppId"
            configuration        = @{
                entityId   = ""
                contentUrl = "$SiteUrl/_layouts/15/teamslogon.aspx?spfx=true&dest=$encodedUrl"
                removeUrl  = $null
                websiteUrl = $WebUrl
            }
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Uri $tabsUri -Headers $headers -Method Post -ContentType "application/json" -Body $body | Out-Null
        Write-InstallLogAction -Message "Added $Kind tab '$DisplayName' to the channel."
    }
    catch {
        Write-InstallLogAction -Message "Failed to add $Kind tab '$DisplayName': $($_.Exception.Message)" -Level Warning
    }
}

function Remove-Teams {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContentPath,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $contentConfig = Get-Content -Path $ContentPath -Raw | ConvertFrom-Json

    # Sites that could not be fully removed, so the caller can tell the admin to finish them by hand
    $script:sitesNotRemoved = [System.Collections.Generic.List[object]]::new()

    foreach ($site in $contentConfig.Sites) {
        $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
        try {

            $existingTeam = Get-PnPTeamsTeam -Identity $site.URL -ErrorAction SilentlyContinue
            if (-not $existingTeam) {
                $existingTeam = Get-PnPTeamsTeam -ErrorAction SilentlyContinue | Where-Object { $_.MailNickName -eq $site.URL } | Select-Object -First 1
            }

            # Deleted items take time to show up in the bins, so only poll after a team was removed.
            $waitForBins = $false
            if ($existingTeam) {
                Remove-PnPTeamsTeam -Identity $existingTeam.GroupId -Force
                Write-InstallLogAction "Removed Team '$($site.Title)' ($($site.URL)) and its Microsoft 365 group."
                $waitForBins = $true
            }
            else {
                Write-InstallLogAction "Team for site '$($site.URL)' does not exist, skipping deletion."
            }

            $deadline = (Get-Date).AddMinutes(3)
            do {
                $deletedGroup = Get-PnPDeletedMicrosoft365Group -ErrorAction SilentlyContinue | Where-Object { $_.MailNickname -eq $site.URL } | Select-Object -First 1
                if (-not $deletedGroup -and $waitForBins) { Start-Sleep -Seconds 10 }
            } while (-not $deletedGroup -and $waitForBins -and (Get-Date) -lt $deadline)

            if ($deletedGroup) {
                Remove-PnPDeletedMicrosoft365Group -Identity $deletedGroup.Id
                Write-InstallLogAction "Purged group '$($site.URL)' from the deleted groups bin."
            }
            elseif ($waitForBins) {
                Write-InstallLogAction "Group '$($site.URL)' did not appear in the deleted groups bin in time." -Level Warning
            }

            # The site can stay bound to the deleted group for a while, so keep retrying the removal
            # until it leaves active use (or was never there).
            $deadline = (Get-Date).AddMinutes(5)
            $siteInactive = $false
            do {
                $activeSite = Get-PnPTenantSite -Identity $siteUrl -ErrorAction SilentlyContinue
                if (-not $activeSite) {
                    $siteInactive = $true
                    break
                }

                try {
                    Remove-PnPTenantSite -Url $siteUrl -Force -ErrorAction Stop
                    Write-InstallLogAction "Removed site '$($site.Title)' from active sites at $siteUrl."
                    $siteInactive = $true
                }
                catch {
                    if (-not $waitForBins) { break }
                    Start-Sleep -Seconds 10
                }
            } while (-not $siteInactive -and (Get-Date) -lt $deadline)

            if (-not $siteInactive) {
                Write-InstallLogAction "Site '$siteUrl' could not be removed from active sites in time." -Level Warning
                $script:sitesNotRemoved.Add([PSCustomObject]@{ Title = $site.Title; Url = $siteUrl; Reason = "Still an active site" })
                continue
            }

            $deadline = (Get-Date).AddMinutes(2)
            do {
                $deletedSite = Get-PnPTenantDeletedSite -Identity $siteUrl -ErrorAction SilentlyContinue
                if (-not $deletedSite -and $waitForBins) { Start-Sleep -Seconds 10 }
            } while (-not $deletedSite -and $waitForBins -and (Get-Date) -lt $deadline)

            if ($deletedSite) {
                Remove-PnPTenantDeletedSite -Identity $siteUrl -Force
                Write-InstallLogAction "Purged site '$($site.Title)' from the tenant recycle bin at $siteUrl."
            }
            elseif ($waitForBins) {
                Write-InstallLogAction "Site '$siteUrl' did not appear in the tenant recycle bin in time." -Level Warning
                $script:sitesNotRemoved.Add([PSCustomObject]@{ Title = $site.Title; Url = $siteUrl; Reason = "Removed from active sites but not confirmed purged from the tenant recycle bin" })
            }
        }
        catch {
            Write-InstallLogAction "Failed to remove site '$($site.URL)': $($_.Exception.Message)" -Level Error
            $script:sitesNotRemoved.Add([PSCustomObject]@{ Title = $site.Title; Url = $siteUrl; Reason = "Error: $($_.Exception.Message)" })
        }
    }
}

function Wait-ForTeamProvisioned {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,
        [Parameter(Mandatory = $true)]
        [string]$MailNickName
    )

    $pollIntervalSeconds = 5
    $timeoutSeconds = 300
    $elapsedSeconds = 0
    $site = $null
    $groupId = $null

    do {
        $team = Get-PnPTeamsTeam -Identity $MailNickName -ErrorAction SilentlyContinue
        if (-not $team) {
            $team = Get-PnPTeamsTeam -ErrorAction SilentlyContinue | Where-Object { $_.MailNickName -eq $MailNickName } | Select-Object -First 1
        }
        $groupId = $team.GroupId

        if (-not $groupId) {
            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds
        }
    } while (-not $groupId -and $elapsedSeconds -lt $timeoutSeconds)

    if (-not $groupId) {
        throw "The team '$MailNickName' was not created after waiting $timeoutSeconds seconds."
    }

    $elapsedSeconds = 0

    do {
        $site = Get-PnPTenantSite -Url $SiteUrl -ErrorAction SilentlyContinue

        if (-not $site) {
            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds
        }
    } while (-not $site -and $elapsedSeconds -lt $timeoutSeconds)

    if (-not $site) {
        throw "The SharePoint site at '$SiteUrl' was not provisioned after waiting $timeoutSeconds seconds."
    }

    $elapsedSeconds = 0
    do {
        $channels = Get-PnPTeamsChannel -Team $groupId -ErrorAction SilentlyContinue
        if (-not $channels) {
            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds
        }
    } while (-not $channels -and $elapsedSeconds -lt $timeoutSeconds)

    if (-not $channels) {
        throw "The team '$MailNickName' has no channels after waiting $timeoutSeconds seconds."
    }

    return $groupId
}

function Add-TeamAccess {
    param(
        [Parameter(Mandatory = $true)]
        $GroupId,
        [Parameter(Mandatory = $true)]
        $Site
    )

    foreach ($ownerEmail in $Site.Owners) {
        Add-GroupRoleMember -GroupId $GroupId -Site $Site -Email $ownerEmail -Role Owner
    }

    foreach ($memberEmail in $Site.Members) {
        Add-GroupRoleMember -GroupId $GroupId -Site $Site -Email $memberEmail -Role Member
    }
}

function Remove-TeamAccess {
    param(
        [Parameter(Mandatory = $true)]
        $GroupId,
        [Parameter(Mandatory = $true)]
        $Site
    )

    $currentUserUpn = Get-CurrentUserUpn

    foreach ($role in @("Owner", "Member")) {
        $roleLower = $role.ToLower()

        try {
            $existingUsers = & "Get-PnPAzureADGroup$role" -Identity $GroupId

            foreach ($user in ($existingUsers | Where-Object { $_.UserPrincipalName -ne $currentUserUpn })) {
                $identifier = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.Id }
                try {
                    if ($user.UserPrincipalName) {
                        & "Remove-PnPAzureADGroup$role" -Identity $GroupId -Users $user.UserPrincipalName
                    }
                    else {
                        & "Remove-PnPAzureADGroup$role" -Identity $GroupId -MemberObjectId $user.Id
                    }
                    Write-InstallLogAction -Message "Removed $identifier as a $roleLower of site '$($Site.URL)'."
                }
                catch {
                    Write-Host "Failed to remove $roleLower $($identifier): $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        catch {
            Write-Host "Failed to list ${roleLower}s for site '$($Site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Get-CurrentUserUpn {
    (Invoke-RestMethod -Uri "$graphBaseUrl/me?`$select=userPrincipalName" -Headers $headers -Method Get).userPrincipalName
}

function Add-GroupRoleMember {
    param(
        [Parameter(Mandatory = $true)]
        $GroupId,
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Owner", "Member")]
        [string]$Role
    )

    $roleLower = $Role.ToLower()

    try {
        & "Add-PnPAzureADGroup$Role" -Identity $GroupId -Users $Email
        Write-InstallLogAction -Message "Added $Email as a $roleLower of site '$($Site.URL)'."
    }
    catch {
        if ($_.Exception.Message -match "already exist") {
            Write-InstallLogAction -Message "$Email is already a $roleLower of site '$($Site.URL)'."
        }
        else {
            Write-Host "Failed to add $roleLower $($Email): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

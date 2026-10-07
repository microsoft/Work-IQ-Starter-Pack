function Add-TeamSite {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ContentPath,
        [Parameter(Mandatory = $true)]
        $Config
    )

    $contentConfig = Get-Content -Path $ContentPath -Raw | ConvertFrom-Json

    foreach ($site in $contentConfig.Sites) {
        try {
            $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
            $existingTeam = Get-PnPTeamsTeam -Identity $site.URL -ErrorAction SilentlyContinue

            if (-not $existingTeam) {
                $visibility = if ($site.IsPublic) { "Public" } else { "Private" }
                $teamParams = @{
                    DisplayName  = $site.Title
                    MailNickName = $site.URL
                    Description  = $site.Description
                    Visibility   = $visibility
                }

                New-PnPTeamsTeam @teamParams | Out-Null
                $groupId = Wait-ForTeamProvisioned -SiteUrl $siteUrl -MailNickName $site.URL
                Add-TeamAccess -GroupId $groupId -Site $site
                Add-TeamChannels -GroupId $groupId -Site $site
                Write-InstallLogAction -Message "Created site '$($site.Title)' at $siteUrl"
            }
            else {
                Write-InstallLogAction -Message "Team for site '$($site.URL)' already exists, skipping creation."
                $groupId = Wait-ForTeamProvisioned -SiteUrl $siteUrl -MailNickName $site.URL
                Remove-TeamAccess -GroupId $groupId -Site $site
                Add-TeamAccess -GroupId $groupId -Site $site
                Add-TeamChannels -GroupId $groupId -Site $site
            }
        }
        catch {
            Write-Host "Failed to create team (Add-TeamSite). '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
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
            Write-Host "Failed to add channel '$($channel.Title)' to site '$($Site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
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

    foreach ($site in $contentConfig.Sites) {
        try {
            $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"

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

            $deadline = (Get-Date).AddMinutes(5)
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
            }
        }
        catch {
            Write-InstallLogAction "Failed to remove site '$($site.URL)': $($_.Exception.Message)" -Level Error
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
    $timeoutSeconds = 120
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

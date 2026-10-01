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
                Wait-ForTeamProvisioned -SiteUrl $siteUrl

                $groupId = (Get-PnPTeamsTeam -Identity $site.URL).GroupId
                Add-SiteAccess -GroupId $groupId -Site $site
                Add-TeamChannels -GroupId $groupId -Site $site
                Write-InstallLogAction -Message "Created site '$($site.Title)' at $siteUrl"
            }
            else {
                Write-InstallLogAction -Message "Team for site '$($site.URL)' already exists, skipping creation."
                $groupId = $existingTeam.GroupId
                Wait-ForTeamProvisioned -SiteUrl $siteUrl
                Remove-SiteAccess -GroupId $groupId -Site $site
                Add-SiteAccess -GroupId $groupId -Site $site
                Add-TeamChannels -GroupId $groupId -Site $site
            }
        }
        catch {
            Write-Host "Failed to process site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
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

function Remove-Sites {
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

            if ($existingTeam) {
                Remove-PnPTeamsTeam -Identity $existingTeam.GroupId -Force
                Write-InstallLogAction "Removed Team '$($site.Title)' ($($site.URL)) and its Microsoft 365 group."
            }
            else {
                Write-InstallLogAction "Team for site '$($site.URL)' does not exist, skipping deletion."
            }

            $deletedGroup = Get-PnPDeletedMicrosoft365Group -ErrorAction SilentlyContinue | Where-Object { $_.MailNickname -eq $site.URL } | Select-Object -First 1
            if ($deletedGroup) {
                Remove-PnPDeletedMicrosoft365Group -Identity $deletedGroup.Id
                Write-InstallLogAction "Purged group '$($site.URL)' from the deleted groups bin."
            }

            $deletedSite = Get-PnPTenantDeletedSite -Identity $siteUrl -ErrorAction SilentlyContinue
            if ($deletedSite) {
                Remove-PnPTenantDeletedSite -Identity $siteUrl -Force
                Write-InstallLogAction "Purged site '$($site.Title)' from the tenant recycle bin at $siteUrl."
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
        [string]$SiteUrl
    )

    $pollIntervalSeconds = 5
    $timeoutSeconds = 120
    $elapsedSeconds = 0
    $site = $null

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
}

function Add-SiteAccess {
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

function Remove-SiteAccess {
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

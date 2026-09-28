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

            $siteOwners = @()
            foreach ($owner in $site.Owners) {
                $siteOwners += $owner
            }
            $currentUserUpn = Get-CurrentUserUpn
            if ($currentUserUpn -and ($siteOwners -notcontains $currentUserUpn)) {
                $siteOwners += $currentUserUpn
            }

            $siteMembers = @()
            foreach ($member in $site.Members) {
                $siteMembers += $member
            }
            
            if (-not $existingTeam) {
                $visibility = if ($site.IsPublic) { "Public" } else { "Private" }
                $teamParams = @{
                    DisplayName  = $site.Title
                    MailNickName = $site.URL
                    Description  = $site.Description
                    Visibility   = $visibility
                }
                
                $teamParams.Owners = $siteOwners
                $teamParams.Members = $siteMembers

                New-PnPTeamsTeam @teamParams | Out-Null
                Wait-ForSiteProvisioned -SiteUrl $siteUrl
                Write-InstallLogAction -Message "Created site '$($site.Title)' at $siteUrl"
            }
            else {
                Write-InstallLogAction -Message "Team for site '$($site.URL)' already exists, skipping creation."
                $groupId = $existingTeam.GroupId
                Wait-ForSiteProvisioned -SiteUrl $siteUrl
                Remove-SiteAccess -GroupId $groupId -Site $site
                Add-SiteAccess -GroupId $groupId -Site $site
            }
        }
        catch {
            Write-Host "Failed to process site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Remove-Sites {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($site in $Config.Sites) {
        try {
            $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
            $existingSite = Get-PnPTenantSite -Url $siteUrl -ErrorAction SilentlyContinue

            if ($existingSite) {
                Remove-PnPTenantSite -Url $siteUrl -Force
                Write-Host "Removed site '$($site.Title)' at $siteUrl."
            }
            else {
                Write-Host "Site with URL '$($site.URL)' does not exist, skipping deletion."
            }

            # Remove-PnPTenantSite only soft-deletes the site into the tenant recycle bin, so purge it
            # from there too - but only this demo's own site URL, never a blanket recycle bin sweep.
            $deletedSite = Get-PnPTenantDeletedSite -Identity $siteUrl -ErrorAction SilentlyContinue

            if ($deletedSite) {
                Remove-PnPTenantDeletedSite -Identity $siteUrl -Force
                Write-Host "Purged site '$($site.Title)' from the tenant recycle bin at $siteUrl."
            }
        }
        catch {
            Write-Host "Failed to remove site '$($site.URL)': $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Wait-ForSiteProvisioned {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )

    # New-PnPTeamsTeam returns as soon as the group/Team is created, but the backing SharePoint
    # site is provisioned asynchronously afterward - poll for it before callers (e.g.
    # Import-SiteDocuments) try to connect directly to $SiteUrl.
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

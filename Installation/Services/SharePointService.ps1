function Add-Sites {
    param(
        [Parameter(Mandatory = $true)]
        $ContentConfig,
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($site in $ContentConfig.Sites) {
        try {
            $siteUrl = "https://$($Config.Settings.TenantPrefix).sharepoint.com/sites/$($site.URL)"
            $existingSite = Get-PnPTenantSite -Url $siteUrl -ErrorAction SilentlyContinue

            if (-not $existingSite) {
                $groupId = New-TeamsSite -Site $site -Config $Config -SiteUrl $siteUrl
                Write-InstallLogAction -Message "Created site '$($site.Title)' at $siteUrl"
            }
            else {
                Write-InstallLogAction -Message "Site with URL '$($site.URL)' already exists, skipping creation."
                $groupId = Get-SiteGroupId -Site $site
                Set-SiteTeamsConnection -Site $site -Config $Config -SiteUrl $siteUrl -GroupId $groupId
                Remove-SiteAccess -GroupId $groupId -Site $site
            }

            Add-SiteAccess -GroupId $groupId -Site $site
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

function New-TeamsSite {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl
    )

    New-PnPSite -Type TeamSite -Title $Site.Title -Alias $Site.URL -Description $Site.Description `
        -IsPublic:([bool]$Site.IsPublic) -Wait

    $groupId = Get-SiteGroupId -Site $Site
    Set-SiteTeamsConnection -Site $Site -Config $Config -SiteUrl $SiteUrl -GroupId $groupId

    return $groupId
}

function Get-SiteGroupId {
    param(
        [Parameter(Mandatory = $true)]
        $Site
    )

    # The backing M365 group can take a little while to become queryable via Graph after site creation, so poll for it.
    $pollIntervalSeconds = 5
    $timeoutSeconds = 120
    $elapsedSeconds = 0
    $group = $null

    do {
        $group = (Invoke-RestMethod -Uri "$graphBaseUrl/groups?`$filter=mailNickname eq '$($Site.URL)'" -Headers $headers -Method Get).value | Select-Object -First 1

        if (-not $group) {
            Start-Sleep -Seconds $pollIntervalSeconds
            $elapsedSeconds += $pollIntervalSeconds
        }
    } while (-not $group -and $elapsedSeconds -lt $timeoutSeconds)

    if (-not $group) {
        throw "The Microsoft 365 group backing site '$($Site.URL)' could not be found after waiting $timeoutSeconds seconds."
    }

    return $group.id
}

function Set-SiteTeamsConnection {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [string]$SiteUrl,
        [Parameter(Mandatory = $true)]
        $GroupId
    )

    if (-not $Site.EnableMicrosoftTeams) {
        return
    }

    $group = Invoke-RestMethod -Uri "$graphBaseUrl/groups/$GroupId`?`$select=resourceProvisioningOptions" -Headers $headers -Method Get

    if ($group.resourceProvisioningOptions -contains "Team") {
        Write-Host "Microsoft Teams is already connected to site '$($Site.URL)'."
        return
    }

    $siteConnection = Connect-PnPOnline -Url $SiteUrl -ClientId $Config.Settings.ClientId -Interactive -ReturnConnection
    Add-PnPTeamsTeam -Connection $siteConnection
    Write-Host "Enabled Microsoft Teams on site '$($Site.URL)'."
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

    # Exclude the currently signed-in admin so a reset never revokes the access of whoever is
    # running the install - they may be a group owner from having created/administered the site
    # without being listed in the site's config Owners.
    $currentUserId = (Invoke-RestMethod -Uri "$graphBaseUrl/me?`$select=id" -Headers $headers -Method Get).id

    foreach ($refCollection in @("owners", "members")) {
        $roleLower = if ($refCollection -eq "owners") { "owner" } else { "member" }

        try {
            $existingRefs = (Invoke-RestMethod -Uri "$graphBaseUrl/groups/$GroupId/$refCollection`?`$select=id,userPrincipalName" -Headers $headers -Method Get).value

            foreach ($ref in ($existingRefs | Where-Object { $_.id -ne $currentUserId })) {
                $identifier = if ($ref.userPrincipalName) { $ref.userPrincipalName } else { $ref.id }
                try {
                    Invoke-RestMethod -Uri "$graphBaseUrl/groups/$GroupId/$refCollection/$($ref.id)/`$ref" -Headers $headers -Method Delete
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

    # The owners endpoint only accepts users/servicePrincipals, so it must be referenced via /users/{id};
    # the members endpoint accepts multiple object types and is referenced via the generic /directoryObjects/{id}.
    $refCollection = if ($Role -eq "Owner") { "owners" } else { "members" }
    $refSegment = if ($Role -eq "Owner") { "users" } else { "directoryObjects" }
    $roleLower = $Role.ToLower()

    try {
        $user = Invoke-RestMethod -Uri "$graphBaseUrl/users/$Email" -Headers $headers -Method Get
        $body = @{ "@odata.id" = "$graphBaseUrl/$refSegment/$($user.id)" } | ConvertTo-Json
        Invoke-RestMethod -Uri "$graphBaseUrl/groups/$GroupId/$refCollection/`$ref" -Headers $headers -Method Post -ContentType "application/json" -Body $body
        Write-InstallLogAction -Message "Added $Email as a $roleLower of site '$($Site.URL)'."
    }
    catch {
        if ($_.ErrorDetails.Message -match "already exist") {
            Write-InstallLogAction -Message "$Email is already a $roleLower of site '$($Site.URL)'."
        }
        else {
            Write-Host "Failed to add $roleLower $($Email): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

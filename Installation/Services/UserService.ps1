function Resolve-RealUsers {
    param(
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        [hashtable]$RealUserUpns
    )

    foreach ($index in $RealUserUpns.Keys) {
        $upn = $RealUserUpns[$index]
        $graphUser = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,givenName,surname,jobTitle,department,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

        if (-not $graphUser) {
            throw "Could not find a user with UPN '$upn' in Entra ID. Please verify the UPN and try again."
        }

        $entry = $Settings.Users[$index]
        $entry.FirstName = $graphUser.givenName
        $entry.LastName = $graphUser.surname
        $entry.JobTitle = $graphUser.jobTitle
        $entry.Department = $graphUser.department
        $entry.Email = $graphUser.userPrincipalName
        $entry.UserPrincipalName = ($graphUser.userPrincipalName -split '@')[0]
        if (-not [string]::IsNullOrWhiteSpace($graphUser.usageLocation)) {
            $entry.UsageLocation = $graphUser.usageLocation
        }
        # DynamicsLicenses is left as-is: it reflects which role slots should get Dynamics
        # licenses per the starter pack's plan, not a fact pulled from Entra ID.
    }

    return $Settings
}

function Add-Users {
    param(
        [Parameter(Mandatory = $true)]
        $Settings,
        [switch]$SkipLicenses
    )

    foreach ($user in $Settings.Users) {
        try {
            $existingUser = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

            if (-not $existingUser) {
                $tempPassword = "Wiq!" + [System.Guid]::NewGuid().ToString("N").Substring(0, 10) + "9"
                $newUser = @{
                    accountEnabled    = $true
                    displayName       = "$($user.FirstName) $($user.LastName)"
                    mailNickname       = $user.UserPrincipalName
                    userPrincipalName = $user.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
                    jobTitle          = $user.JobTitle
                    department        = $user.Department
                    usageLocation     = $user.UsageLocation
                    givenName        = $user.FirstName
                    surname          = $user.LastName
                    passwordProfile   = @{
                        forceChangePasswordNextSignIn = $true
                        password                      = $tempPassword
                    }
                }

                $existingUser = Invoke-GraphRestMethod -Uri "$graphBaseUrl/users" -Headers $headers -Method Post -ContentType "application/json" -Body ($newUser | ConvertTo-Json -Depth 5)
                Write-InstallLogAction -Message "Created $($user.Email) with temporary password: $tempPassword"
                Write-InstallLogPassword -Email $user.Email -Password $tempPassword
            }
            else {
                Write-InstallLogAction -Message "$($user.Email) already exists, skipping creation."
                # Never overwrite an existing user's usageLocation - only fill it in when Entra ID
                # doesn't already have one set, so real users' existing data is never clobbered.
                if ([string]::IsNullOrWhiteSpace($existingUser.usageLocation) -and -not [string]::IsNullOrWhiteSpace($user.UsageLocation)) {
                    Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$($existingUser.id)" -Headers $headers -Method Patch -ContentType "application/json" -Body (@{ usageLocation = $user.UsageLocation } | ConvertTo-Json)
                }
            }

            if (-not $SkipLicenses) {
                Set-LicenseForUser -UserId $existingUser.id
            }
        }
        catch {
            Write-Host "Failed to process $($user.Email): $($_.Exception.Message)" -ForegroundColor Red
            throw
        }
    }
}

# Reads the tenant's Temporary Access Pass policy and returns the policy plus the IDs of the
# given users it applies to. Returns $null (after logging why) when TAP can't be used, so the
# caller can skip. The policy is never changed.
function Get-TapEligibility {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$UserIds
    )

    try {
        $policy = Invoke-GraphRestMethod -Uri "$graphBaseUrl/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/temporaryAccessPass" -Headers $headers -Method Get
    }
    catch {
        Write-InstallLogAction -Message "Skipping Temporary Access Pass: could not read the tenant policy ($($_.Exception.Message)). Check that the Policy.Read.All permission is consented." -Level Warning
        return $null
    }

    if ($policy.state -ne 'enabled') {
        Write-InstallLogAction -Message "Skipping Temporary Access Pass: the method is not enabled in the tenant's Authentication methods policy." -Level Warning
        return $null
    }

    $includeTargets = @($policy.includeTargets)
    $excludeTargets = @($policy.excludeTargets)
    $allUsersIncluded = [bool]($includeTargets | Where-Object { $_.id -eq 'all_users' })
    $groupIds = @(($includeTargets + $excludeTargets) | Where-Object { $_.targetType -eq 'group' -and $_.id -ne 'all_users' } | ForEach-Object { $_.id } | Select-Object -Unique)

    $eligible = @()
    foreach ($userId in $UserIds) {
        $memberOf = @()
        if ($groupIds.Count -gt 0) {
            $memberOf = @((Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$userId/checkMemberGroups" -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ groupIds = $groupIds } | ConvertTo-Json)).value)
        }
        $included = $allUsersIncluded -or [bool]($includeTargets | Where-Object { $_.id -in $memberOf })
        $excluded = [bool]($excludeTargets | Where-Object { $_.id -in $memberOf })
        if ($included -and -not $excluded) { $eligible += $userId }
    }

    if ($eligible.Count -eq 0) {
        Write-InstallLogAction -Message "Skipping Temporary Access Pass: the tenant policy does not apply to the demo users." -Level Warning
        return $null
    }

    return [PSCustomObject]@{ Policy = $policy; UserIds = $eligible }
}

# Creates a Temporary Access Pass for one user and returns it. A user can only have one, so an
# existing one is replaced with -Renew, otherwise left alone (and nothing is returned) because
# Graph only reveals the code at creation. The user's password is never touched.
function New-UserTap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [int]$LifetimeInMinutes = 480,
        [bool]$IsUsableOnce = $false,
        [switch]$Renew
    )

    $tapUri = "$graphBaseUrl/users/$UserId/authentication/temporaryAccessPassMethods"
    $existing = @((Invoke-GraphRestMethod -Uri $tapUri -Headers $headers -Method Get).value)
    if ($existing.Count -gt 0) {
        if (-not $Renew) {
            Write-InstallLogAction -Message "$Email already has a Temporary Access Pass, skipping. Use -RenewTap to replace it."
            return $null
        }
        foreach ($method in $existing) {
            Invoke-GraphRestMethod -Uri "$tapUri/$($method.id)" -Headers $headers -Method Delete | Out-Null
        }
    }

    $created = Invoke-GraphRestMethod -Uri $tapUri -Headers $headers -Method Post -ContentType 'application/json' -Body (@{ lifetimeInMinutes = $LifetimeInMinutes; isUsableOnce = $IsUsableOnce } | ConvertTo-Json)
    $start = if ($created.startDateTime) { ([datetime]$created.startDateTime).ToUniversalTime() } else { ([datetime]$created.createdDateTime).ToUniversalTime() }
    return [PSCustomObject]@{
        Email        = $Email
        Tap          = $created.temporaryAccessPass
        ExpiresAt    = $start.AddMinutes([int]$created.lifetimeInMinutes)
        IsUsableOnce = [bool]$created.isUsableOnce
    }
}

# Issues Temporary Access Passes so demo users can sign in without setting up an authenticator
# app. Demo users only, and skipped when the tenant's TAP policy doesn't allow it.
function Add-UserTaps {
    param(
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        [bool]$InstallDemoUsers,
        [int]$LifetimeInMinutes = 480,
        [bool]$IsUsableOnce = $false,
        [switch]$Renew
    )

    if (-not $InstallDemoUsers) {
        Write-InstallLogAction -Message "Skipping Temporary Access Pass: only available for the built-in demo users." -Level Warning
        return
    }

    $users = @{}
    foreach ($user in $Settings.Users) {
        try {
            $found = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id,userPrincipalName" -Headers $headers -Method Get).value | Select-Object -First 1
            if ($found) { $users[$found.id] = $user.Email }
            else { Write-InstallLogAction -Message "Skipping Temporary Access Pass for $($user.Email): user not found." -Level Warning }
        }
        catch {
            Write-InstallLogAction -Message "Failed to look up $($user.Email): $($_.Exception.Message)" -Level Error
        }
    }
    if ($users.Count -eq 0) { return }

    $eligibility = Get-TapEligibility -UserIds @($users.Keys)
    if (-not $eligibility) { return }

    foreach ($userId in @($users.Keys | Where-Object { $_ -notin $eligibility.UserIds })) {
        Write-InstallLogAction -Message "Skipping Temporary Access Pass for $($users[$userId]): the tenant policy does not apply to this user." -Level Warning
    }

    # Stay inside what the tenant policy allows, otherwise Graph rejects the request.
    $policy = $eligibility.Policy
    if ($policy.isUsableOnce -eq $true -and -not $IsUsableOnce) {
        Write-InstallLogAction -Message "The tenant policy requires one-time Temporary Access Passes; issuing single-use codes." -Level Warning
        $IsUsableOnce = $true
    }
    if ($policy.minimumLifetimeInMinutes -and $LifetimeInMinutes -lt [int]$policy.minimumLifetimeInMinutes) { $LifetimeInMinutes = [int]$policy.minimumLifetimeInMinutes }
    if ($policy.maximumLifetimeInMinutes -and $LifetimeInMinutes -gt [int]$policy.maximumLifetimeInMinutes) { $LifetimeInMinutes = [int]$policy.maximumLifetimeInMinutes }

    foreach ($userId in $eligibility.UserIds) {
        $email = $users[$userId]
        try {
            $tap = New-UserTap -UserId $userId -Email $email -LifetimeInMinutes $LifetimeInMinutes -IsUsableOnce $IsUsableOnce -Renew:$Renew
            if ($tap) {
                $use = if ($tap.IsUsableOnce) { 'single use' } else { 'multi use' }
                Write-InstallLogAction -Message "Issued a Temporary Access Pass for $email (expires $($tap.ExpiresAt.ToString('yyyy-MM-dd HH:mm')) UTC, $use)."
                Write-Host "  $email : $($tap.Tap)" -ForegroundColor Cyan
                Write-InstallLogTap -Email $email -TemporaryAccessPass $tap.Tap -ExpiresAt $tap.ExpiresAt -IsUsableOnce $tap.IsUsableOnce
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to issue a Temporary Access Pass for ${email}: $($_.Exception.Message)" -Level Error
        }
    }
}

function Add-Groups {
    param(
        [Parameter(Mandatory = $true)]
        $Site,
        [Parameter(Mandatory = $true)]
        $Settings
    )

    # Groups is a list of security group names. Membership uses the same resolved
    # demo or real users passed to Add-Users, rather than the site's Teams membership.
    foreach ($groupName in @($Site.Groups | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
        try {
            $escapedName = [Uri]::EscapeDataString($groupName.Replace("'", "''"))
            $groups = @()
            $uri = "$graphBaseUrl/groups?`$filter=displayName eq '$escapedName'&`$select=id,displayName,securityEnabled,mailEnabled,groupTypes"
            do {
                $page = Invoke-GraphRestMethod -Uri $uri -Headers $headers -Method Get
                $groups += @($page.value)
                $uri = $page.'@odata.nextLink'
            } while ($uri)

            if ($groups.Count -gt 1) {
                throw "Multiple groups named '$groupName' exist; cannot safely choose one."
            }

            $group = $groups | Select-Object -First 1
            if ($group) {
                if (-not $group.securityEnabled -or $group.mailEnabled -or @($group.groupTypes).Count -gt 0) {
                    throw "Existing group '$groupName' is not an assigned, non-mail-enabled security group."
                }
                Write-InstallLogAction -Message "Security group '$groupName' already exists, skipping creation."
            }
            else {
                $body = @{
                    displayName     = $groupName
                    mailNickname    = "WorkIQ" + [Guid]::NewGuid().ToString("N")
                    mailEnabled     = $false
                    securityEnabled = $true
                    groupTypes      = @()
                } | ConvertTo-Json -Depth 5
                $group = Invoke-GraphRestMethod -Uri "$graphBaseUrl/groups" -Headers $headers -Method Post -ContentType "application/json" -Body $body
                Write-InstallLogAction -Message "Created security group '$groupName'." -Level Success
            }

            $memberIds = @{}
            $uri = "$graphBaseUrl/groups/$($group.id)/members?`$select=id"
            do {
                $page = Invoke-GraphRestMethod -Uri $uri -Headers $headers -Method Get
                foreach ($member in $page.value) { $memberIds[$member.id] = $true }
                $uri = $page.'@odata.nextLink'
            } while ($uri)

            foreach ($user in $Settings.Users) {
                try {
                    $userUpn = [Uri]::EscapeDataString($user.Email)
                    $graphUser = Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$userUpn`?`$select=id" -Headers $headers -Method Get
                    if ($memberIds.ContainsKey($graphUser.id)) {
                        continue
                    }
                    $body = @{ '@odata.id' = "$graphBaseUrl/directoryObjects/$($graphUser.id)" } | ConvertTo-Json
                    Invoke-GraphRestMethod -Uri "$graphBaseUrl/groups/$($group.id)/members/`$ref" -Headers $headers -Method Post -ContentType "application/json" -Body $body | Out-Null
                    $memberIds[$graphUser.id] = $true
                    Write-InstallLogAction -Message "Added $($user.Email) to security group '$groupName'."
                }
                catch {
                    Write-InstallLogAction -Message "Failed to add $($user.Email) to security group '$groupName': $($_.Exception.Message)" -Level Error
                }
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to provision security group '$groupName': $($_.Exception.Message)" -Level Error
        }
    }
}

function Add-UserPhotos {
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )

    $photosDir = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/UserPhotos"))
    if (-not (Test-Path $photosDir)) {
        return
    }

    # Photo files are named after the first part of the UPN (e.g. "Serena.Ribeiro.png" for
    # UserPrincipalName "serena.ribeiro") but casing doesn't necessarily match, so index by
    # lower-cased file stem.
    $photosByStem = @{}
    foreach ($file in Get-ChildItem -Path $photosDir -File) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        $photosByStem[$stem] = $file
    }

    foreach ($user in $Settings.Users) {
        try {
            $photoFile = $photosByStem[$user.UserPrincipalName.ToLowerInvariant()]
            if (-not $photoFile) {
                Write-InstallLogAction -Message "No profile photo found for $($user.Email), skipping."
                continue
            }

            $existingUser = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id" -Headers $headers -Method Get).value | Select-Object -First 1
            if (-not $existingUser) {
                Write-InstallLogAction -Message "$($user.Email) does not exist, skipping photo upload."
                continue
            }

            $contentType = switch ($photoFile.Extension.ToLowerInvariant()) {
                ".png"  { "image/png" }
                ".jpg"  { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                default { $null }
            }
            if (-not $contentType) {
                Write-InstallLogAction -Message "Unsupported photo file type for $($user.Email): $($photoFile.Name), skipping."
                continue
            }

            # Right after Add-Users assigns a license, Exchange Online mailbox provisioning is
            # still async - the photo endpoint 404s until the mailbox exists, so retry with
            # backoff instead of treating that as a hard failure.
            $photoUri = "$graphBaseUrl/users/$($existingUser.id)/photo/`$value"
            $maxAttempts = 6
            $delaySeconds = 20
            for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                try {
                    Invoke-GraphRestMethod -Uri $photoUri -Headers $headers -Method Put -ContentType $contentType -InFile $photoFile.FullName
                    Write-InstallLogAction -Message "Set profile photo for $($user.Email) from $($photoFile.Name)."
                    break
                }
                catch {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                    if ($statusCode -eq 404 -and $attempt -lt $maxAttempts) {
                        Write-Host "Mailbox for $($user.Email) isn't provisioned yet, retrying photo upload in $delaySeconds seconds (attempt $attempt/$maxAttempts)..."
                        Start-Sleep -Seconds $delaySeconds
                    }
                    else {
                        throw
                    }
                }
            }
        }
        catch {
            Write-Host "Failed to set profile photo for $($user.Email): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Remove-Users {
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )

    foreach ($user in $Settings.Users) {
        try {
            if ($Settings.DefaultUsers -notcontains $user.UserPrincipalName) {
                Write-InstallLogAction "$($user.Email) is not a default demo user, skipping deletion."
                continue
            }

            $existingUser = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'" -Headers $headers -Method Get).value | Select-Object -First 1

            if ($existingUser) {
                Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$($existingUser.id)" -Headers $headers -Method Delete
                Write-InstallLogAction "Deleted default demo user $($user.Email)."

                # Deleting a user only moves them to the Entra ID deleted items bin (restorable for
                # 30 days) - permanently delete this user so the demo can be reinstalled cleanly.
                try {
                    Invoke-GraphRestMethod -Uri "$graphBaseUrl/directory/deletedItems/$($existingUser.id)" -Headers $headers -Method Delete
                    Write-InstallLogAction "Permanently deleted $($user.Email) from the deleted items bin."
                }
                catch {
                    Write-InstallLogAction "Could not permanently delete $($user.Email): $($_.Exception.Message)" -Level Warning
                }
            }
            else {
                Write-InstallLogAction "$($user.Email) does not exist, skipping deletion."
            }
        }
        catch {
            Write-InstallLogAction "Failed to delete $($user.Email): $($_.Exception.Message)" -Level Error
        }
    }
}

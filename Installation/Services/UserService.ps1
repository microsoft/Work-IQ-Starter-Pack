function Resolve-RealUsers {
    param(
        [Parameter(Mandatory = $true)]
        $Settings,
        [Parameter(Mandatory = $true)]
        [hashtable]$RealUserUpns
    )

    foreach ($index in $RealUserUpns.Keys) {
        $upn = $RealUserUpns[$index]
        $graphUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,givenName,surname,jobTitle,department,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

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
            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

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

                $existingUser = Invoke-RestMethod -Uri "$graphBaseUrl/users" -Headers $headers -Method Post -ContentType "application/json" -Body ($newUser | ConvertTo-Json -Depth 5)
                Write-InstallLogAction -Message "Created $($user.Email) with temporary password: $tempPassword"
                Write-InstallLogPassword -Email $user.Email -Password $tempPassword
            }
            else {
                Write-InstallLogAction -Message "$($user.Email) already exists, skipping creation."
                # Never overwrite an existing user's usageLocation - only fill it in when Entra ID
                # doesn't already have one set, so real users' existing data is never clobbered.
                if ([string]::IsNullOrWhiteSpace($existingUser.usageLocation) -and -not [string]::IsNullOrWhiteSpace($user.UsageLocation)) {
                    Invoke-RestMethod -Uri "$graphBaseUrl/users/$($existingUser.id)" -Headers $headers -Method Patch -ContentType "application/json" -Body (@{ usageLocation = $user.UsageLocation } | ConvertTo-Json)
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
                $page = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
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
                $group = Invoke-RestMethod -Uri "$graphBaseUrl/groups" -Headers $headers -Method Post -ContentType "application/json" -Body $body
                Write-InstallLogAction -Message "Created security group '$groupName'." -Level Success
            }

            $memberIds = @{}
            $uri = "$graphBaseUrl/groups/$($group.id)/members?`$select=id"
            do {
                $page = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
                foreach ($member in $page.value) { $memberIds[$member.id] = $true }
                $uri = $page.'@odata.nextLink'
            } while ($uri)

            foreach ($user in $Settings.Users) {
                try {
                    $userUpn = [Uri]::EscapeDataString($user.Email)
                    $graphUser = Invoke-RestMethod -Uri "$graphBaseUrl/users/$userUpn`?`$select=id" -Headers $headers -Method Get
                    if ($memberIds.ContainsKey($graphUser.id)) {
                        continue
                    }
                    $body = @{ '@odata.id' = "$graphBaseUrl/directoryObjects/$($graphUser.id)" } | ConvertTo-Json
                    Invoke-RestMethod -Uri "$graphBaseUrl/groups/$($group.id)/members/`$ref" -Headers $headers -Method Post -ContentType "application/json" -Body $body | Out-Null
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

            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id" -Headers $headers -Method Get).value | Select-Object -First 1
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
                    Invoke-RestMethod -Uri $photoUri -Headers $headers -Method Put -ContentType $contentType -InFile $photoFile.FullName
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

            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'" -Headers $headers -Method Get).value | Select-Object -First 1

            if ($existingUser) {
                Invoke-RestMethod -Uri "$graphBaseUrl/users/$($existingUser.id)" -Headers $headers -Method Delete
                Write-InstallLogAction "Deleted default demo user $($user.Email)."

                # Deleting a user only moves them to the Entra ID deleted items bin (restorable for
                # 30 days) - permanently delete this user so the demo can be reinstalled cleanly.
                try {
                    Invoke-RestMethod -Uri "$graphBaseUrl/directory/deletedItems/$($existingUser.id)" -Headers $headers -Method Delete
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

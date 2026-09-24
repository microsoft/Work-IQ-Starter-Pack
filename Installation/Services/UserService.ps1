function Resolve-RealUsers {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [Parameter(Mandatory = $true)]
        [hashtable]$RealUserUpns
    )

    foreach ($index in $RealUserUpns.Keys) {
        $upn = $RealUserUpns[$index]
        $graphUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,givenName,surname,jobTitle,department,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

        if (-not $graphUser) {
            throw "Could not find a user with UPN '$upn' in Entra ID. Please verify the UPN and try again."
        }

        $entry = $Config.Users[$index]
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

    return $Config
}

function Add-Users {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($user in $Config.Users) {
        try {
            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'&`$select=id,userPrincipalName,usageLocation" -Headers $headers -Method Get).value | Select-Object -First 1

            if (-not $existingUser) {
                $tempPassword = "Wiq!" + [System.Guid]::NewGuid().ToString("N").Substring(0, 10) + "9"
                $newUser = @{
                    accountEnabled    = $true
                    displayName       = "$($user.FirstName) $($user.LastName)"
                    mailNickname       = $user.UserPrincipalName
                    userPrincipalName = $user.Email
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

            Set-LicenseForUser -UserId $existingUser.id
        }
        catch {
            Write-Host "Failed to process $($user.Email): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

function Add-UserPhotos {
    param(
        [Parameter(Mandatory = $true)]
        $Config
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

    foreach ($user in $Config.Users) {
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
        $Config,
        [Parameter(Mandatory = $true)]
        $Settings
    )

    foreach ($user in $Config.Users) {
        try {
            if ($Settings.DefaultUsers -notcontains $user.UserPrincipalName) {
                Write-Host "$($user.Email) is not a default demo user, skipping deletion."
                continue
            }

            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'" -Headers $headers -Method Get).value | Select-Object -First 1

            if ($existingUser) {
                Invoke-RestMethod -Uri "$graphBaseUrl/users/$($existingUser.id)" -Headers $headers -Method Delete
                Write-Host "Deleted default demo user $($user.Email)."
            }
            else {
                Write-Host "$($user.Email) does not exist, skipping deletion."
            }
        }
        catch {
            Write-Host "Failed to delete $($user.Email): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

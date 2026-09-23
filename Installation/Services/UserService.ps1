function Add-Users {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    foreach ($user in $Config.Users) {
        try {
            $existingUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$($user.Email)'" -Headers $headers -Method Get).value | Select-Object -First 1

            if (-not $existingUser) {
                $tempPassword = "Wiq!" + [System.Guid]::NewGuid().ToString("N").Substring(0, 10) + "9"
                $newUser = @{
                    accountEnabled    = $true
                    displayName       = "$($user.FirstName) $($user.LastName)"
                    mailNickname       = $user.UserPrincipalName
                    userPrincipalName = $user.Email
                    jobTitle          = $user.JobTitle
                    department        = $user.Department
                    usageLocation     = $Config.UsageLocation
                    givenName        = $user.FirstName
                    surname          = $user.LastName
                    passwordProfile   = @{
                        forceChangePasswordNextSignIn = $true
                        password                      = $tempPassword
                    }
                }

                $existingUser = Invoke-RestMethod -Uri "$graphBaseUrl/users" -Headers $headers -Method Post -ContentType "application/json" -Body ($newUser | ConvertTo-Json -Depth 5)
                Write-Host "Created $upn with temporary password: $tempPassword"
            }
            else {
                Write-Host "$upn already exists, skipping creation."
            }

            Set-LicenseForUser -UserId $existingUser.id
        }
        catch {
            Write-Host "Failed to process $($user.Email): $($_.Exception.Message)" -ForegroundColor Red
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

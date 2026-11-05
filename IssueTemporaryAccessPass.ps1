# Requires -Version 7.4
param(
    # Path to the config.json file to read. Defaults to Configuration/config.json.
    [Alias('Config')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Configuration/config.json')
)

# Issues Temporary Access Passes (TAP) so users can sign in without setting up an authenticator
# app. Run it after InstallWorkIQStarterPack.ps1. The tenant's TAP policy is only read, never changed.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Installation/Services/ConfigurationService.ps1')
$configurationPaths = Get-WorkIQConfigurationPaths -ConfigPath $ConfigPath -RepositoryRoot $PSScriptRoot
$configPath = $configurationPaths.ConfigPath
$config = $configurationPaths.Config
. (Join-Path $PSScriptRoot 'Installation/Services/InstallLogService.ps1')
. (Join-Path $PSScriptRoot 'Installation/Services/WorkIQService.ps1')
. (Join-Path $PSScriptRoot 'Installation/Services/AppRegService.ps1')
Initialize-InstallLog -Title 'WorkIQ Starter Pack Temporary Access Pass Log' -FileName 'TapLog.md' -IncludePasswords $false -IncludeTaps $true -LogDirectory $configurationPaths.LogDirectory
Write-InstallLogInput -Prompt 'Configuration file' -Response $configPath

# Ask a yes/no question and record the answer in the log. A blank answer accepts the default.
function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { ' (yes/no, default: yes)' } else { ' (yes/no, default: no)' }
    do {
        $answer = (Read-Host "$Prompt$suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) { $answer = if ($Default) { 'yes' } else { 'no' } }
    } while ($answer -notin @('yes', 'y', 'no', 'n'))

    $selected = $answer -in @('yes', 'y')
    Write-InstallLogInput -Prompt $Prompt -Response $(if ($selected) { 'Yes' } else { 'No' })
    return $selected
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
        Write-InstallLogAction -Message 'Skipping Temporary Access Pass: the tenant policy does not apply to the selected users.' -Level Warning
        return $null
    }

    return [PSCustomObject]@{ Policy = $policy; UserIds = $eligible }
}

# Creates a Temporary Access Pass for one user and returns it. A user can only have one, so when
# one exists the installer is asked whether to replace it. Graph only reveals the code at
# creation, so a pass that is kept can't be shown again. Returns $null when nothing was created.
# The user's password is never touched.
function New-UserTap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserId,
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [int]$LifetimeInMinutes = 480,
        [bool]$IsUsableOnce = $false
    )

    $tapUri = "$graphBaseUrl/users/$UserId/authentication/temporaryAccessPassMethods"
    $existing = @((Invoke-GraphRestMethod -Uri $tapUri -Headers $headers -Method Get).value)
    if ($existing.Count -gt 0) {
        $current = $existing | Select-Object -First 1
        $state = 'expired'
        if ($current.startDateTime -and $current.lifetimeInMinutes) {
            $expires = ([datetime]$current.startDateTime).ToUniversalTime().AddMinutes([int]$current.lifetimeInMinutes)
            if ($current.isUsable -ne $false -and $expires -gt [datetime]::UtcNow) {
                $state = "still valid, expires $($expires.ToString('yyyy-MM-dd HH:mm')) UTC"
            }
        }
        elseif ($current.isUsable -eq $true) {
            $state = 'still valid'
        }

        if (-not (Read-YesNo "$Email already has a Temporary Access Pass ($state). Replace it with a new one?" -Default $false)) {
            Write-InstallLogAction -Message "Keeping the existing Temporary Access Pass for $Email."
            return $null
        }
        foreach ($method in $existing) {
            Invoke-GraphRestMethod -Uri "$tapUri/$($method.id)" -Headers $headers -Method Delete | Out-Null
        }
        Write-InstallLogAction -Message "Deleted the existing Temporary Access Pass for $Email."
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

# Issues Temporary Access Passes for the given accounts, skipped when the tenant's TAP policy
# doesn't allow it.
function Add-UserTaps {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Emails,
        [int]$LifetimeInMinutes = 480,
        [bool]$IsUsableOnce = $false
    )

    $users = [ordered]@{}
    foreach ($email in $Emails) {
        try {
            $escaped = [Uri]::EscapeDataString($email.Replace("'", "''"))
            $found = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$escaped'&`$select=id,userPrincipalName" -Headers $headers -Method Get).value | Select-Object -First 1
            if ($found) { $users[$found.id] = $email }
            else { Write-InstallLogAction -Message "Skipping Temporary Access Pass for ${email}: user not found." -Level Warning }
        }
        catch {
            Write-InstallLogAction -Message "Failed to look up ${email}: $($_.Exception.Message)" -Level Error
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
        Write-InstallLogAction -Message 'The tenant policy requires one-time Temporary Access Passes; issuing single-use codes.' -Level Warning
        $IsUsableOnce = $true
    }
    if ($policy.minimumLifetimeInMinutes -and $LifetimeInMinutes -lt [int]$policy.minimumLifetimeInMinutes) { $LifetimeInMinutes = [int]$policy.minimumLifetimeInMinutes }
    if ($policy.maximumLifetimeInMinutes -and $LifetimeInMinutes -gt [int]$policy.maximumLifetimeInMinutes) { $LifetimeInMinutes = [int]$policy.maximumLifetimeInMinutes }

    foreach ($userId in $eligibility.UserIds) {
        $email = $users[$userId]
        try {
            $tap = New-UserTap -UserId $userId -Email $email -LifetimeInMinutes $LifetimeInMinutes -IsUsableOnce $IsUsableOnce
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

$tapSucceeded = $false
try {
    if ([string]::IsNullOrWhiteSpace($config.Settings.TenantPrefix) -or [string]::IsNullOrWhiteSpace($config.Settings.ClientId)) {
        throw "Settings.TenantPrefix and Settings.ClientId must be set in '$configPath'. Run InstallWorkIQStarterPack.ps1 first so the app registration exists."
    }
    $tenantPrefix = ($config.Settings.TenantPrefix -replace '\.onmicrosoft\.com$', '')
    $tapLifetimeInMinutes = if ($config.Settings.TapLifetimeInMinutes) { [int]$config.Settings.TapLifetimeInMinutes } else { 480 }
    $tapIsUsableOnce = [bool]$config.Settings.TapIsUsableOnce

    Write-Host ''
    if ([bool]$config.Settings.InstallDemoUsers) {
        $settings = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Configuration/settings.json') -Raw | ConvertFrom-Json
        $demoUsers = @($settings.Users | ForEach-Object {
            [PSCustomObject]@{ Name = "$($_.FirstName) $($_.LastName)".Trim(); Email = $_.Email.Replace('<TENANTPREFIX>', $tenantPrefix) }
        })
        Write-Host 'Demo users:'
        foreach ($demoUser in $demoUsers) {
            $label = if ($demoUser.Name) { "$($demoUser.Name) <$($demoUser.Email)>" } else { $demoUser.Email }
            Write-Host "  - $label"
        }
        Write-Host ''
        if (-not (Read-YesNo 'Do you want to enable Temporary Access Pass for all of these demo users?' -Default $true)) {
            Write-InstallLogAction -Message 'Temporary Access Pass was not enabled. Nothing was changed.'
            $tapSucceeded = $true
            return
        }
        $targetEmails = @($demoUsers | ForEach-Object { $_.Email })
    }
    else {
        $defaultUpns = @($config.Settings.RealUserUpns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $prompt = 'Enter the accounts (UPNs, separated by commas or spaces) to enable Temporary Access Pass for'
        if ($defaultUpns.Count -gt 0) { $prompt += " (press Enter to use: $($defaultUpns -join ', '))" }
        $answer = (Read-Host $prompt).Trim()
        Write-InstallLogInput -Prompt 'Accounts to enable Temporary Access Pass for' -Response $(if ($answer) { $answer } else { $defaultUpns -join ', ' })
        $targetEmails = if ([string]::IsNullOrWhiteSpace($answer)) { $defaultUpns } else { @($answer -split '[,;\s]+' | Where-Object { $_ }) }
        $targetEmails = @($targetEmails | Select-Object -Unique)
        if ($targetEmails.Count -eq 0) {
            Write-InstallLogAction -Message 'No accounts were entered. Nothing was changed.' -Level Warning
            $tapSucceeded = $true
            return
        }
        Write-Host ''
        Write-Host 'Accounts:'
        foreach ($email in $targetEmails) { Write-Host "  - $email" }
        Write-Host ''
        if (-not (Read-YesNo 'Do you want to enable Temporary Access Pass for these accounts?' -Default $true)) {
            Write-InstallLogAction -Message 'Temporary Access Pass was not enabled. Nothing was changed.'
            $tapSucceeded = $true
            return
        }
    }

    # Browser sign-in with the starter pack's app registration; the functions above use these globals.
    $tenant = "$tenantPrefix.onmicrosoft.com"
    $global:graphBaseUrl = 'https://graph.microsoft.com/v1.0'
    $global:headers = @{ Authorization = "Bearer $(Get-AppRegBrowserAccessToken -Tenant $tenant -AuthenticationClientId ([guid]$config.Settings.ClientId) -Scope 'https://graph.microsoft.com/.default')" }

    Write-InstallLogAction -Message 'Issuing Temporary Access Passes...'
    Add-UserTaps -Emails $targetEmails -LifetimeInMinutes $tapLifetimeInMinutes -IsUsableOnce $tapIsUsableOnce
    $tapSucceeded = -not (@($script:installLogActions | Where-Object Level -eq 'Error').Count -gt 0)
    Write-InstallLogAction -Message 'Finished issuing Temporary Access Passes.' -Level $(if ($tapSucceeded) { 'Success' } else { 'Warning' })
}
catch {
    Write-InstallLogAction -Message "Temporary Access Pass failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    $global:headers = $null
    Save-InstallLog -Success $tapSucceeded
    Write-Host "Temporary Access Pass log: $script:installLogPath"
}

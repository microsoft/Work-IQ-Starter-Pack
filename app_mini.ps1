#Requires -Version 7.4
param(
    # Use the tenant prefix and app name saved in Configuration/config.json.
    [switch]$UseConfig
)

. (Join-Path $PSScriptRoot 'Installation/Services/InstallLogService.ps1')
Initialize-InstallLog -Title 'WorkIQ Starter Pack Mini App Registration Log' -FileName 'AppMiniLog.md' -IncludePasswords $false
$registrationSucceeded = $false
try {
    $configPath = Join-Path $PSScriptRoot 'Configuration/config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'Installation/Services/AppRegistrationService.ps1')

    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Write-InstallLogAction -Message 'Installing PnP.PowerShell for the current user...'
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PnP.PowerShell -ErrorAction Stop

    Write-Host 'Create a new WorkIQ application registration and save its client ID to Configuration/config.json.'
    $tenant = [string]$config.Settings.TenantPrefix
    if (-not $UseConfig) {
        do {
            $answer = (Read-Host "Enter your tenant prefix (default: $tenant)").Trim()
            if ($answer) { $tenant = $answer }
        } while ([string]::IsNullOrWhiteSpace($tenant))
    }
    if ([string]::IsNullOrWhiteSpace($tenant)) { throw '-UseConfig requires Settings.TenantPrefix in Configuration/config.json.' }
    $tenant = $tenant.Trim() -replace '\.onmicrosoft\.com$', ''
    Write-InstallLogInput -Prompt 'Tenant prefix' -Response $tenant

    $appName = [string]$config.Settings.AppRegistrationName
    if ([string]::IsNullOrWhiteSpace($appName)) { $appName = 'WorkIQStarterPack' }
    if (-not $UseConfig) {
        $answer = (Read-Host "Enter the name for your application registration (default: $appName)").Trim()
        if ($answer) { $appName = $answer }
    }
    Write-InstallLogInput -Prompt 'Application registration name' -Response $appName

    $registration = New-AppRegistration -Tenant $tenant -AppName $appName
    if ([string]::IsNullOrWhiteSpace($registration.ClientId)) { throw 'App registration returned no client ID.' }
    if (-not (Set-AppRegistrationConfig -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix -ConfigPath $configPath)) {
        throw "App registration was created, but its configuration could not be saved. Client ID: $($registration.ClientId)."
    }
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $config.Settings | Add-Member -NotePropertyName AppRegistrationName -NotePropertyValue $appName -Force
    $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction Stop
    Connect-WorkIQPnP -SharePointUrl $registration.SharePointUrl -ClientId $registration.ClientId -Force
    Update-AppRegistrationPermissions -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix | Out-Null
    Write-InstallLogAction -Message "Created application registration '$appName'. Client ID: $($registration.ClientId)." -Level Success
    $registrationSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "App registration failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if (Get-Command Disconnect-PnPOnline -ErrorAction SilentlyContinue) { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
    Save-InstallLog -Success $registrationSucceeded
    Write-Host "App registration log: $script:installLogPath"
}

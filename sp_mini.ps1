#Requires -Version 7.4
param(
    # Use saved settings without configuration prompts. Sign-in remains interactive.
    [switch]$UseConfig
)

. (Join-Path $PSScriptRoot 'Installation/Services/InstallLogService.ps1')
Initialize-InstallLog -Title 'Dynamics SharePoint Integration Check' -FileName 'SharePointMiniLog.md' -IncludePasswords $false
$checkSucceeded = $false
$connected = $false
try {
    $configPath = Join-Path $PSScriptRoot 'Configuration/config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsSharePointService.ps1')

    Write-Host 'Check SharePoint integration configuration in Dynamics. This checks configured sites and their last validation status; it does not test live SharePoint connectivity.'
    foreach ($setting in @('TenantPrefix','ClientId','DynamicsEnvironmentUrl')) {
        $value = [string]$config.Settings.$setting
        if (-not $UseConfig) {
            do {
                $answer = (Read-Host "Enter $setting (default: $value)").Trim()
                if ($answer) { $value = $answer }
            } while ([string]::IsNullOrWhiteSpace($value))
        }
        if ([string]::IsNullOrWhiteSpace($value)) { throw "Settings.$setting is required in Configuration/config.json." }
        $value = $value.Trim()
        if ($setting -eq 'TenantPrefix') {
            $value = $value -replace '\.onmicrosoft\.com$', ''
            if ($value -notmatch '^[a-zA-Z0-9-]+$') { throw 'Enter a tenant prefix or an onmicrosoft.com tenant domain.' }
        }
        elseif ($setting -eq 'ClientId') { $value = [Guid]::Parse($value).ToString() }
        else {
            $uri = $null
            if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment) {
                throw 'DynamicsEnvironmentUrl must be an HTTPS environment root URL.'
            }
            $value = $uri.GetLeftPart([UriPartial]::Authority)
        }
        $config.Settings | Add-Member -NotePropertyName $setting -NotePropertyValue $value -Force
        Write-InstallLogInput -Prompt $setting -Response $value
    }
    if (-not $UseConfig) {
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $configPath -Encoding UTF8 -ErrorAction Stop
    }

    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Write-InstallLogAction -Message 'Installing PnP.PowerShell for the current user...'
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PnP.PowerShell -ErrorAction Stop
    Connect-PnPOnline -Url "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId -Interactive -ErrorAction Stop
    $connected = $true
    $integrationConfigured = Test-DynamicsSharePointIntegration -Config $config
    Write-InstallLogAction -Message "SharePoint integration configured: $integrationConfigured."
    $checkSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "SharePoint integration check failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if ($connected) { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
    Save-InstallLog -Success $checkSucceeded
    Write-Host "SharePoint check log: $script:installLogPath"
}

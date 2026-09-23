. (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")

try {
    Install-PnPPowerShellModule
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

do {
    $tenant = Read-Host "Enter your tenant prefix name (e.g. contoso from contoso.onmicrosoft.com)"
} while ([string]::IsNullOrWhiteSpace($tenant))

$appName = Read-Host "Enter the name for your application registration (default: WorkIQStarterPack)"
if ([string]::IsNullOrWhiteSpace($appName)) {
    $appName = "WorkIQStarterPack"
}

try {
    $registration = New-AppRegistration -Tenant $tenant -AppName $appName
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

Set-AppRegistrationConfig -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix | Out-Null

try {
    Connect-WorkIQGraph -SharePointUrl $registration.SharePointUrl -ClientId $registration.ClientId

    Initialize-TeamsChatMigrationCertificate -ClientId $registration.ClientId -SharePointUrl $registration.SharePointUrl
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host "This is required to load Teams chat history - rerun this script once admin consent has been granted." -ForegroundColor Yellow
    exit 1
}

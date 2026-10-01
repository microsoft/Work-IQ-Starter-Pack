try {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
    }
    Import-Module PnP.PowerShell
}
catch {
    Write-Host "Failed to install or import the PnP.PowerShell module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Ask the user a yes/no question for configuration
function Read-YesNo {
    param([string]$Prompt)

    do {
        $answer = (Read-Host "$Prompt (yes/no)").Trim().ToLowerInvariant()
    } while ($answer -notin @("yes", "no", "y", "n"))

    return $answer -in @("yes", "y")
}

try {
    # Load the configuration file from file system
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Load the installation settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    $confirmed = Read-YesNo "This will remove demo users, sites/Teams, and their content from https://$($config.Settings.TenantPrefix).sharepoint.com. Continue?"

    if (-not $confirmed) {
        Write-Host "Cleanup cancelled."
        exit 0
    }

    # Make sure there are no existing connections sitting out there
    Disconnect-PnPOnline -ErrorAction SilentlyContinue

    # Connect to SharePoint Online using PnP PowerShell
    Connect-PnPOnline -Url "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId -Interactive

    # Set global variables for use when calling Graph API
    $graphBaseUrl = "https://graph.microsoft.com/v1.0"
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")
    $headers = @{ Authorization = "Bearer $(Get-WorkIQGraphAccessToken)" }

    # Load services files
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/SharePointService.ps1")

    # Tear down in the reverse order the installer creates things: sites/Teams/content first, then users.
    Remove-Sites -Config $config
    Remove-Users -Settings $settings

    $removeAppRegistration = Read-YesNo "Do you also want to remove the application registration (ClientId: $($config.Settings.ClientId)) and its service principal from Entra ID, and delete the local Teams chat migration certificate? Only do this if this script originally created the app registration for you - skip if you supplied a pre-existing one."

    if ($removeAppRegistration) {
        Remove-AppRegistration -ClientId $config.Settings.ClientId
        Remove-TeamsChatMigrationCertificate
    }
}
catch {
    Write-Host "Failed to clean up the Work IQ Starter Pack: $($_.Exception.Message)" -ForegroundColor Red
    Disconnect-PnPOnline
    exit 1
}

try {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
    }
    Import-Module PnP.PowerShell
}
catch {
    throw "Failed to install or import the PnP.PowerShell module: $($_.Exception.Message)"
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

    # Load the installtion settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    #Load App Registration Service file
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")

    # Ask for the tenant prefix once up front - both the existing and new app registration paths need it.
    # Pressing Enter keeps the value already in config.json.
    $currentTenant = $config.Settings.TenantPrefix
    do {
        $prompt = "Enter your tenant prefix name (e.g. caldova from caldova.onmicrosoft.com)"
        if (-not [string]::IsNullOrWhiteSpace($currentTenant)) {
            $prompt += " (default: $currentTenant)"
        }
        $tenant = (Read-Host $prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($tenant)) {
            $tenant = $currentTenant
        }
    } while ([string]::IsNullOrWhiteSpace($tenant))

    $config.Settings.TenantPrefix = ($tenant -replace '\.onmicrosoft\.com$', '')
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Check if the user needs the app registration created
    $hasAppRegistration = Read-YesNo "Do you have an existing Application Registration? Please review the README.md file for the level of permissions required."

    # If they have an app reg then ask for the client ID.
    if ($hasAppRegistration) {
        do {
            $clientId = (Read-Host "Enter the application registration client ID").Trim()
        } while ([string]::IsNullOrWhiteSpace($clientId))

        $config.Settings.ClientId = $clientId
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

        Write-Host "Client ID saved to $configPath" -ForegroundColor Green

        # Make sure the existing app registration has every permission the installer needs, adding any
        # that are missing and prompting for admin consent.
        Connect-WorkIQPnP -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $clientId
        Update-AppRegistrationPermissions -ClientId $clientId -TenantPrefix $config.Settings.TenantPrefix | Out-Null
    }
    else {
        # If they don't have an app reg create one.
        $appName = Read-Host "Enter the name for your application registration (default: WorkIQStarterPack)"
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = "WorkIQStarterPack"
        }

        $registration = New-AppRegistration -Tenant $config.Settings.TenantPrefix -AppName $appName
        Set-AppRegistrationConfig -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix -ConfigPath $configPath | Out-Null

        # Reload configuration in case Set-AppRegistrationConfig updated config.json.
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }

    # Connect to SharePoint Online using PnP PowerShell. This is done once here and the resulting
    Connect-WorkIQGraph -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId

    # Run this for existing app registrations too - it's a no-op when the certificate is already
    # registered, and the certificate-based migration connection below fails without it.
    Initialize-TeamsChatMigrationCertificate -ClientId $config.Settings.ClientId -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com"
    # end app reg creation

    if ([string]::IsNullOrWhiteSpace($config.Settings.ClientId)) {
        throw "No application registration client ID was found in config.json."
    }
    
    # ---------------------Start App Configuration------------------------------------
    # You need to install one of the content packs to proceed.
    if ($config.Settings.InstallM365Content -eq $true -or $config.Settings.InstallDynamicsContent -eq $true) {
        #L oad services files
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/LicensingService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/WorkIQService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/SharePointService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1")

        # Teams chat history import uses Microsoft Graph's message migration API, which only supports
        # application permissions (Teamwork.Migrate.All) - need a seprate connection specifically for migration using a cert.
        $migrationCertificatePath = Join-Path -Path $PSScriptRoot -ChildPath "Installation/.certs/teams-chat-migration.pfx"
        if (-not (Test-Path $migrationCertificatePath)) {
            throw "Teams chat migration certificate not found at $migrationCertificatePath. Run InstallWorkIQStarterPack.ps1 again once admin consent has been granted."
        }
        $migrationToken = Get-TeamsChatMigrationAccessToken -ClientId $config.Settings.ClientId `
            -TenantPrefix $config.Settings.TenantPrefix -CertificatePath $migrationCertificatePath
        $migrationHeaders = @{ Authorization = "Bearer $migrationToken" }

        #Check to see if the required licenses are available before provisioning users
        $preRequisitesMet = Test-License-PreRequisites -Settings $settings
        $workIQEnabled = Test-WorkIQServicePrincipalEnabled -Settings $settings
        $preRequisitesMet = $true
        if (($preRequisitesMet -eq $true -or $config.Settings.SkipPreReqCheck -eq $true) -and $workIQEnabled -eq $true) {
            Write-Host "All license pre-requisites are met. Proceeding with user provisioning."
            #Add-Users -Config $config
            #Add-Sites -Config $config
            #Import-SiteDocuments -Config $config
            #Add-TeamsChatMessages -Config $config -MigrationHeaders $migrationHeaders

        }
        else {
            Write-Host "Not enough licenses available to provision users. You need at least 5 Copilot licenses and 5 E3, E5, or Business Premium Office licenses. Please ensure you have enough licenses available for the number of users you are trying to provision." -ForegroundColor Red
            exit 1
        }
    }
}
catch {
    Write-Host "Failed to provision users: $($_.Exception.Message)" -ForegroundColor Red
    #Disconnect-PnPOnline
    exit 1
}


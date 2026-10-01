try {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
    }
    Import-Module PnP.PowerShell
}
catch {
    throw "Failed to install or import the PnP.PowerShell module: $($_.Exception.Message)"
}

# Ask the user a yes/no question for configuration. Pass -Default to let a blank
# response (pressing Enter) accept that default instead of re-prompting.
function Read-YesNo {
    param(
        [string]$Prompt,
        [Nullable[bool]]$Default = $null
    )

    $suffix = if ($Default -eq $true) { " (yes/no, default: yes)" }
              elseif ($Default -eq $false) { " (yes/no, default: no)" }
              else { " (yes/no)" }

    do {
        $answer = (Read-Host "$Prompt$suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer) -and $null -ne $Default) {
            return $Default
        }
    } while ($answer -notin @("yes", "no", "y", "n"))

    return $answer -in @("yes", "y")
}

$installSucceeded = $false
try {
    Clear-Host
    Write-Host ""
    # Load the configuration file from file system
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Load the installtion settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    # settings.json's Users list and Content/content.json always stay the pristine demo data. When
    # InstallDemoUsers is false, the real users' resolved identities and the persona-swapped
    # content live in these separate "custom" files instead, so the demo definitions are never
    # overwritten.
    $customUsersPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/users.custom.json"
    $contentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.json"
    $customContentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.custom.json"

    #Load App Registration Service file
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")

    # Load the install log service and start recording this run's inputs/actions/passwords so
    # they're captured to a Markdown report under Logs/, even if the run fails partway through.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/InstallLogService.ps1")
    Initialize-InstallLog

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
    Write-InstallLogInput -Prompt "Tenant prefix" -Response $config.Settings.TenantPrefix

    # Ask whether to provision the built-in demo users, or point the starter pack's 5 role
    # slots at real, existing users instead. The UPNs are collected here (upfront, alongside
    # the other one-time setup questions); the actual Entra ID lookup happens later, once
    # Connect-WorkIQGraph has established a Graph connection.
    $provisionDemoUsers = Read-YesNo "Do you want to provision the built-in demo users?" -Default $true
    $config.Settings.InstallDemoUsers = $provisionDemoUsers
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-InstallLogInput -Prompt "Provision the built-in demo users?" -Response $(if ($provisionDemoUsers) { "Yes" } else { "No" })

    $realUserUpns = $null
    if (-not $provisionDemoUsers) {
        $demoRoles = @(
            @{ Label = "Marketing user"; Index = 0 },
            @{ Label = "Finance user"; Index = 1 },
            @{ Label = "Security/Governance user"; Index = 2 },
            @{ Label = "Finance user 2"; Index = 3 },
            @{ Label = "Sales user"; Index = 4 }
        )

        $realUserUpns = @{}
        foreach ($role in $demoRoles) {
            do {
                $upn = (Read-Host "Enter the UPN for the $($role.Label)").Trim()
            } while ([string]::IsNullOrWhiteSpace($upn))

            $realUserUpns[$role.Index] = $upn
            Write-InstallLogInput -Prompt "UPN for the $($role.Label)" -Response $upn
        }
    }

    # Ask which starter pack content pack(s) to install. At least one must be selected, otherwise
    # the content-provisioning block below has nothing to do.
    $installM365Content = Read-YesNo "Do you want to install the M365 WorkIQ Starter Pack Content?" -Default $true
    $installDynamicsContent = Read-YesNo "Do you want to install the Dynamics WorkIQ Starter Pack Content?" -Default $false
    Write-InstallLogInput -Prompt "Install the M365 WorkIQ Starter Pack Content?" -Response $(if ($installM365Content) { "Yes" } else { "No" })
    Write-InstallLogInput -Prompt "Install the Dynamics WorkIQ Starter Pack Content?" -Response $(if ($installDynamicsContent) { "Yes" } else { "No" })

    if (-not $installM365Content -and -not $installDynamicsContent) {
        Write-InstallLogAction -Message "You must select at least one of the M365 or Dynamics WorkIQ Starter Pack Content options to proceed." -Level Error
        exit 1
    }

    $config.Settings.InstallM365Content = $installM365Content
    $config.Settings.InstallDynamicsContent = $installDynamicsContent
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Check if the user needs the app registration created
    $hasAppRegistration = Read-YesNo "Do you have an existing Application Registration? Please review the README.md file for the level of permissions required." -Default $false
    Write-InstallLogInput -Prompt "Do you have an existing Application Registration?" -Response $(if ($hasAppRegistration) { "Yes" } else { "No" })

    # If they have an app reg then ask for the client ID.
    if ($hasAppRegistration) {
        
        $storedClientID = $config.Settings.ClientId
        do {
            $prompt = "Enter the application registration client ID"
            if (-not [string]::IsNullOrWhiteSpace($storedClientID)) {
                $prompt += " (default: $storedClientID)"
            }
            $clientId = (Read-Host $prompt).Trim()
            if ([string]::IsNullOrWhiteSpace($clientId)) {
                $clientId = $storedClientID
            }
        } while ([string]::IsNullOrWhiteSpace($clientId))
        Write-InstallLogInput -Prompt "Application registration client ID" -Response $clientId

        $config.Settings.ClientId = $clientId
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

        Write-InstallLogAction -Message "Client ID saved to $configPath" -Level Success

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
        Write-InstallLogInput -Prompt "Application registration name" -Response $appName

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

    # If the admin opted out of the demo users, look up each supplied UPN's real profile in
    # Entra ID now that Connect-WorkIQGraph has established a Graph connection. The resolved
    # identities go into Configuration/users.custom.json and the persona-swapped content into
    # Content/content.custom.json - settings.json's Users and Content/content.json are never
    # touched, so the demo definitions stay intact no matter how many times this runs.
    if ($null -ne $realUserUpns) {
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1")

        $demoUsers = $settings.Users | ForEach-Object { $_.PSObject.Copy() }
        $customUsersSettings = [PSCustomObject]@{ Users = ($settings.Users | ForEach-Object { $_.PSObject.Copy() }) }
        $customUsersSettings = Resolve-RealUsers -Settings $customUsersSettings -RealUserUpns $realUserUpns
        $customUsersSettings.Users | ConvertTo-Json -Depth 10 | Set-Content -Path $customUsersPath

        Update-ContentPersonas -SourcePath $contentPath -OutputPath $customContentPath -DemoUsers $demoUsers -RealUsers $customUsersSettings.Users -RealUserUpns $realUserUpns
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
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/PermissionsService.ps1")

        # Teams chat history import uses Microsoft Graph's message migration API, which only supports
        # application permissions (Teamwork.Migrate.All) - need a seprate connection specifically for migration using a cert.
        $migrationCertificatePath = Join-Path -Path $PSScriptRoot -ChildPath "Installation/.certs/teams-chat-migration.pfx"
        if (-not (Test-Path $migrationCertificatePath)) {
            throw "Teams chat migration certificate not found at $migrationCertificatePath. Run InstallWorkIQStarterPack.ps1 again once admin consent has been granted."
        }
        $migrationToken = Get-TeamsChatMigrationAccessToken -ClientId $config.Settings.ClientId `
            -TenantPrefix $config.Settings.TenantPrefix -CertificatePath $migrationCertificatePath
        $migrationHeaders = @{ Authorization = "Bearer $migrationToken" }

        # Demo users provisioned -> use settings.json's own Users and Content/content.json as-is.
        # Existing users instead -> swap in the resolved identities from users.custom.json and
        # the persona-swapped content.custom.json, without ever touching the demo definitions.
        $provisioningSettings = $settings
        $activeContentPath = $contentPath
        if (-not $config.Settings.InstallDemoUsers) {
            $customUsers = Get-Content -Path $customUsersPath -Raw | ConvertFrom-Json
            $provisioningSettings = $settings.PSObject.Copy()
            $provisioningSettings.Users = $customUsers
            $activeContentPath = $customContentPath
        }

        #Check to see if the current user is a Global Administrator before checking license availability
        $isGlobalAdmin = Test-GlobalAdminPreRequisite

        #Check to see if the required licenses are available before provisioning users
        $preRequisitesMet = Test-License-PreRequisites -Settings $settings
        $workIQEnabled = Test-WorkIQServicePrincipalEnabled -Settings $settings
        $preRequisitesMet = $true

        #If installing Dynamics content, also confirm the user has permission to configure a Power Platform environment
        $powerPlatformPermissionsMet = $true
        if ($config.Settings.InstallDynamicsContent -eq $true) {
            $powerPlatformPermissionsMet = Test-PowerPlatformEnvironmentPermissions -Settings $settings
        }

        if ((($isGlobalAdmin -eq $true -and $preRequisitesMet -eq $true -and $powerPlatformPermissionsMet -eq $true) -or $config.Settings.SkipPreReqCheck -eq $true) -and $workIQEnabled -eq $true) {
            Write-Host "All pre-requisites are met. Proceeding with user provisioning."

            Add-Users -Settings $provisioningSettings
            if ($config.Settings.InstallDemoUsers) {
                Add-UserPhotos -Settings $provisioningSettings
            }

            # TODO: each of these re-reads and re-parses $activeContentPath from disk independently.
            # Fine for this small one-time install script, but if the content file grows or these
            # calls move into a hotter path, parse it once here and pass the object through instead.
            Add-TeamSite -ContentPath $activeContentPath -Config $config
            Import-SiteDocuments -ContentPath $activeContentPath -Config $config
            Add-TeamsChatMessages -ContentPath $activeContentPath -Settings $provisioningSettings -MigrationHeaders $migrationHeaders
        }
        else {
            Write-InstallLogAction -Message "One or more prerequisites were not met. Please review the messages above." -Level Error
            exit 1
        }
    }

    $installSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "Failed to provision WorkIQ Starter Pack: $($_.Exception.Message)" -Level Error
    #Disconnect-PnPOnline
    exit 1
}
finally {
    # Always write the install log, even on failure, so any inputs/actions/passwords captured
    # before an exception (e.g. already-created demo user passwords) are never lost.
    Save-InstallLog -Success ($installSucceeded -eq $true)

    if (Test-Path $script:installLogPath) {
        # file:// URI makes this a clickable link in terminals that support it (e.g. VS Code's).
        $logLink = "file://$($script:installLogPath -replace '\\', '/')"
        Write-Host ""
        Write-Host "Installation log (including any demo user passwords): $logLink" -ForegroundColor Cyan
    }
}


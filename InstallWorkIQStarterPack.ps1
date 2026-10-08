param(
    # Skip every install question and run straight from Configuration/config.json (for CLI/automated installs).
    [switch]$UseConfig
)

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
    if (-not $UseConfig) {
        Clear-Host
    }
    Write-Host ""
    # Load the configuration file from file system
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Load the installation settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    # settings.json emails carry a <TENANTPREFIX> token; resolve it from config.json once, in memory.
    foreach ($user in $settings.Users) {
        $user.Email = $user.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
    }

    # settings.json's Users list and Content/content.json always stay pristine demo data. When
    # InstallDemoUsers is false, the real users' resolved identities and the persona-swapped
    # content live in these separate "custom" files instead, so the demo definitions are never
    # overwritten.
    $customUsersPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/users.custom.json"
    $contentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.json"
    $customContentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.custom.json"

    #Load App Registration Service file
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")

    # Load the install log service and start recording this run's inputs/actions so
    # they're captured to a Markdown report under Logs/, even if the run fails partway through.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/InstallLogService.ps1")
    Initialize-InstallLog

    $currentTenant = $config.Settings.TenantPrefix
    if ($UseConfig) {
        if ([string]::IsNullOrWhiteSpace($currentTenant)) {
            throw "-UseConfig requires Settings.TenantPrefix in config.json."
        }
        $tenant = $currentTenant
    }
    else {
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
    }

    $config.Settings.TenantPrefix = ($tenant -replace '\.onmicrosoft\.com$', '')
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-InstallLogInput -Prompt "Tenant prefix" -Response $config.Settings.TenantPrefix

    # Ask whether to provision the built-in demo users, or point the starter pack's 5 role
    # slots at real, existing users instead. The UPNs are collected here (upfront, alongside
    # the other one-time setup questions); the actual Entra ID lookup happens later, once
    # Connect-WorkIQGraph has established a Graph connection.
    $provisionDemoUsers = if ($UseConfig) { [bool]$config.Settings.InstallDemoUsers } else { Read-YesNo "Do you want to provision the built-in demo users?" -Default $true }
    $config.Settings.InstallDemoUsers = $provisionDemoUsers
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-InstallLogInput -Prompt "Provision the built-in demo users?" -Response $(if ($provisionDemoUsers) { "Yes" } else { "No" })

    # Persisted so the email import step can be gated on it later. Demo users always get emails.
    $provisionEmails = $true
    $realUserUpns = $null
    if (-not $provisionDemoUsers) {
        if ($UseConfig) {
            $provisionEmails = [bool]$config.Settings.ProvisionUserEmails
        }
        else {
            Write-Host ""
            Write-Host "NOTICE: This starter pack will provision emails in the users' inboxes." -ForegroundColor Yellow
            Write-Host "        It should NOT be used in a production tenant." -ForegroundColor Yellow
            Write-Host ""
            $provisionEmails = Read-YesNo "Do you want to provision emails in the users' inboxes?" -Default $false
        }
        Write-InstallLogInput -Prompt "Provision emails in the users' inboxes?" -Response $(if ($provisionEmails) { "Yes" } else { "No" })

        $demoRoles = @(
            @{ Label = "Marketing user"; Index = 0 },
            @{ Label = "Finance user"; Index = 1 },
            @{ Label = "Security/Governance user"; Index = 2 },
            @{ Label = "Finance user 2"; Index = 3 },
            @{ Label = "Sales user"; Index = 4 }
        )

        $configUpns = @($config.Settings.RealUserUpns)
        if ($UseConfig -and ($configUpns.Count -ne $demoRoles.Count -or @($configUpns | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)) {
            throw "-UseConfig with InstallDemoUsers=false requires Settings.RealUserUpns in config.json to list $($demoRoles.Count) UPNs."
        }

        $realUserUpns = @{}
        foreach ($role in $demoRoles) {
            if ($UseConfig) {
                $upn = "$($configUpns[$role.Index])".Trim()
            }
            else {
                do {
                    $upn = (Read-Host "Enter the UPN for the $($role.Label)").Trim()
                } while ([string]::IsNullOrWhiteSpace($upn))
            }

            $realUserUpns[$role.Index] = $upn
            Write-InstallLogInput -Prompt "UPN for the $($role.Label)" -Response $upn
        }
    }

    # Add-Member -Force so configs that predate this setting still work.
    $config.Settings | Add-Member -NotePropertyName ProvisionUserEmails -NotePropertyValue $provisionEmails -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Ask which starter pack content pack(s) to install. At least one must be selected, otherwise
    # the content-provisioning block below has nothing to do.
    if ($UseConfig) {
        $installM365Content = [bool]$config.Settings.InstallM365Content
        $installDynamicsContent = [bool]$config.Settings.InstallDynamicsContent
    }
    else {
        $installM365Content = Read-YesNo "Do you want to install the M365 WorkIQ Starter Pack Content?" -Default $true
        $installDynamicsContent = Read-YesNo "Do you want to install the Dynamics WorkIQ Starter Pack Content?" -Default $true
    }
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
    # With -UseConfig, a ClientId in config.json means use that existing app registration; otherwise one is created.
    $hasAppRegistration = if ($UseConfig) { -not [string]::IsNullOrWhiteSpace($config.Settings.ClientId) } else { Read-YesNo "Do you have an existing Application Registration? Please review the README.md file for the level of permissions required." -Default $false }
    Write-InstallLogInput -Prompt "Do you have an existing Application Registration?" -Response $(if ($hasAppRegistration) { "Yes" } else { "No" })

    # If they have an app reg then ask for the client ID.
    if ($hasAppRegistration) {
        
        $storedClientID = $config.Settings.ClientId
        if ($UseConfig) {
            $clientId = $storedClientID
        }
        else {
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
        }
        Write-InstallLogInput -Prompt "Application registration client ID" -Response $clientId

        $config.Settings.ClientId = $clientId
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

        Write-InstallLogAction -Message "Client ID saved to $configPath" -Level Success

        Connect-WorkIQPnP -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $clientId -Force
        Update-AppRegistrationPermissions -ClientId $clientId -TenantPrefix $config.Settings.TenantPrefix | Out-Null
    }
    else {
        # If they don't have an app reg create one.
        $appName = if ($UseConfig) { $config.Settings.AppRegistrationName } else { Read-Host "Enter the name for your application registration (default: WorkIQStarterPack)" }
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

    # If the installer opted out of the demo users, look up each supplied UPN's real profile in
    # Entra ID. Resolved users go into Configuration/users.custom.json and the persona-swapped content into
    # Content/content.custom.json - settings.json's
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1")
    if ($null -eq $realUserUpns) {
        Update-ContentPersonas -SourcePath $contentPath -OutputPath $customContentPath -TenantPrefix $config.Settings.TenantPrefix
    }
    else {
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")

        $demoUsers = $settings.Users | ForEach-Object { $_.PSObject.Copy() }
        $customUsersSettings = [PSCustomObject]@{ Users = ($settings.Users | ForEach-Object { $_.PSObject.Copy() }) }
        $customUsersSettings = Resolve-RealUsers -Settings $customUsersSettings -RealUserUpns $realUserUpns
        $customUsersSettings.Users | ConvertTo-Json -Depth 10 | Set-Content -Path $customUsersPath

        Update-ContentPersonas -SourcePath $contentPath -OutputPath $customContentPath -TenantPrefix $config.Settings.TenantPrefix -DemoUsers $demoUsers -RealUsers $customUsersSettings.Users -RealUserUpns $realUserUpns
    }

    # ---------------------Start App Configuration------------------------------------
    
    # You need to install one of the content packs to proceed.
    if ($config.Settings.InstallM365Content -eq $true -or $config.Settings.InstallDynamicsContent -eq $true) {
        #L oad services files
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/LicensingService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/WorkIQService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/TeamsService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/SharePointService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/EmailService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/MeetingService.ps1")
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
        $activeContentPath = $customContentPath
        if (-not $config.Settings.InstallDemoUsers) {
            $customUsers = Get-Content -Path $customUsersPath -Raw | ConvertFrom-Json
            $provisioningSettings = $settings.PSObject.Copy()
            $provisioningSettings.Users = $customUsers
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

            # Parse the content file once and provision it one site at a time: each site gets its team,
            # documents, lists/libraries, chats and emails before moving on to the next.
            $contentConfig = Get-Content -Path $activeContentPath -Raw | ConvertFrom-Json
            $runJitter = [TimeSpan]::FromMilliseconds((Get-Date).Second * 1000 + (Get-Date).Millisecond)

            # The same certificate token carries Mail.ReadWrite, so it also serves the inbox import.
            # $settings.Users are always the demo personas the email markdown is written with.
            if (-not $config.Settings.ProvisionUserEmails) {
                Write-InstallLogAction -Message "Skipping email provisioning (not confirmed by the user)."
            }

            foreach ($site in @(Get-EligibleSites -ContentConfig $contentConfig -Config $config)) {
                Write-InstallLogAction -Message "Provisioning site '$($site.Title)'..."

                if (-not (Add-TeamSite -Site $site -Config $config)) {
                    Write-InstallLogAction -Message "Skipping the remaining content for site '$($site.Title)' because its team could not be created." -Level Warning
                    continue
                }

                Import-SiteDocuments -Site $site -Config $config
                Add-SiteListsAndLibraries -Site $site -Config $config
                # The meeting posts are imported with the chats: a channel can only be migrated once.
                $meetingMessages = Add-TeamMeetings -Site $site -Config $config -Settings $provisioningSettings -DemoUsers $settings.Users
                Add-TeamsChatMessages -Site $site -Settings $provisioningSettings -MigrationHeaders $migrationHeaders -RunJitter $runJitter -ExtraMessages $meetingMessages
                if ($config.Settings.ProvisionUserEmails) {
                    Import-UserEmails -Site $site -ContentConfig $contentConfig -ContentPath $activeContentPath -Settings $provisioningSettings -DemoUsers $settings.Users -MailHeaders $migrationHeaders
                }
            }
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
    exit 1
}
finally {
    # Always drop the PnP connection, whether the install succeeded or failed
    Disconnect-PnPOnline -ErrorAction SilentlyContinue

    Save-InstallLog -Success ($installSucceeded -eq $true)

    if (Test-Path $script:installLogPath) {
        # file:// URI makes this a clickable link in terminals that support it (e.g. VS Code's).
        $logLink = "file://$($script:installLogPath -replace '\\', '/')"
        Write-Host ""
        Write-Host "Installation log (including any demo user passwords): $logLink" -ForegroundColor Cyan
    }
}


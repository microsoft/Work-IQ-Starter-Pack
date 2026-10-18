param(
    # Skip every install question and run straight from Configuration/config.json (for CLI/automated installs).
    [switch]$UseConfig
)

try {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Write-Host "PnP.PowerShell module was not found. It will now be installed for the current user."
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
    Initialize-InstallLog -Title "WorkIQ Starter Pack Mini Installation Log" -FileName "InstallMiniLog.md"

    Write-Host "Mini installer: provisions users, security groups, and Dynamics leads, accounts, contacts, price lists, and published products when selected. M365 content and mailbox emails are not installed."
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

    # Resolve user emails after the selected tenant has been saved.
    foreach ($user in $settings.Users) {
        $user.Email = $user.Email.Replace('<TENANTPREFIX>', $config.Settings.TenantPrefix)
    }
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

    # Prompt for each environment immediately after selecting its content pack.
    $installM365Content = if ($UseConfig) { [bool]$config.Settings.InstallM365Content } else { Read-YesNo "Do you want to install the M365 WorkIQ Starter Pack Content?" -Default $true }
    Write-InstallLogInput -Prompt "Install the M365 WorkIQ Starter Pack Content?" -Response $(if ($installM365Content) { "Yes" } else { "No" })
    $installDynamicsContent = if ($UseConfig) { [bool]$config.Settings.InstallDynamicsContent } else { Read-YesNo "Do you want to install the Dynamics WorkIQ Starter Pack Content?" -Default $true }
    Write-InstallLogInput -Prompt "Install the Dynamics WorkIQ Starter Pack Content?" -Response $(if ($installDynamicsContent) { "Yes" } else { "No" })
    if ($installDynamicsContent) {
        $environmentUrl = $config.Settings.DynamicsEnvironmentUrl
        if (-not $UseConfig) {
            do {
                $prompt = "Enter the Dynamics 365 Sales & Customer Service environment URL (e.g. https://contoso.crm.dynamics.com)"
                if (-not [string]::IsNullOrWhiteSpace($environmentUrl)) {
                    $prompt += " (default: $environmentUrl)"
                }
                $answer = (Read-Host $prompt).Trim()
                if (-not [string]::IsNullOrWhiteSpace($answer)) { $environmentUrl = $answer }
            } while ([string]::IsNullOrWhiteSpace($environmentUrl))
        }
        $environmentUri = $null
        if (-not [Uri]::TryCreate($environmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
            $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
            $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
            throw "Provide an HTTPS environment root URL in Settings.DynamicsEnvironmentUrl or at the prompt."
        }
        $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
        $config.Settings | Add-Member -NotePropertyName DynamicsEnvironmentUrl -NotePropertyValue $environmentUrl -Force
        Write-InstallLogInput -Prompt "Dynamics 365 Sales & Customer Service environment URL" -Response $environmentUrl
    }
    $installDynamicsFOContent = if ($UseConfig) { [bool]$config.Settings.InstallDynamicsFOContent } else { Read-YesNo "Do you want to install the Dynamics 365 F&O WorkIQ Starter Pack Content?" -Default $false }
    Write-InstallLogInput -Prompt "Install the Dynamics 365 F&O WorkIQ Starter Pack Content?" -Response $(if ($installDynamicsFOContent) { "Yes" } else { "No" })
    if ($installDynamicsFOContent) {
        $foEnvironmentUrl = $config.Settings.DynamicsFOEnvironmentUrl
        if (-not $UseConfig) {
            do {
                $prompt = "Enter the Dynamics 365 F&O environment URL (e.g. https://contoso.operations.dynamics.com)"
                if (-not [string]::IsNullOrWhiteSpace($foEnvironmentUrl)) {
                    $prompt += " (default: $foEnvironmentUrl)"
                }
                $answer = (Read-Host $prompt).Trim()
                if (-not [string]::IsNullOrWhiteSpace($answer)) { $foEnvironmentUrl = $answer }
            } while ([string]::IsNullOrWhiteSpace($foEnvironmentUrl))
        }
        $foEnvironmentUri = $null
        if (-not [Uri]::TryCreate($foEnvironmentUrl, [UriKind]::Absolute, [ref]$foEnvironmentUri) -or
            $foEnvironmentUri.Scheme -ne 'https' -or $foEnvironmentUri.UserInfo -or
            $foEnvironmentUri.AbsolutePath -ne '/' -or $foEnvironmentUri.Query -or $foEnvironmentUri.Fragment) {
            throw "Provide an HTTPS environment root URL in Settings.DynamicsFOEnvironmentUrl or at the prompt."
        }
        $foEnvironmentUrl = $foEnvironmentUri.GetLeftPart([UriPartial]::Authority)
        $config.Settings | Add-Member -NotePropertyName DynamicsFOEnvironmentUrl -NotePropertyValue $foEnvironmentUrl -Force
        Write-InstallLogInput -Prompt "Dynamics 365 F&O environment URL" -Response $foEnvironmentUrl
    }
    if (-not $installM365Content -and -not $installDynamicsContent -and -not $installDynamicsFOContent) {
        throw 'You must select at least one of the M365, Dynamics, or Dynamics F&O Content options to proceed.'
    }
    $config.Settings.InstallM365Content = $installM365Content
    $config.Settings.InstallDynamicsContent = $installDynamicsContent
    $config.Settings | Add-Member -NotePropertyName InstallDynamicsFOContent -NotePropertyValue $installDynamicsFOContent -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Check if the user needs the app registration created
    # With -UseConfig, a ClientId in config.json means use that existing app registration; otherwise one is created.
    $hasAppRegistration = if ($UseConfig) { -not [string]::IsNullOrWhiteSpace($config.Settings.ClientId) } else { Read-YesNo "Do you have an existing Application Registration? Please review the README.md file for the level of permissions required." -Default $true }
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
        Connect-WorkIQPnP -SharePointUrl $registration.SharePointUrl -ClientId $registration.ClientId -Force
        Update-AppRegistrationPermissions -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix | Out-Null

        # Reload configuration in case Set-AppRegistrationConfig updated config.json.
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }

    # Connect to SharePoint Online using PnP PowerShell. This is done once here and the resulting
    Connect-WorkIQGraph -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId

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

    # Mini installation uses the same configuration and identity resolution as the
    # full installer, with users, security groups, and selected Dynamics provisioning.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/PowerPlatformService.ps1")

    $provisioningSettings = $settings
    if (-not $config.Settings.InstallDemoUsers) {
        $provisioningSettings = $settings.PSObject.Copy()
        $provisioningSettings.Users = Get-Content -Path $customUsersPath -Raw | ConvertFrom-Json
    }

    if (-not $config.Settings.SkipPreReqCheck) {
        $isGlobalAdmin = Test-GlobalAdminPreRequisite
        if (-not $isGlobalAdmin) {
            throw "One or more prerequisites were not met. Please review the messages above."
        }
    }

    if ($config.Settings.InstallDynamicsContent -eq $true) {
        $dynamicsEnvironment = Show-DynamicsEnvironmentSecurityGroup -Config $config
    }
    Add-Users -Settings $provisioningSettings -SkipLicenses
    $contentConfig = Get-Content -Path $customContentPath -Raw | ConvertFrom-Json
    foreach ($site in @(Get-EligibleSites -ContentConfig $contentConfig -Config $config)) {
        Add-Groups -Site $site -Settings $provisioningSettings
    }

    if ($config.Settings.InstallDynamicsContent -eq $true) {
        Initialize-PowerPlatformUsers -Config $config -Settings $provisioningSettings -Environment $dynamicsEnvironment
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/DynamicsService.ps1")
        Install-DynamicsFieldEngagementSolution -Config $config
        Set-PowerPlatformUserSecurityRoles -Config $config -Settings $provisioningSettings
        Initialize-DynamicsIdentityMap -Config $config -Settings $provisioningSettings
        $continueDeployment = Read-YesNo 'Environment user checks are complete. Do you want to continue with demo data deployment?' -Default $false
        Write-InstallLogInput -Prompt 'Continue with demo data deployment?' -Response $(if ($continueDeployment) { 'Yes' } else { 'No' })
        if (-not $continueDeployment) {
            Write-InstallLogAction -Message 'Demo data deployment stopped at the user confirmation step.'
            $installSucceeded = $true
            return
        }
        Add-DynamicsLeads -Config $config
        Add-DynamicsAccounts -Config $config
        Add-DynamicsContacts -Config $config
        Update-DynamicsAccountPrimaryContacts -Config $config
        Add-DynamicsPriceLists -Config $config
        Add-DynamicsProducts -Config $config
        Add-DynamicsOpportunities -Config $config
        Add-DynamicsQuotes -Config $config
        Add-DynamicsOrders -Config $config
        Add-DynamicsInvoices -Config $config
        Add-DynamicsIncidents -Config $config
        Add-DynamicsEmails -Config $config
        Add-DynamicsFieldEngagements -Config $config
        Set-DynamicsDemoOwners -Config $config
    }

    if ($config.Settings.InstallDynamicsFOContent -eq $true) {
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/DynamicsFOService.ps1")
        Add-DynamicsFOContent -Config $config -Settings $provisioningSettings -ConfigPath $configPath -UseConfig:$UseConfig
    }

    if (@($script:installLogActions | Where-Object { $_.Level -eq "Error" }).Count -gt 0) {
        throw "Mini installation finished with errors. Please review the installation log."
    }
    $installSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "Failed to provision WorkIQ Starter Pack mini installation: $($_.Exception.Message)" -Level Error
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



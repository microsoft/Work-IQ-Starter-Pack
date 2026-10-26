param(
    # Path to a config.json file. When supplied, every install question is skipped and the installer runs
    # straight from that file (for CLI/automated installs). Omit it to be prompted and use Configuration/config.json.
    [string]$ConfigPath
)

# Passing -ConfigPath is what switches the installer to unattended mode.
$UseConfig = -not [string]::IsNullOrWhiteSpace($ConfigPath)
if ($UseConfig -and -not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "The file passed to -ConfigPath was not found: $ConfigPath"
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
    if ($UseConfig) {
        $configPath = (Resolve-Path -LiteralPath $ConfigPath).ProviderPath
    }
    else {
        $configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
    }
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Load the installation settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    # settings.json's Users list and Content/content.json always stay pristine demo data. When
    # InstallDemoUsers is false, the real users' resolved identities and the persona-swapped
    # content live in these separate "custom" files instead, so the demo definitions are never
    # overwritten.
    $customUsersPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/Users.custom.json"
    $contentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.json"
    $customContentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.custom.json"

    #Load App Registration Service file
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegService.ps1")

    # Load the install log service and start recording this run's inputs/actions so
    # they're captured to a Markdown report under Logs/, even if the run fails partway through.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/InstallLogService.ps1")
    Initialize-InstallLog -Title "WorkIQ Starter Pack Mini Installation Log" -FileName "InstallMiniLog.md"

    Write-Host "Mini installer: provisions Users and D365 Sales & CS Leads, Accounts, Contacts, Price Lists, and Published Products when selected. M365 content and mailbox Emails are not installed."
    $currentTenant = $config.Settings.TenantPrefix
    if ($UseConfig) {
        if ([string]::IsNullOrWhiteSpace($currentTenant)) {
            throw "-ConfigPath requires Settings.TenantPrefix in config.json."
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
    # Browser authentication has established access to Microsoft Graph.
    $provisionDemoUsers = if ($UseConfig) { [bool]$config.Settings.InstallDemoUsers } else { Read-YesNo "Do you want to provision the built-in demo Users?" -Default $true }
    $config.Settings.InstallDemoUsers = $provisionDemoUsers
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
    Write-InstallLogInput -Prompt "Provision the built-in demo Users?" -Response $(if ($provisionDemoUsers) { "Yes" } else { "No" })

    # Persisted so the email import step can be gated on it later. Demo users always get emails.
    $provisionEmails = $true
    $realUserUpns = $null
    if (-not $provisionDemoUsers) {
        if ($UseConfig) {
            $provisionEmails = [bool]$config.Settings.ProvisionUserEmails
        }
        else {
            Write-Host ""
            Write-Host "NOTICE: This starter pack will provision Emails in the Users' inboxes." -ForegroundColor Yellow
            Write-Host "        It should NOT be used in a production tenant." -ForegroundColor Yellow
            Write-Host ""
            $provisionEmails = Read-YesNo "Do you want to provision Emails in the Users' inboxes?" -Default $false
        }
        Write-InstallLogInput -Prompt "Provision Emails in the Users' inboxes?" -Response $(if ($provisionEmails) { "Yes" } else { "No" })

        $demoRoles = @(
            @{ Label = "Marketing user"; Index = 0 },
            @{ Label = "Finance user"; Index = 1 },
            @{ Label = "Security/Governance user"; Index = 2 },
            @{ Label = "Finance user 2"; Index = 3 },
            @{ Label = "Sales user"; Index = 4 }
        )

        $configUpns = @($config.Settings.RealUserUpns)
        if ($UseConfig -and ($configUpns.Count -ne $demoRoles.Count -or @($configUpns | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)) {
            throw "-ConfigPath with InstallDemoUsers=false requires Settings.RealUserUpns in config.json to list $($demoRoles.Count) UPNs."
        }

        $savedContentUpns = @()
        if (-not $UseConfig -and (Test-Path -LiteralPath $customContentPath)) {
            try {
                $savedContent = Get-Content -LiteralPath $customContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                $savedContentUpns = @($savedContent.RealUserUpns)
            }
            catch { Write-Verbose "Could not load saved UPN defaults: $($_.Exception.Message)" }
        }
        $realUserUpns = @{}
        foreach ($role in $demoRoles) {
            if ($UseConfig) {
                $upn = "$($configUpns[$role.Index])".Trim()
            }
            else {
                do {
                    $defaultUpn = if ($role.Index -lt $configUpns.Count -and -not [string]::IsNullOrWhiteSpace($configUpns[$role.Index])) {
                        ([string]$configUpns[$role.Index]).Trim()
                    }
                    elseif ($role.Index -lt $savedContentUpns.Count) { ([string]$savedContentUpns[$role.Index]).Trim() }
                    else { '' }
                    $prompt = "Enter the UPN for the $($role.Label)"
                    if (-not [string]::IsNullOrWhiteSpace($defaultUpn)) { $prompt += " (default: $defaultUpn)" }
                    $upn = (Read-Host $prompt).Trim()
                    if ([string]::IsNullOrWhiteSpace($upn)) { $upn = $defaultUpn }
                } while ([string]::IsNullOrWhiteSpace($upn))
            }

            $realUserUpns[$role.Index] = $upn
            Write-InstallLogInput -Prompt "UPN for the $($role.Label)" -Response $upn
        }
        $selectedUpns = @($demoRoles | ForEach-Object { $realUserUpns[$_.Index] })
        $config.Settings | Add-Member -NotePropertyName RealUserUpns -NotePropertyValue $selectedUpns -Force
    }

    # Add-Member -Force so configs that predate this setting still work.
    $config.Settings | Add-Member -NotePropertyName ProvisionUserEmails -NotePropertyValue $provisionEmails -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Prompt for each environment immediately after selecting its content pack.
    $installDynamicsContent = if ($UseConfig) { [bool]$config.Settings.InstallDynamicsContent } else { Read-YesNo "Do you want to install the Dynamics 365 Sales and Customer Service (D365 Sales & CS) WorkIQ Starter Pack Content?" -Default $true }
    Write-InstallLogInput -Prompt "Install the D365 Sales & CS WorkIQ Starter Pack Content?" -Response $(if ($installDynamicsContent) { "Yes" } else { "No" })
    $createDynamicsEnvironment = $false
    if ($installDynamicsContent) {
        # Automated installs keep using the configured environment.
        $createDynamicsEnvironment = if ($UseConfig) { $false } else { Read-YesNo 'Do you want to create a new Dataverse environment?' -Default $false }
        Write-InstallLogInput -Prompt 'Create a new Dataverse environment?' -Response $(if ($createDynamicsEnvironment) { 'Yes' } else { 'No' })
        if (-not $createDynamicsEnvironment) {
        $environmentUrl = $config.Settings.DynamicsEnvironmentUrl
        if (-not $UseConfig) {
            do {
                $prompt = "Enter the D365 Sales & CS environment URL (e.g. https://contoso.crm.dynamics.com)"
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
        Write-InstallLogInput -Prompt "D365 Sales & CS environment URL" -Response $environmentUrl
        }
    }
    $installDynamicsFOContent = if ($UseConfig) { [bool]$config.Settings.InstallDynamicsFOContent } else { Read-YesNo "Do you want to install the Dynamics 365 Finance & Operations (D365 F&O) WorkIQ Starter Pack Content?" -Default $false }
    Write-InstallLogInput -Prompt "Install the D365 F&O WorkIQ Starter Pack Content?" -Response $(if ($installDynamicsFOContent) { "Yes" } else { "No" })
    if ($installDynamicsFOContent) {
        $foEnvironmentUrl = $config.Settings.DynamicsFOEnvironmentUrl
        if (-not $UseConfig) {
            do {
                $prompt = "Enter the D365 F&O environment URL (e.g. https://contoso.operations.dynamics.com)"
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
        Write-InstallLogInput -Prompt "D365 F&O environment URL" -Response $foEnvironmentUrl
    }
    if (-not $installDynamicsContent -and -not $installDynamicsFOContent) {
        throw 'You must select D365 Sales & CS or D365 F&O Content to proceed.'
    }
    $config.Settings.InstallDynamicsContent = $installDynamicsContent
    $config.Settings | Add-Member -NotePropertyName InstallDynamicsFOContent -NotePropertyValue $installDynamicsFOContent -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

    # Check if the user needs the app registration created
    # With -ConfigPath, a ClientId in config.json means use that existing app registration; otherwise one is created.
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

        Update-AppRegistrationPermissions -ClientId $clientId -TenantPrefix $config.Settings.TenantPrefix | Out-Null
    }
    else {
        # If they don't have an app reg create one.
        $appName = if ($UseConfig) { $config.Settings.AppRegistrationName } else { Read-Host "Enter the name for your new application registration (default: WorkIQStarterPack)" }
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = "WorkIQStarterPack"
        }
        Write-InstallLogInput -Prompt "Application registration name" -Response $appName

        $registration = New-AppRegistration -Tenant $config.Settings.TenantPrefix -AppName $appName
        Set-AppRegistrationConfig -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix -ConfigPath $configPath | Out-Null
        # New-AppRegistration has already configured and consented all JSON permissions.

        # Reload configuration in case Set-AppRegistrationConfig updated config.json.
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
    }

    # One browser sign-in for the registered app; reuse its refresh token for APIs.
    $installerTenant = "$($config.Settings.TenantPrefix).onmicrosoft.com"
    $installerClientId = [guid]$config.Settings.ClientId
    $installerSignIn = Get-AppRegBrowserAccessToken -Tenant $installerTenant -AuthenticationClientId $installerClientId -Scope 'https://graph.microsoft.com/.default offline_access' -ReturnTokenResponse
    if (-not $installerSignIn.refresh_token) { throw 'Sign-in did not return a refresh token for the selected APIs.' }
    $installerAuthentication = @{ RefreshToken = $installerSignIn.refresh_token }
    $installerTokens = @{
        'https://graph.microsoft.com' = @{ Token = $installerSignIn.access_token; Expires = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, [int]$installerSignIn.expires_in - 120)) }
    }
    $installerSignIn = $null
    $installerTokenProvider = {
        param([string]$Scope)
        $resource = $Scope.Substring(0, $Scope.LastIndexOf('/'))
        if (-not $installerTokens.ContainsKey($resource) -or $installerTokens[$resource].Expires -lt [DateTime]::UtcNow) {
            $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$installerTenant/oauth2/v2.0/token" -Body @{
                client_id = $installerClientId.ToString()
                grant_type = 'refresh_token'
                refresh_token = $installerAuthentication.RefreshToken
                scope = "$resource/.default"
            } -ErrorAction Stop
            if (-not $response.access_token) { throw "No token returned for '$resource'. Check admin consent for this API." }
            if ($response.refresh_token) { $installerAuthentication.RefreshToken = $response.refresh_token }
            $installerTokens[$resource] = @{ Token = $response.access_token; Expires = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, [int]$response.expires_in - 120)) }
        }
        return $installerTokens[$resource].Token
    }
    $global:graphBaseUrl = 'https://graph.microsoft.com/v1.0'
    $global:headers = @{ Authorization = "Bearer $(& $installerTokenProvider 'https://graph.microsoft.com/.default')" }

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
    # full installer, with users and selected Dynamics provisioning.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/PowerPlatformService.ps1") -AccessTokenProvider $installerTokenProvider
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
        if ($createDynamicsEnvironment) {
            # Authentication and prerequisite checks are complete before provisioning.
            $environmentOptions = @{}
            foreach ($option in @(
                @{ Name = 'DisplayName'; Prompt = 'Environment display name'; Default = 'Caldova Demo' },
                @{ Name = 'Location'; Prompt = 'Environment location code (e.g. unitedstates or europe)'; Default = 'unitedstates' },
                @{ Name = 'EnvironmentType'; Prompt = 'Environment type (Sandbox, Production, Trial, Developer)'; Default = 'Sandbox' },
                @{ Name = 'BaseLanguage'; Prompt = 'Base language LCID (1033: English)'; Default = '1033' },
                @{ Name = 'CurrencyCode'; Prompt = 'Currency code'; Default = 'USD' }
            )) {
                $answer = (Read-Host "$($option.Prompt) (default: $($option.Default))").Trim()
                if (-not $answer) { $answer = $option.Default }
                $environmentOptions[$option.Name] = $answer
                Write-InstallLogInput -Prompt $option.Prompt -Response $answer
            }
            $environmentOptions.BaseLanguage = [int]$environmentOptions.BaseLanguage
            $environmentOptions.CurrencyCode = $environmentOptions.CurrencyCode.ToUpperInvariant()
            $environmentOptions.SecurityGroupId = ''
            Write-InstallLogInput -Prompt 'Environment security group object ID' -Response $(if ($environmentOptions.SecurityGroupId) { $environmentOptions.SecurityGroupId } else { 'None' })
            $newEnvironment = Invoke-InstallStep -Description 'Creating the Dataverse Environment' -Action { New-PowerPlatformDataverseEnvironment @environmentOptions }
            $newEnvironmentUri = $null
            if (-not [Uri]::TryCreate([string]$newEnvironment.dataverseOrganizationUrl, [UriKind]::Absolute, [ref]$newEnvironmentUri) -or
                $newEnvironmentUri.Scheme -ne 'https' -or $newEnvironmentUri.UserInfo -or
                $newEnvironmentUri.AbsolutePath -ne '/' -or $newEnvironmentUri.Query -or $newEnvironmentUri.Fragment -or
                -not $newEnvironment.environmentId) {
                throw 'Environment creation did not return a valid Dataverse root URL and environment ID.'
            }
            $environmentUrl = $newEnvironmentUri.GetLeftPart([UriPartial]::Authority)
            $config.Settings | Add-Member -NotePropertyName DynamicsEnvironmentId -NotePropertyValue $newEnvironment.environmentId -Force
            $config.Settings | Add-Member -NotePropertyName DynamicsEnvironmentUrl -NotePropertyValue $environmentUrl -Force
            $config | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath
            Write-InstallLogAction -Message "Using new Dataverse environment '$($newEnvironment.environmentId)' at $environmentUrl. Configuration saved." -Level Success
        }
        $dynamicsEnvironment = Show-DynamicsEnvironmentSecurityGroup -Config $config
    }
    Invoke-InstallStep -Description 'Provisioning Demo Users' -Action {
        Add-Users -Settings $provisioningSettings -SkipLicenses
    }

    if ($config.Settings.InstallDynamicsContent -eq $true) {
        Invoke-InstallStep -Description 'Synchronizing Users with Dataverse' -Action {
            Initialize-PowerPlatformUsers -Config $config -Settings $provisioningSettings -Environment $dynamicsEnvironment
        }
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/DynamicsService.ps1") -AccessTokenProvider $installerTokenProvider
        Invoke-InstallStep -Description 'Installing the D365 Sales & CS Field Engagement Solution' -Action {
            Install-DynamicsFieldEngagementSolution -Config $config
        }
        Invoke-InstallStep -Description 'Assigning Dataverse User Security Roles' -Action {
            Set-PowerPlatformUserSecurityRoles -Config $config -Settings $provisioningSettings
        }
        Invoke-InstallStep -Description 'Preparing D365 Sales & CS User Identities' -Action {
            Initialize-DynamicsIdentityMap -Config $config -Settings $provisioningSettings
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Leads' -Action {
            Add-DynamicsLeads -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Accounts' -Action {
            Add-DynamicsAccounts -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Contacts' -Action {
            Add-DynamicsContacts -Config $config
        }
        Invoke-InstallStep -Description 'Updating D365 Sales & CS Account Primary Contacts' -Action {
            Update-DynamicsAccountPrimaryContacts -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Price Lists' -Action {
            Add-DynamicsPriceLists -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Products' -Action {
            Add-DynamicsProducts -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Opportunities' -Action {
            Add-DynamicsOpportunities -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Quotes' -Action {
            Add-DynamicsQuotes -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Sales Orders' -Action {
            Add-DynamicsOrders -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Invoices' -Action {
            Add-DynamicsInvoices -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Cases' -Action {
            Add-DynamicsIncidents -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Emails' -Action {
            Add-DynamicsEmails -Config $config
        }
        Invoke-InstallStep -Description 'Creating D365 Sales & CS Field Engagements' -Action {
            Add-DynamicsFieldEngagements -Config $config
        }
        Invoke-InstallStep -Description 'Assigning D365 Sales & CS Record Owners' -Action {
            Set-DynamicsDemoOwners -Config $config
        }
        $deployDynamicsDocuments = Read-YesNo 'Do you want to deploy the SharePoint Documents connected to D365 Sales & CS?' -Default $false
        Write-InstallLogInput -Prompt 'Deploy SharePoint Documents connected to D365 Sales & CS?' -Response $(if ($deployDynamicsDocuments) { 'Yes' } else { 'No' })
        if ($deployDynamicsDocuments) {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsSharePointService.ps1') -AccessTokenProvider $installerTokenProvider
            $integrationReady = Invoke-InstallStep -Description 'Checking D365 Sales & CS SharePoint Integration' -Action {
                Wait-DynamicsSharePointAccountIntegration -Config $config
            }
            if ($integrationReady) {
                Invoke-InstallStep -Description 'Deploying D365 Sales & CS SharePoint Documents' -Action {
                    Initialize-DynamicsSharePointDocuments -Config $config
                }
            }
        }
    }

    if ($config.Settings.InstallDynamicsFOContent -eq $true) {
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/DynamicsFOService.ps1") -AccessTokenProvider $installerTokenProvider
        Invoke-InstallStep -Description 'Provisioning D365 F&O Demo Data' -Action {
            Add-DynamicsFOContent -Config $config -Settings $provisioningSettings -ConfigPath $configPath -UseConfig:$UseConfig
        }
    }

    if (@($script:installLogActions | Where-Object { $_.Level -eq "Error" }).Count -gt 0) {
        throw "Mini installation finished with errors. Please review the installation log."
    }
    Write-InstallLogAction -Message 'Completed all selected D365 Sales & CS installation steps.' -Level Success
    $installSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "Failed to provision WorkIQ Starter Pack mini installation: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    # Clear API credentials after the installation.
    if (Get-Variable installerTokens -ErrorAction SilentlyContinue) { $installerTokens.Clear() }
    if (Get-Variable installerAuthentication -ErrorAction SilentlyContinue) { $installerAuthentication.Clear() }
    $installerSignIn = $null
    $global:headers = $null

    Save-InstallLog -Success ($installSucceeded -eq $true)

    if (Test-Path $script:installLogPath) {
        # file:// URI makes this a clickable link in terminals that support it (e.g. VS Code's).
        $logLink = "file://$($script:installLogPath -replace '\\', '/')"
        Write-Host ""
        Write-Host "Installation log (including any demo user passwords): $logLink" -ForegroundColor Cyan
    }
}

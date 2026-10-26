param(
    # Read install choices from the selected file; browser sign-in is still required.
    [Alias('Config')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'Configuration/config.json')
)

$UseConfig = $PSBoundParameters.ContainsKey('ConfigPath')
. (Join-Path $PSScriptRoot 'Installation/Services/ConfigurationService.ps1')
$configurationPaths = Get-WorkIQConfigurationPaths -ConfigPath $ConfigPath -RepositoryRoot $PSScriptRoot
$configPath = $configurationPaths.ConfigPath

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
    $config = $configurationPaths.Config

    # Load the installation settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json

    # settings.json's Users list and Content/content.json always stay pristine demo data. When
    # InstallDemoUsers is false, the real users' resolved identities and the persona-swapped
    # content live in these separate "custom" files instead, so the demo definitions are never
    # overwritten.
    $customUsersPath = $configurationPaths.CustomUsersPath
    $contentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.json"
    $customContentPath = $configurationPaths.CustomContentPath
    New-Item -Path (Split-Path $customContentPath -Parent) -ItemType Directory -Force | Out-Null

    #Load App Registration Service file
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegService.ps1")

    # Load the install log service and start recording this run's inputs/actions so
    # they're captured to a Markdown report under Logs/, even if the run fails partway through.
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/InstallLogService.ps1")
    Initialize-InstallLog -LogDirectory $configurationPaths.LogDirectory
    Write-InstallLogInput -Prompt 'Configuration file' -Response $configPath

    $currentTenant = $config.Settings.TenantPrefix
    if ($UseConfig) {
        if ([string]::IsNullOrWhiteSpace($currentTenant)) {
            throw "-Config requires Settings.TenantPrefix in '$configPath'."
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
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
    Write-InstallLogInput -Prompt "Tenant prefix" -Response $config.Settings.TenantPrefix

    foreach ($user in $settings.Users) {
        $user.Email = $user.Email.Replace('<TENANTPREFIX>', $config.Settings.TenantPrefix)
    }
    # Ask whether to provision the built-in demo users, or point the starter pack's 5 role
    # slots at real, existing users instead. The UPNs are collected here.
    $provisionDemoUsers = if ($UseConfig) { [bool]$config.Settings.InstallDemoUsers } else { Read-YesNo "Do you want to provision the built-in demo users?" -Default $true }
    $config.Settings.InstallDemoUsers = $provisionDemoUsers
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
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
            throw "-Config with InstallDemoUsers=false requires Settings.RealUserUpns in '$configPath' to list $($demoRoles.Count) UPNs."
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
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath

    $installM365Content = if ($UseConfig) { [bool]$config.Settings.InstallM365Content } else { Read-YesNo "Do you want to install the M365 WorkIQ Starter Pack Content?" -Default $true }
    Write-InstallLogInput -Prompt "Install the M365 WorkIQ Starter Pack Content?" -Response $(if ($installM365Content) { "Yes" } else { "No" })
    $config.Settings.InstallM365Content = $installM365Content
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
    if (-not $installM365Content -and -not $installDynamicsContent -and -not $installDynamicsFOContent) {
        throw 'You must select M365, D365 Sales & CS, or D365 F&O Content to proceed.'
    }
    $config.Settings.InstallDynamicsContent = $installDynamicsContent
    $config.Settings | Add-Member -NotePropertyName InstallDynamicsFOContent -NotePropertyValue $installDynamicsFOContent -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath

    # Scope app registration creation, updates, and consent to the selected APIs.
    $requiredResourceIds = @(
        '00000003-0000-0000-c000-000000000000' # Microsoft Graph
        '00000003-0000-0ff1-ce00-000000000000' # SharePoint
    )
    if ($installDynamicsContent) {
        $requiredResourceIds += '00000007-0000-0000-c000-000000000000' # Dynamics CRM
        $requiredResourceIds += '8578e004-a5c6-46e7-913e-12f58912df43' # Power Platform
    }
    if ($installDynamicsFOContent) {
        $requiredResourceIds += '00000015-0000-0000-c000-000000000000' # Dynamics ERP
    }
    # Check if the user needs the app registration created
    # With -Config, a ClientId in the selected file means use that app registration; otherwise one is created.
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
        $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath

        Write-InstallLogAction -Message "Client ID saved to $configPath" -Level Success


        Update-AppRegistrationPermissions -ClientId $clientId -TenantPrefix $config.Settings.TenantPrefix -RequiredResourceIds $requiredResourceIds | Out-Null
    }
    else {
        # If they don't have an app reg create one.
        $appName = if ($UseConfig) { $config.Settings.AppRegistrationName } else { Read-Host "Enter the name for your new application registration (default: WorkIQStarterPack)" }
        if ([string]::IsNullOrWhiteSpace($appName)) {
            $appName = "WorkIQStarterPack"
        }
        Write-InstallLogInput -Prompt "Application registration name" -Response $appName

        $registration = New-AppRegistration -Tenant $config.Settings.TenantPrefix -AppName $appName -RequiredResourceIds $requiredResourceIds
        Set-AppRegistrationConfig -ClientId $registration.ClientId -TenantPrefix $registration.TenantPrefix -ConfigPath $configPath | Out-Null

        # Reload configuration in case Set-AppRegistrationConfig updated config.json.
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
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

    if ([string]::IsNullOrWhiteSpace($config.Settings.ClientId)) {
        throw "No application registration client ID was found in config.json."
    }

    # If the installer opted out of the demo users, look up each supplied UPN's real profile in
    # Entra ID. Resolved users go into Configuration/users.custom.json and the persona-swapped content into
    # Content/content.custom.json - settings.json's
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1") -ImportedPostsPath $configurationPaths.ImportedPostsPath
    if ($null -eq $realUserUpns) {
        Update-ContentPersonas -SourcePath $contentPath -OutputPath $customContentPath -TenantPrefix $config.Settings.TenantPrefix
    }
    else {
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")

        $demoUsers = $settings.Users | ForEach-Object { $_.PSObject.Copy() }
        $customUsersSettings = [PSCustomObject]@{ Users = ($settings.Users | ForEach-Object { $_.PSObject.Copy() }) }
        $customUsersSettings = Resolve-RealUsers -Settings $customUsersSettings -RealUserUpns $realUserUpns
        $customUsersSettings.Users | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $customUsersPath

        Update-ContentPersonas -SourcePath $contentPath -OutputPath $customContentPath -TenantPrefix $config.Settings.TenantPrefix -DemoUsers $demoUsers -RealUsers $customUsersSettings.Users -RealUserUpns $realUserUpns
    }

    # ---------------------Start App Configuration------------------------------------
    # Check the lab prerequisites for every content pack before provisioning.
    . (Join-Path $PSScriptRoot 'Installation/Services/PowerPlatformService.ps1') -AccessTokenProvider $installerTokenProvider
    $isGlobalAdmin = Test-GlobalAdminPreRequisite
    if (-not $isGlobalAdmin) {
        throw "One or more prerequisites were not met. Please review the messages above."
    }

    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/LicensingService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/WorkIQService.ps1")

    $provisioningSettings = $settings
    if (-not $config.Settings.InstallDemoUsers) {
        $provisioningSettings = $settings.PSObject.Copy()
        $provisioningSettings.Users = Get-Content -LiteralPath $customUsersPath -Raw | ConvertFrom-Json
    }

    $preRequisitesMet = Test-License-PreRequisites -Settings $provisioningSettings
    $copilotCreditsAvailable = Test-CopilotCreditBalance
    if (-not $preRequisitesMet -or -not $copilotCreditsAvailable) {
        throw "One or more prerequisites were not met. Please review the messages above."
    }

    Enable-WorkIQServicePrincipal -Settings $settings | Out-Null
    $workIQEnabled = Test-WorkIQServicePrincipalEnabled -Settings $settings
    if (-not $workIQEnabled) {
        throw "One or more prerequisites were not met. Please review the messages above."
    }
    Write-Host "All pre-requisites are met. Proceeding with user provisioning."

    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
    Invoke-InstallStep -Description 'Provisioning Users and Licenses' -Action {
        Add-Users -Settings $provisioningSettings
    }

    # M365 provisioning runs only when its content pack was selected.
    if ($installM365Content) {
        Connect-WorkIQGraph -SharePointUrl "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId
        Initialize-TeamsChatMigrationCertificate -ClientId $config.Settings.ClientId -CertificateDirectory $configurationPaths.CertificateDirectory

        #Load services files
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/TeamsService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/SharePointService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/ContentService.ps1") -ImportedPostsPath $configurationPaths.ImportedPostsPath
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/EmailService.ps1")
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/MeetingService.ps1")


        # Teams chat history import uses Microsoft Graph's message migration API - need a seprate connection specifically for migration using a cert.
        $migrationCertificatePath = $configurationPaths.CertificatePath
        if (-not (Test-Path -LiteralPath $migrationCertificatePath)) {
            throw "Teams chat migration certificate not found at $migrationCertificatePath. Run InstallWorkIQStarterPack.ps1 again once admin consent has been granted."
        }
        $migrationToken = Get-TeamsChatMigrationAccessToken -ClientId $config.Settings.ClientId `
            -TenantPrefix $config.Settings.TenantPrefix -CertificatePath $migrationCertificatePath
        $migrationHeaders = @{ Authorization = "Bearer $migrationToken" }

        $activeContentPath = $customContentPath

        if ($config.Settings.InstallDemoUsers) {
            Add-UserPhotos -Settings $provisioningSettings
        }

        # Parse the content file once and provision it one site at a time: each site gets its team,
        # documents, lists/libraries, chats and emails before moving on to the next.
        $contentConfig = Get-Content -LiteralPath $activeContentPath -Raw | ConvertFrom-Json
        $runJitter = [TimeSpan]::FromMilliseconds((Get-Date).Second * 1000 + (Get-Date).Millisecond)

        # The same certificate token carries Mail.ReadWrite, so it also serves the inbox import.
        # $settings.Users are always the demo personas the email markdown is written with.
        if (-not $config.Settings.ProvisionUserEmails) {
            Write-InstallLogAction -Message "Skipping email provisioning (not confirmed by the user)."
        }

        #Confirm that the licenses are available
        $licensesAvailable = Test-License-PreRequisites -Settings $provisioningSettings

        $powerPlatformPermissionsMet = $true
        if ($isGlobalAdmin -eq $true -and $licensesAvailable -eq $true -and $powerPlatformPermissionsMet -eq $true -and $copilotCreditsAvailable -eq $true -and $workIQEnabled -eq $true) {
            Write-Host "All pre-requisites are met. Proceeding with user provisioning."

            Add-Groups -Site $site -Settings $provisioningSettings

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

    if ($installDynamicsContent -or $installDynamicsFOContent) {
        # Dynamics provisioning reuses the shared identities and app registration.
        . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/PowerPlatformService.ps1") -AccessTokenProvider $installerTokenProvider

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
                $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
                Write-InstallLogAction -Message "Using new Dataverse environment '$($newEnvironment.environmentId)' at $environmentUrl. Configuration saved." -Level Success
            }
            $dynamicsEnvironment = Show-DynamicsEnvironmentSecurityGroup -Config $config
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
            $deployDynamicsDocuments = if ($UseConfig) { [bool]$config.Settings.DeployDynamicsDocuments } else { Read-YesNo 'Do you want to deploy the SharePoint Documents connected to D365 Sales & CS?' -Default $false }
            $config.Settings | Add-Member -NotePropertyName DeployDynamicsDocuments -NotePropertyValue $deployDynamicsDocuments -Force
            $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath
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
            throw "Installation finished with errors. Please review the installation log."
        }
        Write-InstallLogAction -Message 'Completed all selected Dynamics installation steps.' -Level Success
    }
    $installSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "Failed to provision WorkIQ Starter Pack: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if (Get-Variable installerTokens -ErrorAction SilentlyContinue) { $installerTokens.Clear() }
    if (Get-Variable installerAuthentication -ErrorAction SilentlyContinue) { $installerAuthentication.Clear() }
    $installerSignIn = $null
    # Always drop the PnP connection, whether the install succeeded or failed
    # Disconnect-PnPOnline throws a terminating error when there is no connection, which -ErrorAction does not suppress.
    try { Disconnect-PnPOnline } catch { }

    Save-InstallLog -Success ($installSucceeded -eq $true)

    if (Test-Path -LiteralPath $script:installLogPath) {
        # file:// URI makes this a clickable link in terminals that support it (e.g. VS Code's).
        $logLink = "file://$($script:installLogPath -replace '\\', '/')"
        Write-Host ""
        Write-Host "Installation log (including any demo user passwords): $logLink" -ForegroundColor Cyan
    }
}

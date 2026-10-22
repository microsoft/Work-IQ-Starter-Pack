#Requires -Version 7.4

# Independently clean Dynamics and D365 F&O demo records using source IDs/codes.
$cleanupSucceeded = $false
. (Join-Path $PSScriptRoot 'Installation/Services/InstallLogService.ps1')
Initialize-InstallLog -Title 'WorkIQ Starter Pack Mini Cleanup Log' -FileName 'CleanUpLog.md' -IncludePasswords $false

function Read-MiniCleanupChoice {
    param([string]$Prompt, [bool]$Default = $false)
    $defaultText = if ($Default) { 'yes' } else { 'no' }
    do {
        $answer = (Read-Host "$Prompt (yes/no, default: $defaultText)").Trim().ToLowerInvariant()
    } while ($answer -notin @('', 'yes', 'y', 'no', 'n'))
    $selected = if ($answer -eq '') { $Default } else { $answer -in @('yes', 'y') }
    Write-InstallLogInput -Prompt $Prompt -Response $(if ($selected) { 'Yes' } else { 'No' })
    return $selected
}

function Read-MiniCleanupEnvironmentUrl {
    param([string]$Label, [string]$Example, [string]$Default, [string]$SettingName)
    $environmentUrl = $Default
    do {
        $prompt = "Enter the $Label environment URL (e.g. $Example)"
        if (-not [string]::IsNullOrWhiteSpace($environmentUrl)) {
            $prompt += " (default: $environmentUrl)"
        }
        $answer = (Read-Host $prompt).Trim()
        if (-not [string]::IsNullOrWhiteSpace($answer)) { $environmentUrl = $answer }
    } while ([string]::IsNullOrWhiteSpace($environmentUrl))
    $environmentUri = $null
    if (-not [Uri]::TryCreate($environmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "Provide an HTTPS environment root URL in Settings.$SettingName or at the prompt."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    Write-InstallLogInput -Prompt "$Label environment URL" -Response $environmentUrl
    return $environmentUrl
}

function Invoke-MiniCleanupStep {
    param([string]$Description, [string]$ActionVerb = 'Deleting', [string]$CompletedVerb = 'deleting', [scriptblock]$Action)
    Write-Host ''
    Write-InstallLogAction -Message "$ActionVerb $Description..."
    & $Action
    Write-InstallLogAction -Message "Finished $CompletedVerb $Description." -Level Success
}

try {
    $configPath = Join-Path $PSScriptRoot 'Configuration/config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $contentPath = Join-Path $PSScriptRoot 'Content/contentDynamics.json'
    $content = Get-Content -LiteralPath $contentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    . (Join-Path $PSScriptRoot 'Installation/Services/AppRegService.ps1')
    $currentTenant = $config.Settings.TenantPrefix
    do {
        $prompt = 'Enter your tenant prefix name (e.g. caldova from caldova.onmicrosoft.com)'
        if (-not [string]::IsNullOrWhiteSpace($currentTenant)) {
            $prompt += " (default: $currentTenant)"
        }
        $tenant = (Read-Host $prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($tenant)) { $tenant = $currentTenant }
        $tenant = $tenant -replace '\.onmicrosoft\.com$', ''
    } while ([string]::IsNullOrWhiteSpace($tenant))
    $config.Settings | Add-Member -NotePropertyName TenantPrefix -NotePropertyValue $tenant -Force
    Write-InstallLogInput -Prompt 'Tenant prefix' -Response $tenant

    $hasAppRegistration = Read-MiniCleanupChoice 'Do you have an existing Application Registration? Please review the README.md file for the level of permissions required.' -Default $true
    if ($hasAppRegistration) {
        $storedClientID = $config.Settings.ClientId
        do {
            $prompt = 'Enter the application registration client ID'
            if (-not [string]::IsNullOrWhiteSpace($storedClientID)) {
                $prompt += " (default: $storedClientID)"
            }
            $clientId = (Read-Host $prompt).Trim()
            if ([string]::IsNullOrWhiteSpace($clientId)) { $clientId = $storedClientID }
        } while ([string]::IsNullOrWhiteSpace($clientId))
        $null = [guid]::Parse($clientId)
        Write-InstallLogInput -Prompt 'Application registration client ID' -Response $clientId
    }
    else {
        throw 'Cleanup requires an existing app registration with all required permissions and admin consent already granted. Run InstallWorkIQDynamicsPack.ps1 to create or configure one first.'
    }

    Write-Host 'D365 Sales & CS cleanup deletes demo Emails, Cases, Invoices, Orders, Quotes, Opportunities, Leads, Accounts, and Product catalog records by their IDs in Content/contentDynamics.json.'
    $deleteDynamics = Read-MiniCleanupChoice 'Do you want to delete the Dynamics 365 Sales and Customer Service (D365 Sales & CS) demo data?'
    $removeSolution = $false
    if ($deleteDynamics) {
        $environmentUrl = Read-MiniCleanupEnvironmentUrl -Label 'D365 Sales & CS' -Example 'https://contoso.crm.dynamics.com' -Default $config.Settings.DynamicsEnvironmentUrl -SettingName 'DynamicsEnvironmentUrl'
        $config.Settings | Add-Member -NotePropertyName DynamicsEnvironmentUrl -NotePropertyValue $environmentUrl -Force
        Write-Host 'Removing the managed Field Engagement solution also removes its custom table, app, and any remaining Field Engagement records.'
        $removeSolution = Read-MiniCleanupChoice 'Do you also want to remove the Caldova Field Engagement solution?'
    }
    Write-Host "D365 F&O cleanup deletes $(@($content.Orders).Count) demo Sales Orders and their lines, $(@($content.Accounts).Count) demo customers by Account code in company '$($config.Settings.DynamicsFOLegalEntityId)' and $(@($content.Products).Count) shared Products by Product number. Shared Products apply across companies."
    $deleteFO = Read-MiniCleanupChoice 'Do you want to delete the Dynamics 365 Finance & Operations (D365 F&O) demo data?'
    if ($deleteFO) {
        $foEnvironmentUrl = Read-MiniCleanupEnvironmentUrl -Label 'D365 F&O' -Example 'https://contoso.operations.dynamics.com' -Default $config.Settings.DynamicsFOEnvironmentUrl -SettingName 'DynamicsFOEnvironmentUrl'
        $config.Settings | Add-Member -NotePropertyName DynamicsFOEnvironmentUrl -NotePropertyValue $foEnvironmentUrl -Force
    }
    $deleteSharePoint = Read-MiniCleanupChoice 'Do you want to remove the uploaded D365 Sales & CS SharePoint integration files?'
    if (-not $deleteDynamics -and -not $deleteFO -and -not $deleteSharePoint) {
        Write-InstallLogAction -Message 'No cleanup selected.'
        $cleanupSucceeded = $true
        return
    }
    $requiredResourceIds = @('00000003-0000-0000-c000-000000000000') # Microsoft Graph
    # SharePoint cleanup reads the integration site from Dataverse, so it also needs CRM.
    if ($deleteDynamics -or $removeSolution -or $deleteSharePoint) {
        $requiredResourceIds += '00000007-0000-0000-c000-000000000000' # Dynamics CRM
    }
    if ($deleteFO) { $requiredResourceIds += '00000015-0000-0000-c000-000000000000' } # Dynamics ERP / AX
    if ($deleteSharePoint) { $requiredResourceIds += '00000003-0000-0ff1-ce00-000000000000' } # SharePoint
    $requiredSettings = @('TenantPrefix')
    if ($deleteDynamics -or $deleteSharePoint) { $requiredSettings += 'DynamicsEnvironmentUrl' }
    if ($deleteFO) { $requiredSettings += @('DynamicsFOEnvironmentUrl','DynamicsFOLegalEntityId') }
    foreach ($setting in $requiredSettings) {
        if ([string]::IsNullOrWhiteSpace($config.Settings.$setting)) { throw "Settings.$setting is required in Configuration/config.json." }
    }
    $config.Settings.ClientId = $clientId
    $cleanupTokens = @{}
    $cleanupTenant = "$($config.Settings.TenantPrefix).onmicrosoft.com"
    $cleanupClientId = [guid]$clientId
    # Open the app's authorization flow directly, using only existing Graph grants.
    # Entra can show consent when no grant exists; do not approve it during cleanup.
    Write-Host 'Sign in to the existing app registration. If Microsoft displays Permissions requested, cancel and configure admin consent separately with the installer.'
    $signIn = Get-AppRegBrowserAccessToken -Tenant $cleanupTenant -AuthenticationClientId $cleanupClientId -Scope 'https://graph.microsoft.com/.default offline_access' -ReturnTokenResponse
    Assert-AppRegistrationPermissions -ClientId $clientId -AccessToken $signIn.access_token -RequiredResourceIds $requiredResourceIds
    if (-not $signIn.refresh_token) { throw 'Sign-in did not return a refresh token. Cleanup requires offline_access to reuse this sign-in for the selected APIs.' }
    $cleanupTokens['https://graph.microsoft.com'] = @{ Token = $signIn.access_token; Expires = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, [int]$signIn.expires_in - 120)) }
    $cleanupAuthentication = @{ RefreshToken = $signIn.refresh_token }
    $signIn = $null
    $cleanupTokenProvider = {
        param([string]$Scope)
        $resource = $Scope.Substring(0, $Scope.LastIndexOf('/'))
        $resourceUri = [uri]$resource
        if (-not $resourceUri.IsAbsoluteUri -or $resourceUri.Scheme -ne 'https' -or $resourceUri.UserInfo -or $resourceUri.Query -or $resourceUri.Fragment) { throw 'Invalid cleanup resource URL.' }
        if (-not $cleanupTokens.ContainsKey($resource) -or $cleanupTokens[$resource].Expires -lt [DateTime]::UtcNow) {
            try {
                $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$cleanupTenant/oauth2/v2.0/token" -Body @{
                    client_id = $cleanupClientId.ToString()
                    grant_type = 'refresh_token'
                    refresh_token = $cleanupAuthentication.RefreshToken
                    scope = "$resource/.default"
                } -ErrorAction Stop
            }
            catch {
                throw "Unable to obtain existing access to '$resource' from the initial sign-in. Cleanup will not request consent or open another sign-in window. Check existing consent and tenant authentication policies. $($_.Exception.Message)"
            }
            if (-not $response.access_token) { throw "No access token returned for '$resource'." }
            if ($response.refresh_token) { $cleanupAuthentication.RefreshToken = $response.refresh_token }
            $cleanupTokens[$resource] = @{ Token = $response.access_token; Expires = [DateTime]::UtcNow.AddSeconds([Math]::Max(0, [int]$response.expires_in - 120)) }
        }
        return $cleanupTokens[$resource].Token
    }
    # Acquire every selected API token before any deletion begins.
    if ($deleteDynamics -or $deleteSharePoint) { $null = & $cleanupTokenProvider "$($config.Settings.DynamicsEnvironmentUrl.TrimEnd('/'))/user_impersonation" }
    if ($deleteFO) { $null = & $cleanupTokenProvider "$($config.Settings.DynamicsFOEnvironmentUrl.TrimEnd('/'))/Odata.FullAccess" }
    if ($deleteSharePoint) { $null = & $cleanupTokenProvider "https://$($config.Settings.TenantPrefix).sharepoint.com/.default" }
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -ErrorAction Stop

    $failures = @()
    if ($deleteSharePoint) {
        try {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsSharePointService.ps1') -AccessTokenProvider $cleanupTokenProvider
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS SharePoint Documents' -ActionVerb 'Recycling' -CompletedVerb 'recycling' -Action {
                Initialize-DynamicsSharePointDocuments -Config $config -ContentPath $contentPath -RemoveDocuments
            }
        }
        catch {
            $failures += "D365 Sales & CS SharePoint: $($_.Exception.Message)"
            Write-InstallLogAction -Message $failures[-1] -Level Error
        }
    }
    if ($deleteDynamics) {
        try {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsService.ps1') -AccessTokenProvider $cleanupTokenProvider
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Field Engagements' -Action {
                Remove-DynamicsFieldEngagements -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Emails' -Action {
                Remove-DynamicsEmails -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Cases' -Action {
                Remove-DynamicsIncidents -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Invoices' -Action {
                Remove-DynamicsInvoices -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Sales Orders' -Action {
                Remove-DynamicsOrders -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Quotes' -Action {
                Remove-DynamicsQuotes -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Opportunities' -Action {
                Remove-DynamicsOpportunities -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Product Catalog Records' -Action {
                Remove-DynamicsProductCatalog -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Leads' -Action {
                Remove-DynamicsLeads -Config $config -ContentPath $contentPath
            }
            Invoke-MiniCleanupStep -Description 'D365 Sales & CS Accounts' -Action {
                Remove-DynamicsAccounts -Config $config -ContentPath $contentPath
            }
            Write-Host 'D365 Sales & CS demo data deletion completed.'
        }
        catch {
            $failures += "D365 Sales & CS: $($_.Exception.Message)"
            Write-InstallLogAction -Message $failures[-1] -Level Error
        }
        # Honor the separately confirmed uninstall even if a data-cleanup step failed.
        if ($removeSolution) {
            try {
                Invoke-MiniCleanupStep -Description 'the Caldova Field Engagement Solution' -ActionVerb 'Removing' -CompletedVerb 'removing' -Action {
                    Remove-DynamicsFieldEngagementSolution -Config $config
                }
            }
            catch {
                $failures += "D365 Sales & CS Solution Uninstall: $($_.Exception.Message)"
                Write-InstallLogAction -Message $failures[-1] -Level Error
            }
        }
    }
    if ($deleteFO) {
        try {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsFOService.ps1') -AccessTokenProvider $cleanupTokenProvider
            Invoke-MiniCleanupStep -Description 'D365 F&O Demo Data' -Action {
                Remove-DynamicsFOContent -Config $config -ContentPath $contentPath
            }
        }
        catch {
            $failures += "D365 F&O: $($_.Exception.Message)"
            Write-InstallLogAction -Message $failures[-1] -Level Error
        }
    }
    if ($failures.Count) { throw ($failures -join ' | ') }
    $cleanupSucceeded = $true
    Write-InstallLogAction -Message 'Selected mini cleanup operations complete.' -Level Success
}
catch {
    Write-InstallLogAction -Message "Mini cleanup failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if (Get-Variable cleanupTokens -ErrorAction SilentlyContinue) { $cleanupTokens.Clear() }
    if (Get-Variable cleanupAuthentication -ErrorAction SilentlyContinue) { $cleanupAuthentication.Clear() }
    $signIn = $null
    Save-InstallLog -Success $cleanupSucceeded
    Write-Host "Cleanup log: $script:installLogPath"
}

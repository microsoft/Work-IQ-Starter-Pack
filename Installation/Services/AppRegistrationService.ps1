# get the permissions from the settings file.
$WorkIQSettingsPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Configuration/settings.json"))
$WorkIQAppRegistrationPermissions = (Get-Content -Path $WorkIQSettingsPath -Raw | ConvertFrom-Json).AppRegistrationPermissions
$WorkIQGraphDelegatePermissions = @($WorkIQAppRegistrationPermissions.GraphDelegate)
$WorkIQGraphApplicationPermissions = @($WorkIQAppRegistrationPermissions.GraphApplication)
$WorkIQSharePointDelegatePermissions = @($WorkIQAppRegistrationPermissions.SharePointDelegate)

# appIds of the Microsoft Graph and SharePoint Online service principals.
$GraphResourceAppId = "00000003-0000-0000-c000-000000000000"
$SharePointResourceAppId = "00000003-0000-0ff1-ce00-000000000000"

function New-AppRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Tenant,
        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    $tenantName = $Tenant
    if ($tenantName -notlike "*.onmicrosoft.com") {
        $tenantName = "$tenantName.onmicrosoft.com"
    }

    try {
        $app = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName $AppName -Tenant $tenantName `
            -GraphDelegatePermissions $WorkIQGraphDelegatePermissions `
            -SharePointDelegatePermissions $WorkIQSharePointDelegatePermissions `
            -GraphApplicationPermissions $WorkIQGraphApplicationPermissions
    }
    catch {
        throw "Failed to register the app: $($_.Exception.Message)"
    }

    $clientId = $app.'AzureAppId/ClientId'
    $tenantPrefix = $tenantName.Split('.')[0]
    $sharePointUrl = "https://$($tenantName -replace '\.onmicrosoft\.com$', '.sharepoint.com')"

    return [PSCustomObject]@{
        ClientId      = $clientId
        TenantPrefix  = $tenantPrefix
        SharePointUrl = $sharePointUrl
    }
}

function Set-AppRegistrationConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$TenantPrefix,
        [string]$ConfigPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Configuration/settings.json"))
    )

    try {
        $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
        $config.Settings.ClientId = $ClientId
        $config.Settings.TenantPrefix = $TenantPrefix
        $config | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigPath
        Write-InstallLogAction -Message "Updated config.json with ClientId: $ClientId and TenantPrefix: $TenantPrefix"
        return $true
    }
    catch {
        Write-Host "Could not automatically update config.json - paste these values in yourself: Settings.ClientId = $ClientId, Settings.TenantPrefix = $TenantPrefix" -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return $false
    }
}

function Connect-WorkIQPnP {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl,
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [switch]$Force
    )

    if (-not $Force -and $global:workIQPnPClientId -eq $ClientId -and (Get-PnPConnection -ErrorAction SilentlyContinue)) {
        return
    }

    Disconnect-PnPOnline -ErrorAction SilentlyContinue
    Connect-PnPOnline -Url $SharePointUrl -ClientId $ClientId -Interactive
    $global:workIQPnPClientId = $ClientId
}

function Add-DynamicsAppRegistrationPermissions {
    param([string]$ClientId)
    $token = Get-PnPAccessToken -Scopes 'https://graph.microsoft.com/.default' -ErrorAction Stop
    $graphHeaders = @{ Authorization = "Bearer $token" }
    $graphUrl = 'https://graph.microsoft.com/v1.0'
    $application = Invoke-RestMethod -Uri "$graphUrl/applications(appId='$ClientId')?`$select=id,requiredResourceAccess" -Headers $graphHeaders -Method Get -ErrorAction Stop
    $resourceAccessByApp = [ordered]@{}
    foreach ($resource in @($application.requiredResourceAccess)) {
        $resourceAccessByApp[$resource.resourceAppId] = [System.Collections.Generic.List[object]]@(
            $resource.resourceAccess | ForEach-Object { @{ id = $_.id; type = $_.type } }
        )
    }
    $added = @()
        $dynamicsPermissions = @(
            @{ ResourceAppId = '00000007-0000-0000-c000-000000000000'; ResourceName = 'Dynamics CRM'; Id = '78ce3f0f-a1ce-49c2-8cde-64b5c0896db4'; Name = 'user_impersonation' }
            @{ ResourceAppId = '00000015-0000-0000-c000-000000000000'; ResourceName = 'Dynamics ERP'; Id = '6397893c-2260-496b-a41d-2f1f15b16ff3'; Name = 'Odata.FullAccess' }
            @{ ResourceAppId = '8578e004-a5c6-46e7-913e-12f58912df43'; ResourceName = 'Power Platform API'; Id = '7a11470a-3968-43d4-af14-8fc4e6afcec1'; Name = 'EnvironmentManagement.Settings.ReadWrite' }
            @{ ResourceAppId = '8578e004-a5c6-46e7-913e-12f58912df43'; ResourceName = 'Power Platform API'; Id = 'd8ed48a4-d90b-481c-b222-e9e342f38d58'; Name = 'EnvironmentManagement.Groups.ReadWrite' }
            @{ ResourceAppId = '8578e004-a5c6-46e7-913e-12f58912df43'; ResourceName = 'Power Platform API'; Id = '177690ed-85f1-41d9-8dbf-2716e60ff46a'; Name = 'EnvironmentManagement.Environments.Read' }
        )

        foreach ($permission in $dynamicsPermissions) {
            if (-not $resourceAccessByApp.Contains($permission.ResourceAppId)) {
                $resourceAccessByApp[$permission.ResourceAppId] = [System.Collections.Generic.List[object]]::new()
            }
            $access = $resourceAccessByApp[$permission.ResourceAppId]
            if (-not @($access | Where-Object { $_.id -eq $permission.Id -and $_.type -eq 'Scope' }).Count) {
                $access.Add(@{ id = $permission.Id; type = 'Scope' })
                $added += "$($permission.ResourceName) $($permission.Name) (Delegated)"
            }
        }

    if ($added.Count) {
        $resources = @(foreach ($key in $resourceAccessByApp.Keys) {
            @{resourceAppId=$key;resourceAccess=@($resourceAccessByApp[$key])}
        })
        $body = @{requiredResourceAccess=$resources} | ConvertTo-Json -Depth 6
        Invoke-RestMethod -Uri "$graphUrl/applications/$($application.id)" -Headers $graphHeaders -Method Patch -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
        $added | ForEach-Object { Write-InstallLogAction -Message "Added API permission after admin grant: $_" }
        Write-InstallLogAction -Message 'The newly added Dynamics and Power Platform permissions require a subsequent admin consent grant before use.' -Level Warning
    }
    else { Write-InstallLogAction -Message 'All Dynamics and Power Platform API permissions are already configured.' }
}

function Update-AppRegistrationPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$TenantPrefix
    )

    try {
        $token = Get-PnPAccessToken -Scopes "https://graph.microsoft.com/.default"
        $grantedScopes = (ConvertFrom-AccessToken -Token $token).scp -split ' '
    }
    catch {
        throw "Failed to get a Microsoft Graph token for app registration $($ClientId): $($_.Exception.Message)"
    }

    if ("Application.ReadWrite.All" -notin $grantedScopes) {
        throw "The app registration $ClientId does not have admin consent for the delegated Microsoft Graph permission Application.ReadWrite.All, so the installer can't check or add the permissions it needs. Add Application.ReadWrite.All (Microsoft Graph, Delegated) under API permissions on the app registration, grant admin consent, then run the installer again."
    }

    $step = "read the app registration"

    try {
        $graphHeaders = @{ Authorization = "Bearer $token" }
        $graphUrl = "https://graph.microsoft.com/v1.0"

        $application = Invoke-RestMethod -Uri "$graphUrl/applications(appId='$ClientId')?`$select=id,requiredResourceAccess" -Headers $graphHeaders -Method Get

        $required = @(
            @{ ResourceAppId = $GraphResourceAppId; Type = "Scope"; Names = $WorkIQGraphDelegatePermissions }
            @{ ResourceAppId = $GraphResourceAppId; Type = "Role"; Names = $WorkIQGraphApplicationPermissions }
            @{ ResourceAppId = $SharePointResourceAppId; Type = "Scope"; Names = $WorkIQSharePointDelegatePermissions }
        )

        $resourceAccessByApp = [ordered]@{}
        foreach ($resource in @($application.requiredResourceAccess)) {
            $resourceAccessByApp[$resource.resourceAppId] = [System.Collections.Generic.List[object]]@(
                $resource.resourceAccess | ForEach-Object { @{ id = $_.id; type = $_.type } }
            )
        }

        $servicePrincipals = @{}
        $added = @()

        foreach ($requirement in $required) {
            $resourceAppId = $requirement.ResourceAppId

            if (-not $servicePrincipals.ContainsKey($resourceAppId)) {
                $step = "look up the permissions exposed by resource $resourceAppId"
                $servicePrincipals[$resourceAppId] = Invoke-RestMethod -Uri "$graphUrl/servicePrincipals(appId='$resourceAppId')?`$select=displayName,appRoles,oauth2PermissionScopes" -Headers $graphHeaders -Method Get
            }
            $servicePrincipal = $servicePrincipals[$resourceAppId]
            $definitions = if ($requirement.Type -eq "Role") { $servicePrincipal.appRoles } else { $servicePrincipal.oauth2PermissionScopes }

            if (-not $resourceAccessByApp.Contains($resourceAppId)) {
                $resourceAccessByApp[$resourceAppId] = [System.Collections.Generic.List[object]]::new()
            }
            $resourceAccess = $resourceAccessByApp[$resourceAppId]

            foreach ($name in $requirement.Names) {
                $definition = $definitions | Where-Object { $_.value -eq $name } | Select-Object -First 1
                if (-not $definition) {
                    throw "$($servicePrincipal.displayName) does not expose a permission named '$name' - check AppRegistrationPermissions in settings.json."
                }

                if (-not ($resourceAccess | Where-Object { $_.id -eq $definition.id -and $_.type -eq $requirement.Type })) {
                    $resourceAccess.Add(@{ id = $definition.id; type = $requirement.Type })
                    $kind = if ($requirement.Type -eq "Role") { "Application" } else { "Delegated" }
                    $added += "$($servicePrincipal.displayName) $name ($kind)"
                }
            }
        }

        if ($added) {
            $requiredResourceAccess = @(foreach ($resourceAppId in $resourceAccessByApp.Keys) {
                    @{ resourceAppId = $resourceAppId; resourceAccess = @($resourceAccessByApp[$resourceAppId]) }
                })
            $body = @{ requiredResourceAccess = $requiredResourceAccess } | ConvertTo-Json -Depth 6

            $step = "update the app registration's API permissions"
            Invoke-RestMethod -Uri "$graphUrl/applications/$($application.id)" -Headers $graphHeaders -Method Patch -ContentType "application/json" -Body $body | Out-Null

            Write-InstallLogAction -Message "Added missing permissions to the app registration:" -Level Warning
            $added | ForEach-Object { Write-InstallLogAction -Message "  - $_" -Level Warning }
        }
        else {
            Write-InstallLogAction -Message "The app registration has all required permissions."
        }

        # Permissions that are configured but not yet consented also need the admin consent step.
        $unconsentedScopes = $WorkIQGraphDelegatePermissions | Where-Object { $_ -notin $grantedScopes }
        if (-not $added -and -not $unconsentedScopes) {
            Add-DynamicsAppRegistrationPermissions -ClientId $ClientId
            return $false
        }

        $consentUrl = "https://login.microsoftonline.com/$TenantPrefix.onmicrosoft.com/adminconsent?client_id=$ClientId"
        Write-Host "Admin consent is required for the app registration's permissions. Opening the consent page - if it doesn't open, browse to:" -ForegroundColor Yellow
        Write-Host "  $consentUrl" -ForegroundColor Yellow
        try {
            Start-Process $consentUrl
        }
        catch {
            # Opening the browser is best-effort, the URL is printed above.
        }
        if ($UseConfig) {
            Write-Host "Running with -UseConfig: continuing without waiting. Grant admin consent at the URL above if it has not been granted yet." -ForegroundColor Yellow
        }
        else {
            Read-Host "Press Enter once admin consent has been granted" | Out-Null
            Add-DynamicsAppRegistrationPermissions -ClientId $ClientId
        }

        return $true
    }
    catch {
        $message = "Failed to check the app registration's permissions (could not $step): $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) {
            $message += " The signed-in account must be an owner of the app registration or hold the Application Administrator, Cloud Application Administrator or Global Administrator role."
        }
        throw $message
    }
}

function Connect-WorkIQGraph {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl,
        [Parameter(Mandatory = $true)]
        [string]$ClientId
    )

    Connect-WorkIQPnP -SharePointUrl $SharePointUrl -ClientId $ClientId

    $global:graphBaseUrl = "https://graph.microsoft.com/v1.0"
    $global:headers = @{ Authorization = "Bearer $(Get-WorkIQGraphAccessToken)" }
}

function Get-WorkIQGraphAccessToken {
    $defaultScope = "https://graph.microsoft.com/.default"
    $namedScopes = $WorkIQGraphDelegatePermissions | ForEach-Object { "https://graph.microsoft.com/$_" }
    $scopes = $defaultScope
    $maxAttempts = 12
    $reason = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $token = Get-PnPAccessToken -Scopes $scopes
            $grantedScopes = (ConvertFrom-AccessToken -Token $token).scp -split ' '

            $missingScopes = $WorkIQGraphDelegatePermissions | Where-Object { $_ -notin $grantedScopes }
            if (-not $missingScopes) {
                return $token
            }
            $reason = "token is missing $($missingScopes -join ', ')"
            $scopes = $namedScopes
        }
        catch {
            $reason = $_.Exception.Message
        }

        if ($attempt -lt $maxAttempts) {
            Write-Host "Waiting for admin consent to reach the Graph token - $reason (attempt $attempt of $maxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }

    throw "Could not get a Microsoft Graph token with the required permissions ($reason). Check that admin consent is granted for $($WorkIQGraphDelegatePermissions -join ', ') on the app registration, then run the installer again."
}

function Get-TeamsChatMigrationAccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$TenantPrefix,
        [Parameter(Mandatory = $true)]
        [string]$CertificatePath
    )

    $maxAttempts = 10
    $reason = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $connection = Connect-PnPOnline -Url "https://$TenantPrefix.sharepoint.com" `
                -ClientId $ClientId -Tenant "$TenantPrefix.onmicrosoft.com" `
                -CertificatePath $CertificatePath -ReturnConnection
            $token = Get-PnPAccessToken -ResourceTypeName Graph -Scopes "https://graph.microsoft.com/.default" -Connection $connection

            # Teamwork.Migrate.All (Teams chat import) and Mail.ReadWrite (inbox import) are both
            # application permissions served by this one certificate token.
            $grantedRoles = (ConvertFrom-AccessToken -Token $token).roles
            $missingRoles = $WorkIQGraphApplicationPermissions | Where-Object { $_ -notin $grantedRoles }
            if (-not $missingRoles) {
                return $token
            }
            $reason = "token is missing $($missingRoles -join ', ')"
        }
        catch {
            if ($_.Exception.Message -notmatch "AADSTS700027") {
                throw
            }
            $reason = "certificate not accepted yet"
        }

        if ($attempt -lt $maxAttempts) {
            Write-Host "Waiting for the Teams chat migration certificate and permissions to propagate in Entra ID - $reason (attempt $attempt of $maxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 30
        }
    }

    throw "Could not sign in with the Teams chat migration certificate ($reason). Check that the certificate is listed under Certificates & secrets and that admin consent is granted for $($WorkIQGraphApplicationPermissions -join ', ') on the app registration, then run the installer again."
}

function ConvertFrom-AccessToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $payload = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload += '=' * ((4 - $payload.Length % 4) % 4)
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Initialize-TeamsChatMigrationCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$SharePointUrl
    )

    $step = "prepare the certificate files"

    try {
        $certDir = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Installation/.certs"))
        $pfxPath = Join-Path -Path $certDir -ChildPath "teams-chat-migration.pfx"
        $cerPath = Join-Path -Path $certDir -ChildPath "teams-chat-migration.cer"

        if ((Test-Path $pfxPath) -and (Test-Path $cerPath)) {
            Write-Host "Reusing existing Teams chat migration certificate files at $certDir."
        }
        else {
            New-Item -ItemType Directory -Path $certDir -Force | Out-Null

            New-PnPAzureCertificate `
                -CommonName "WorkIQStarterPack-TeamsChatMigration" `
                -OutPfx $pfxPath `
                -OutCert $cerPath `
                -ValidYears 2 | Out-Null

            Write-Host "Created new certificate files."
        }

        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($cerPath)
        $publicKeyBase64 = [Convert]::ToBase64String($cert.GetRawCertData())
        $thumbprintBase64 = [Convert]::ToBase64String($cert.GetCertHash())

        $step = "read the app registration"
        $application =Invoke-RestMethod -Uri "$graphBaseUrl/applications(appId='$ClientId')?`$select=id,keyCredentials" -Headers $headers -Method Get

        $alreadyRegistered = $application.keyCredentials | Where-Object { $_.customKeyIdentifier -eq $thumbprintBase64 }
        if ($alreadyRegistered) {
            Write-Host "The Teams chat migration certificate is already registered on the app registration."
            return
        }

        $newCredential = @{
            customKeyIdentifier = $thumbprintBase64
            type                = "AsymmetricX509Cert"
            usage               = "Verify"
            key                 = $publicKeyBase64
            displayName         = "TeamsChatMigration"
        }
        $mergedCredentials = @($application.keyCredentials) + $newCredential
        $body = @{ keyCredentials = $mergedCredentials } | ConvertTo-Json -Depth 6

        $step = "update the app registration's keyCredentials"
        Invoke-RestMethod -Uri "$graphBaseUrl/applications/$($application.id)" -Headers $headers -Method Patch -ContentType "application/json" -Body $body

        Write-Host "Registered the Teams chat migration certificate on the app registration."
    }
    catch {
        $message = "Failed to register the Teams chat migration certificate (could not $step): $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 403) {
            $message += " The signed-in account needs admin consent for the delegated Application.ReadWrite.All permission, and must be an owner of the app registration or hold the Application Administrator, Cloud Application Administrator or Global Administrator role. Alternatively, upload $cerPath manually under Certificates & secrets on the app registration."
        }
        throw $message
    }
}

function Remove-AppRegistration {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId
    )

    try {
        $application = (Invoke-RestMethod -Uri "$graphBaseUrl/applications?`$filter=appId eq '$ClientId'" -Headers $headers -Method Get).value | Select-Object -First 1

        if (-not $application) {
            Write-InstallLogAction "No application registration found for ClientId $ClientId, skipping." -Level Warning
            return
        }

        Invoke-RestMethod -Uri "$graphBaseUrl/applications/$($application.id)" -Headers $headers -Method Delete
        Write-InstallLogAction "Deleted application registration '$($application.displayName)' (ClientId: $ClientId)."
    }
    catch {
        throw "Failed to remove the application registration for ClientId $($ClientId): $($_.Exception.Message)"
    }
}

function Remove-TeamsChatMigrationCertificate {
    try {
        $certDir = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Installation/.certs"))

        if (Test-Path $certDir) {
            Remove-Item -Path $certDir -Recurse -Force
            Write-InstallLogAction "Removed local Teams chat migration certificate files at $certDir."
        }
        else {
            Write-InstallLogAction "No local Teams chat migration certificate files found, skipping."
        }
    }
    catch {
        throw "Failed to remove local Teams chat migration certificate files: $($_.Exception.Message)"
    }
}

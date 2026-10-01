# Permissions the app registration is created with (or repaired to have), loaded from settings.json.
# The delegated Graph permissions are also the ones the Graph token used by the installer must carry.
$WorkIQSettingsPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Configuration/settings.json"))
$WorkIQAppRegistrationPermissions = (Get-Content -Path $WorkIQSettingsPath -Raw | ConvertFrom-Json).AppRegistrationPermissions
$WorkIQGraphDelegatePermissions = @($WorkIQAppRegistrationPermissions.GraphDelegate)
$WorkIQGraphApplicationPermissions = @($WorkIQAppRegistrationPermissions.GraphApplication)
$WorkIQSharePointDelegatePermissions = @($WorkIQAppRegistrationPermissions.SharePointDelegate)

# Well-known appIds of the Microsoft Graph and SharePoint Online service principals.
$GraphResourceAppId = "00000003-0000-0000-c000-000000000000"
$SharePointResourceAppId = "00000003-0000-0ff1-ce00-000000000000"

function Install-PnPPowerShellModule {
    try {
        if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
            Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
        }
        Import-Module PnP.PowerShell
    }
    catch {
        throw "Failed to install or import the PnP.PowerShell module: $($_.Exception.Message)"
    }
}

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
        # Application.ReadWrite.All lets this script attach its own self-signed certificate to the app
        # registration below, so no manual "create a client secret" step is needed. Teamwork.Migrate.All
        # is the application permission actually used at install time to import backdated Teams chat
        # messages. License assignment (Set-LicenseForUser's call to /users/{id}/assignLicense) is
        # covered by User.ReadWrite.All below - LicenseAssignment.ReadWrite.All is the documented
        # least-privileged permission for that call, but this PnP module version's ValidateSet doesn't
        # recognize it yet, so User.ReadWrite.All (a documented higher-privileged alternative) is used.
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

    # Update-AppRegistrationPermissions signs in before Connect-WorkIQGraph does - reuse that sign-in
    # rather than prompting the user a second time. Only reuse it if the PnP connection is still live -
    # a prior run's Disconnect-PnPOnline (e.g. CleanUp.ps1) leaves the client ID global set but the
    # connection gone, which would otherwise make the next Get-PnPAccessToken call fail.
    # -Force skips that reuse and always signs in again.
    if (-not $Force -and $global:workIQPnPClientId -eq $ClientId -and (Get-PnPConnection -ErrorAction SilentlyContinue)) {
        return
    }

    Disconnect-PnPOnline -ErrorAction SilentlyContinue
    Connect-PnPOnline -Url $SharePointUrl -ClientId $ClientId -Interactive
    $global:workIQPnPClientId = $ClientId
}

function Update-AppRegistrationPermissions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClientId,
        [Parameter(Mandatory = $true)]
        [string]$TenantPrefix
    )

    try {
        # A .default token carries every delegated Graph scope that has been consented on the app, so it
        # shows both whether the app can edit itself and whether consent is still outstanding.
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

        # PATCH replaces the whole requiredResourceAccess array, so start from what is already on the app
        # (including unrelated resources) and only append what's missing.
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
        Read-Host "Press Enter once admin consent has been granted" | Out-Null

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

    # Always rebuild the header from a fresh token rather than reusing a cached one - the header is a
    # frozen string, so a cached one from an earlier run in this session can be an expired token even
    # though PnP's own underlying connection would have refreshed it. Get-PnPAccessToken serves from
    # PnP/MSAL's token cache and refreshes silently, so this doesn't add an extra sign-in prompt.
    Connect-WorkIQPnP -SharePointUrl $SharePointUrl -ClientId $ClientId

    $global:graphBaseUrl = "https://graph.microsoft.com/v1.0"
    $global:headers = @{ Authorization = "Bearer $(Get-WorkIQGraphAccessToken)" }
}

function Get-WorkIQGraphAccessToken {
    # Get-PnPAccessToken requests only AllSites.FullControl unless -Scopes is given, which yields a
    # Graph token without any of the Graph permissions (Graph then answers 403). Ask for .default first:
    # it only covers permissions that are already consented, so it never makes Entra show a consent
    # page. Naming the scopes did, when the request came in before a fresh admin consent had
    # propagated - a second, redundant consent prompt. On a fresh install the consent can take a little
    # while to show up in tokens, so retry until it does. A .default token that came back missing
    # scopes stays cached, so from then on name the scopes to force a new token.
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

    # Connect-PnPOnline with a certificate doesn't sign in until a token is requested, so the retry has
    # to cover the token request too. A certificate just added to the app registration can take a few
    # minutes to be accepted (AADSTS700027), and the Teamwork.Migrate.All consent can take a moment to
    # show up in the token's roles. App-only tokens need the .default scope.
    $maxAttempts = 10
    $reason = $null

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $connection = Connect-PnPOnline -Url "https://$TenantPrefix.sharepoint.com" `
                -ClientId $ClientId -Tenant "$TenantPrefix.onmicrosoft.com" `
                -CertificatePath $CertificatePath -ReturnConnection
            # -ResourceUrl is ambiguous between parameter sets in PnP 3.x, so pass .default via -Scopes.
            $token = Get-PnPAccessToken -ResourceTypeName Graph -Scopes "https://graph.microsoft.com/.default" -Connection $connection

            if ((ConvertFrom-AccessToken -Token $token).roles -contains "Teamwork.Migrate.All") {
                return $token
            }
            $reason = "token is missing Teamwork.Migrate.All"
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

    throw "Could not sign in with the Teams chat migration certificate ($reason). Check that the certificate is listed under Certificates & secrets and that admin consent is granted for Teamwork.Migrate.All on the app registration, then run the installer again."
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

        # keyCredentials is only returned by Graph when explicitly selected, and PATCH replaces the
        # whole array - so the existing entries (with their key data) have to be read back and
        # resubmitted alongside the new one, or they'd be silently dropped.
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
        # Invoke-RestMethod's exception message only carries the HTTP status - Graph's actual
        # error code/message (e.g. Authorization_RequestDenied) is in ErrorDetails.
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

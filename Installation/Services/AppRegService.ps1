# App registration uses browser PKCE sign-in and REST consent from appreg_mini.ps1.
# Runtime SharePoint, Graph token, and certificate helpers retain installer compatibility.
# get the permissions from the settings file.
$WorkIQSettingsPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Configuration/settings.json"))
$WorkIQAppRegistrationPermissions = (Get-Content -Path $WorkIQSettingsPath -Raw | ConvertFrom-Json).AppRegistrationPermissions
$WorkIQGraphDelegatePermissions = @($WorkIQAppRegistrationPermissions.GraphDelegate)
$WorkIQGraphApplicationPermissions = @($WorkIQAppRegistrationPermissions.GraphApplication)

function Get-AppRegBrowserAccessToken {
    param(
        [string]$Tenant, [guid]$AuthenticationClientId,
        [string]$Scope = 'https://graph.microsoft.com/Application.ReadWrite.All https://graph.microsoft.com/AppRoleAssignment.ReadWrite.All https://graph.microsoft.com/DelegatedPermissionGrant.ReadWrite.All',
        [switch]$NoConsent,
        [switch]$ReturnTokenResponse
    )
    $authority = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0"
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = New-Object byte[] 32
        $random.GetBytes($bytes)
        $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $challenge = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $random.GetBytes($bytes)
        $state = [Convert]::ToBase64String($bytes)
    }
    finally { $random.Dispose(); $sha.Dispose() }

    # Reserve an available loopback port, then listen before opening the browser.
    $portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $portProbe.Start(); $port = $portProbe.LocalEndpoint.Port }
    finally { $portProbe.Stop() }
    $redirectUri = "http://localhost:$port/"
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add($redirectUri)
    try {
        $listener.Start()
        $parameters = [ordered]@{
            client_id = $AuthenticationClientId.ToString()
            response_type = 'code'
            redirect_uri = $redirectUri
            response_mode = 'query'
            scope = $scope
            state = $state
            code_challenge = $challenge
            code_challenge_method = 'S256'
            prompt = $(if ($NoConsent) { 'none' } else { 'select_account' })
        }
        $query = ($parameters.GetEnumerator() | ForEach-Object {
            '{0}={1}' -f $_.Key, [Uri]::EscapeDataString([string]$_.Value)
        }) -join '&'
        if ($NoConsent) {
            Write-Host "Retrieving existing API access through your browser session for $Tenant."
        }
        else {
            Write-Host "Signing in to tenant: $Tenant. Complete authorization in your browser."
        }
        # A visible browser is intentional: this is the user's sign-in window.
        Start-Process -FilePath "$authority/authorize?$query" -ErrorAction Stop
        $deadline = [DateTime]::UtcNow.AddMinutes(5)
        $code = $null
        while ([DateTime]::UtcNow -lt $deadline) {
            $pending = $listener.GetContextAsync()
            while (-not $pending.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            if (-not $pending.IsCompleted) { throw 'Browser sign-in timed out. Run the script again.' }
            $context = $pending.GetAwaiter().GetResult()
            $callback = $context.Request.QueryString
            if ($callback['state'] -cne $state) {
                $context.Response.StatusCode = 400
                $context.Response.Close()
                continue
            }
            $message = 'Authorization received. Return to PowerShell to view the result.'
            $data = [Text.Encoding]::UTF8.GetBytes($message)
            $context.Response.ContentType = 'text/plain; charset=utf-8'
            $context.Response.ContentLength64 = $data.Length
            $context.Response.OutputStream.Write($data, 0, $data.Length)
            $context.Response.Close()
            if ($callback['error']) {
                if ($NoConsent) {
                    throw "Cleanup authentication failed without requesting consent: $($callback['error']) - $($callback['error_description']). Sign in to the selected tenant in the same browser first. If permissions or admin consent are missing, configure them separately using the installer."
                }
                throw "Browser authorization failed: $($callback['error_description'])"
            }
            $code = $callback['code']
            if (-not $code) { throw 'The browser callback did not contain an authorization code.' }
            break
        }
        if (-not $code) { throw 'Browser sign-in timed out. Run the script again.' }
        $response = Invoke-RestMethod -Method Post -Uri "$authority/token" -Body @{
            client_id = $AuthenticationClientId.ToString()
            grant_type = 'authorization_code'
            code = $code
            redirect_uri = $redirectUri
            code_verifier = $verifier
            scope = $scope
        }
        if (-not $response.access_token) { throw 'Sign-in did not return an access token.' }
        if ($ReturnTokenResponse) { return $response }
        return $response.access_token
    }
    finally { $listener.Close() }
}

function Invoke-AppRegProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$TenantPrefix,
        [string]$AppName,
        [guid]$ClientId,
        [string]$PermissionsPath = (Join-Path $PSScriptRoot '../../Configuration/appPermissions.json'),
        [string[]]$RequiredResourceIds,
        [guid]$AuthenticationClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    )
    $ErrorActionPreference = 'Stop'
    $TenantPrefix = $TenantPrefix.Trim() -replace '\.onmicrosoft\.com$', ''
    if ($TenantPrefix -notmatch '^[a-zA-Z0-9][a-zA-Z0-9-]*$') { throw 'Enter a valid tenant prefix.' }
    if (-not $ClientId -and [string]::IsNullOrWhiteSpace($AppName)) { throw 'AppName is required when creating an app registration.' }
    $Tenant = "$TenantPrefix.onmicrosoft.com"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $parsedPermissions = Get-Content -LiteralPath $PermissionsPath -Raw | ConvertFrom-Json
    $permissions = @($parsedPermissions)
    if ($PSBoundParameters.ContainsKey('RequiredResourceIds')) {
        foreach ($resourceId in $RequiredResourceIds) {
            if (-not @($permissions | Where-Object ResourceId -eq $resourceId).Count) {
                throw "No permissions are defined for required resource '$resourceId' in $PermissionsPath."
            }
        }
        $permissions = @($permissions | Where-Object ResourceId -in $RequiredResourceIds)
    }
    if ($permissions.Count -eq 0) { throw 'The permissions file is empty.' }
    $seen = @{}
    foreach ($permission in $permissions) {
        if (-not $permission.ResourceName -or -not $permission.PermissionName -or
            $permission.PermissionType -cnotin @('Scope', 'Role')) {
            throw 'Each permission needs resource/name and a Scope or Role type.'
        }
        $null = [guid]::Parse($permission.ResourceId)
        $null = [guid]::Parse($permission.PermissionId)
        $key = "$($permission.ResourceId)/$($permission.PermissionId)"
        if ($seen.ContainsKey($key)) { throw "Duplicate permission: $key" }
        $seen[$key] = $true
    }
    $resources = @(foreach ($group in ($permissions | Group-Object ResourceId)) {
        @{
            resourceAppId = $group.Name
            resourceAccess = @($group.Group | ForEach-Object {
                @{ id = $_.PermissionId; type = $_.PermissionType }
            })
        }
    })
    $body = @{
        displayName = $AppName
        signInAudience = 'AzureADMyOrg'
        isFallbackPublicClient = $true
        publicClient = @{ redirectUris = @('http://localhost') }
        requiredResourceAccess = $resources
    } | ConvertTo-Json -Depth 8

    $AccessToken = Get-AppRegBrowserAccessToken -Tenant $Tenant -AuthenticationClientId $AuthenticationClientId

    $headers = @{ Authorization = "Bearer $AccessToken" }
    function Invoke-Graph {
        param([string]$Path, [string]$Method = 'Get', $Payload)
        $request = @{
            Uri = "https://graph.microsoft.com/v1.0/$Path"
            Method = $Method
            Headers = $headers
            ErrorAction = 'Stop'
        }
        if ($null -ne $Payload) {
            $request.ContentType = 'application/json'
            $request.Body = $Payload | ConvertTo-Json -Depth 8
        }
        # New applications and principals can take time to become available.
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try { return Invoke-RestMethod @request }
            catch {
                $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
                if ($status -ne 404 -or $attempt -eq 6) { throw }
                Start-Sleep -Seconds 5
            }
        }
    }
    function Get-OrCreateServicePrincipal {
        param([string]$AppId)
        $found = Invoke-Graph -Path "servicePrincipals?`$filter=appId eq '$AppId'"
        if (@($found.value).Count) { return $found.value[0] }
        return Invoke-Graph -Path 'servicePrincipals' -Method Post -Payload @{ appId = $AppId }
    }

    Write-Host 'Step 1/2: Check required app registration permissions'
    if ($ClientId) {
        $app = Invoke-Graph -Path "applications(appId='$ClientId')"
        # Preserve existing API permissions and add missing entries from the JSON.
        $merged = [ordered]@{}
        foreach ($entry in @($app.requiredResourceAccess)) {
            $merged[$entry.resourceAppId] = @($entry.resourceAccess | ForEach-Object { @{ id = $_.id; type = $_.type } })
        }
        $addedPermissions = @()
        foreach ($permission in $permissions) {
            if (-not $merged.Contains($permission.ResourceId)) { $merged[$permission.ResourceId] = @() }
            if (-not @($merged[$permission.ResourceId] | Where-Object { $_.id -eq $permission.PermissionId -and $_.type -eq $permission.PermissionType }).Count) {
                $merged[$permission.ResourceId] += @{ id = $permission.PermissionId; type = $permission.PermissionType }
                $addedPermissions += $permission.PermissionName
            }
        }
        $required = @(foreach ($key in $merged.Keys) { @{ resourceAppId = $key; resourceAccess = @($merged[$key]) } })
        if ($addedPermissions.Count) {
            $null = Invoke-Graph -Path "applications/$($app.id)" -Method Patch -Payload @{ requiredResourceAccess = $required }
            Write-Host "Added missing API permissions: $($addedPermissions -join ', ')."
        }
        else { Write-Host 'All required API permissions are already configured. No app registration update is needed.' }
    }
    else {
        $escapedName = [Uri]::EscapeDataString($AppName.Replace("'", "''"))
        $existing = @((Invoke-Graph -Path "applications?`$filter=displayName eq '$escapedName'&`$select=id,appId,displayName").value)
        if ($existing.Count) {
            throw "An app registration named '$AppName' already exists (client ID: $($existing[0].appId)). Choose a different name, or re-run and answer yes to using an existing application registration."
        }
        Write-Host 'Creating the app registration with the required API permissions...'
        $app = Invoke-RestMethod -Method Post -Uri 'https://graph.microsoft.com/v1.0/applications' `
            -Headers $headers -ContentType 'application/json' -Body $body
    }
    Write-Host "App registration: $($app.appId) (object ID: $($app.id))"
    try {
        $principal = Get-OrCreateServicePrincipal -AppId $app.appId
        # Ensure resource principals exist before using the same read-only check as cleanup.
        foreach ($resourceId in ($permissions.ResourceId | Sort-Object -Unique)) {
            $null = Get-OrCreateServicePrincipal -AppId $resourceId
        }
        Write-Host 'Step 2/2: Check existing admin consent and grant only missing consent'
        $permissionStatus = @(Get-AppRegistrationPermissionStatus -ClientId $app.appId -AccessToken $AccessToken -PermissionsPath $PermissionsPath -RequiredResourceIds @($permissions.ResourceId | Sort-Object -Unique))
        $missingConsent = @($permissionStatus | Where-Object { -not $_.Consented })
        if (-not $missingConsent.Count) { Write-Host 'Admin consent is already granted for all required permissions. No consent changes are needed.' }
        foreach ($group in ($permissions | Group-Object ResourceId)) {
            $groupMissing = @($missingConsent | Where-Object ResourceId -eq $group.Name)
            if (-not $groupMissing.Count) { continue }
            $resource = Get-OrCreateServicePrincipal -AppId $group.Name
            $delegated = @($group.Group | Where-Object { $_.PermissionType -eq 'Scope' -and $_.PermissionId -in $groupMissing.PermissionId })
            if ($delegated.Count) {
                $grants = Invoke-Graph -Path "oauth2PermissionGrants?`$filter=clientId eq '$($principal.id)' and resourceId eq '$($resource.id)'"
                $grant = @($grants.value | Where-Object consentType -eq 'AllPrincipals')
                $scopes = @($delegated.PermissionName)
                if ($grant.Count) {
                    $scopes += $grant[0].scope -split ' '
                    $null = Invoke-Graph -Path "oauth2PermissionGrants/$($grant[0].id)" -Method Patch -Payload @{
                        scope = (($scopes | Sort-Object -Unique) -join ' ')
                    }
                }
                else {
                    $null = Invoke-Graph -Path 'oauth2PermissionGrants' -Method Post -Payload @{
                        clientId = $principal.id
                        resourceId = $resource.id
                        consentType = 'AllPrincipals'
                        scope = ($scopes -join ' ')
                    }
                }
            }
            $roles = @($group.Group | Where-Object { $_.PermissionType -eq 'Role' -and $_.PermissionId -in $groupMissing.PermissionId })
            if ($roles.Count) {
                $assignments = Invoke-Graph -Path "servicePrincipals/$($principal.id)/appRoleAssignments"
                foreach ($role in $roles) {
                    $existing = @($assignments.value | Where-Object {
                        $_.resourceId -eq $resource.id -and $_.appRoleId -eq $role.PermissionId
                    })
                    if (-not $existing.Count) {
                        $null = Invoke-Graph -Path "servicePrincipals/$($principal.id)/appRoleAssignments" -Method Post -Payload @{
                            principalId = $principal.id
                            resourceId = $resource.id
                            appRoleId = $role.PermissionId
                        }
                    }
                }
            }
            Write-Host "Granted missing admin consent: $($groupMissing.PermissionName -join ', ')."
        }
    }
    catch {
        throw "App $($app.appId) exists, but consent is incomplete. Resume with Update-AppRegistrationPermissions -TenantPrefix $TenantPrefix -ClientId $($app.appId) after resolving the error. $($_.Exception.Message)"
    }
    Write-Host 'Required API permissions and admin consent are ready.'

    [pscustomobject]@{
        ClientId = $app.appId
        ObjectId = $app.id
        Tenant = $Tenant
        TenantPrefix = $TenantPrefix
        SharePointUrl = "https://$TenantPrefix.sharepoint.com"
        AppName = $app.displayName
        AdminConsentGranted = $true
    }
}

function Get-AppRegistrationPermissionStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$ClientId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$PermissionsPath = (Join-Path $PSScriptRoot '../../Configuration/appPermissions.json'),
        [string[]]$RequiredResourceIds
    )
    $ErrorActionPreference = 'Stop'
    $permissions = Get-Content -LiteralPath $PermissionsPath -Raw | ConvertFrom-Json
    if (-not @($permissions).Count) { throw 'The permissions file is empty.' }
    if ($PSBoundParameters.ContainsKey('RequiredResourceIds')) {
        foreach ($resourceId in $RequiredResourceIds) {
            if (-not @($permissions | Where-Object ResourceId -eq $resourceId).Count) {
                throw "No permissions are defined for required resource '$resourceId' in $PermissionsPath."
            }
        }
        $permissions = @($permissions | Where-Object ResourceId -in $RequiredResourceIds)
        if (-not $permissions.Count) { throw 'No required permissions were selected for validation.' }
    }
    $readHeaders = @{ Authorization = "Bearer $AccessToken" }
    function Get-AppRegReadOnly {
        param([string]$Path)
        Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/v1.0/$Path" -Headers $readHeaders -ErrorAction Stop
    }
    function Get-AppRegReadOnlyCollection {
        param([string]$Path)
        do {
            $page = Get-AppRegReadOnly -Path $Path
            $page.value
            $next = $page.PSObject.Properties['@odata.nextLink']
            $Path = if ($next -and $next.Value) {
                if (-not $next.Value.StartsWith('https://graph.microsoft.com/v1.0/')) { throw 'Unexpected Graph pagination URL.' }
                $next.Value.Substring('https://graph.microsoft.com/v1.0/'.Length)
            } else { $null }
        } while ($Path)
    }
    Write-Host 'Checking app registration permissions and existing admin consent (read-only).'
    Write-Host "Required APIs: $(($permissions.ResourceName | Sort-Object -Unique) -join ', ')."
    $app = Get-AppRegReadOnly -Path "applications(appId='$ClientId')?`$select=requiredResourceAccess"
    $principal = Get-AppRegReadOnly -Path "servicePrincipals(appId='$ClientId')?`$select=id"
    $grants = @(Get-AppRegReadOnlyCollection -Path "servicePrincipals/$($principal.id)/oauth2PermissionGrants")
    $roles = @(Get-AppRegReadOnlyCollection -Path "servicePrincipals/$($principal.id)/appRoleAssignments")
    $results = @()
    foreach ($group in ($permissions | Group-Object ResourceId)) {
        $resource = Get-AppRegReadOnly -Path "servicePrincipals(appId='$($group.Name)')?`$select=id"
        foreach ($permission in $group.Group) {
            if ($permission.PermissionType -cnotin @('Scope', 'Role')) { throw "Invalid permission type for $($permission.PermissionName)." }
            $label = "$($permission.ResourceName): $($permission.PermissionName) ($($permission.PermissionType))"
            $configured = @($app.requiredResourceAccess | Where-Object resourceAppId -eq $permission.ResourceId | ForEach-Object { $_.resourceAccess } | Where-Object {
                $_.id -eq $permission.PermissionId -and $_.type -eq $permission.PermissionType
            })

            if ($permission.PermissionType -eq 'Scope') {
                $consented = @($grants | Where-Object {
                    $_.resourceId -eq $resource.id -and $_.consentType -eq 'AllPrincipals' -and
                    $permission.PermissionName -in ($_.scope -split ' ')
                })
            }
            else {
                $consented = @($roles | Where-Object {
                    $_.resourceId -eq $resource.id -and $_.appRoleId -eq $permission.PermissionId
                })
            }
            $results += [pscustomobject]@{
                ResourceId = $permission.ResourceId
                PermissionId = $permission.PermissionId
                PermissionName = $permission.PermissionName
                PermissionType = $permission.PermissionType
                Label = $label
                Configured = $configured.Count -gt 0
                Consented = $consented.Count -gt 0
            }
        }
    }
    return $results
}

function Assert-AppRegistrationPermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$ClientId,
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [string]$PermissionsPath = (Join-Path $PSScriptRoot '../../Configuration/appPermissions.json'),
        [string[]]$RequiredResourceIds
    )
    $status = @(Get-AppRegistrationPermissionStatus @PSBoundParameters)
    $missing = @(foreach ($permission in $status) {
        if (-not $permission.Configured) { "Missing API permission: $($permission.Label)" }
        if (-not $permission.Consented) { "Missing admin consent: $($permission.Label)" }
    })
    if ($missing.Count) {
        throw "Cleanup stopped. App registration $ClientId does not meet the requirements:`n$($missing -join "`n")`nConfigure permissions and grant consent separately before running cleanup."
    }
    Write-Host 'All required API permissions and admin consent are already present.'
}

function New-AppRegistration {
    param(
        [Parameter(Mandatory = $true)][string]$Tenant,
        [Parameter(Mandatory = $true)][string]$AppName,
        [string[]]$RequiredResourceIds,
        [guid]$AuthenticationClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    )
    $options = @{}
    if ($PSBoundParameters.ContainsKey('RequiredResourceIds')) { $options.RequiredResourceIds = $RequiredResourceIds }
    Invoke-AppRegProvisioning -TenantPrefix $Tenant -AppName $AppName -AuthenticationClientId $AuthenticationClientId @options
}

function Update-AppRegistrationPermissions {
    param(
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$TenantPrefix,
        [string[]]$RequiredResourceIds,
        [guid]$AuthenticationClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
    )
    $options = @{}
    if ($PSBoundParameters.ContainsKey('RequiredResourceIds')) { $options.RequiredResourceIds = $RequiredResourceIds }
    $null = Invoke-AppRegProvisioning -TenantPrefix $TenantPrefix -ClientId $ClientId -AuthenticationClientId $AuthenticationClientId @options
    return $true
}

function Add-DynamicsAppRegistrationPermissions {
    param([string]$ClientId, [string]$TenantPrefix)
    Update-AppRegistrationPermissions -ClientId $ClientId -TenantPrefix $TenantPrefix
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
        $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        $config.Settings.ClientId = $ClientId
        $config.Settings.TenantPrefix = $TenantPrefix
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ConfigPath
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

    # Get-PnPConnection throws a terminating error when there is no connection, which -ErrorAction does not suppress.
    $existingConnection = $null
    if (-not $Force -and $global:workIQPnPClientId -eq $ClientId) {
        try { $existingConnection = Get-PnPConnection } catch { }
    }
    if ($existingConnection) {
        return
    }

    Connect-PnPOnline -Url $SharePointUrl -ClientId $ClientId -Interactive
    $global:workIQPnPClientId = $ClientId
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
        [string]$CertificateDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Installation/.certs'))
    )

    $step = "prepare the certificate files"

    try {
        $certDir = $CertificateDirectory
        $pfxPath = Join-Path -Path $certDir -ChildPath "teams-chat-migration.pfx"
        $cerPath = Join-Path -Path $certDir -ChildPath "teams-chat-migration.cer"

        if ((Test-Path -LiteralPath $pfxPath) -and (Test-Path -LiteralPath $cerPath)) {
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
    param([string]$CertificateDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Installation/.certs')))

    try {
        $certDir = $CertificateDirectory

        if (Test-Path -LiteralPath $certDir) {
            Remove-Item -LiteralPath $certDir -Recurse -Force
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

function Show-DynamicsEnvironmentSecurityGroup {
    param([Parameter(Mandatory = $true)]$Config)
    $environmentUrl = ([string]$Config.Settings.DynamicsEnvironmentUrl).TrimEnd('/')
    Write-InstallLogAction -Message "Retrieving the security group associated with Dynamics environment '$environmentUrl'..."
    try {
        $token = Get-PnPAccessToken -Scopes 'https://api.powerplatform.com/.default' -ErrorAction Stop
        $requestHeaders = @{Authorization="Bearer $token";Accept='application/json'}
        $url = 'https://api.powerplatform.com/environmentmanagement/environments?api-version=2024-10-01'
        $environments = @()
        do {
            $uri = [Uri]::new([Uri]'https://api.powerplatform.com/', $url)
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.powerplatform.com') { throw 'Invalid environment pagination URL.' }
            $response = Invoke-RestMethod -Uri $uri.AbsoluteUri -Headers $requestHeaders -Method Get -ErrorAction Stop
            $environments += @($response.value | Where-Object { $_.url -and ([string]$_.url).TrimEnd('/') -eq $environmentUrl })
            $url = $response.'@odata.nextLink'
        } while ($url)
        if ($environments.Count -ne 1) { throw "Expected one accessible Power Platform environment matching '$environmentUrl'; found $($environments.Count)." }
        $environment = $environments[0]
        $groupId = [string]$environment.securityGroupId
        if ([string]::IsNullOrWhiteSpace($groupId) -or $groupId -eq [Guid]::Empty.ToString()) {
            Write-InstallLogAction -Message "Dynamics environment '$($environment.displayName)' ($($environment.id)) has no associated security group."
            return [PSCustomObject]@{EnvironmentId=$environment.id;SecurityGroupId=$null}
        }
        $groupId = [Guid]::Parse($groupId).ToString()
        $graphToken = Get-PnPAccessToken -Scopes 'https://graph.microsoft.com/.default' -ErrorAction Stop
        $group = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$($groupId)?`$select=id,displayName" -Headers @{Authorization="Bearer $graphToken"} -Method Get -ErrorAction Stop
        Write-InstallLogAction -Message "Dynamics environment: $($environment.displayName) ($($environment.id)). Associated security group: $($group.displayName) ($groupId)." -Level Success
        return [PSCustomObject]@{EnvironmentId=$environment.id;SecurityGroupId=$groupId}
    }
    catch { throw "Failed to retrieve the Dynamics environment security group: $($_.Exception.Message) $($_.ErrorDetails.Message)" }
}

function Initialize-PowerPlatformUsers {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)]$Environment)
    $graphToken = Get-PnPAccessToken -Scopes 'https://graph.microsoft.com/.default' -ErrorAction Stop
    $graphHeaders = @{Authorization="Bearer $graphToken"}
    $baseUrl = ([string]$Config.Settings.DynamicsEnvironmentUrl).TrimEnd('/') + '/api/data/v9.2'
    $groupId = $null
    if ($Environment.SecurityGroupId) { $groupId = [Guid]::Parse($Environment.SecurityGroupId).ToString() }
    else { Write-InstallLogAction -Message 'No environment security group is assigned; skipping group membership checks.' }
    foreach ($upn in @($Settings.Users.Email | Select-Object -Unique)) {
        if ([string]::IsNullOrWhiteSpace($upn)) { throw 'A provisioning user has no email/UPN.' }
        try {
            $encodedUpn = [Uri]::EscapeDataString($upn)
            $user = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($encodedUpn)?`$select=id,userPrincipalName" -Headers $graphHeaders -Method Get -ErrorAction Stop
            $userId = [Guid]::Parse($user.id).ToString()
            if ($groupId) {
                $memberUrl = "https://graph.microsoft.com/v1.0/groups/$groupId/members/$userId"
                $isMember = $false
                try {
                    Invoke-RestMethod -Uri $memberUrl -Headers $graphHeaders -Method Get -ErrorAction Stop | Out-Null
                    $isMember = $true
                } catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw } }
                if (-not $isMember) {
                    $body = @{'@odata.id'="https://graph.microsoft.com/v1.0/directoryObjects/$userId"} | ConvertTo-Json
                    Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$ref" -Headers $graphHeaders -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
                    # Directory membership may not be immediately visible after the write.
                    for ($membershipAttempt=1; $membershipAttempt -le 16; $membershipAttempt++) {
                        try {
                            Invoke-RestMethod -Uri $memberUrl -Headers $graphHeaders -Method Get -ErrorAction Stop | Out-Null
                            $isMember = $true
                            break
                        } catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw } }
                        if ($membershipAttempt -lt 16) {
                            Write-InstallLogAction -Message "Membership for '$upn' is not visible yet. Checking again in one minute ($membershipAttempt of 15 waits)..."
                            Start-Sleep -Seconds 60
                        }
                    }
                    if (-not $isMember) { throw 'Security group membership was not visible after 15 minutes; synchronization has not started.' }
                    Write-InstallLogAction -Message "Verified '$upn' was added to environment security group '$groupId'." -Level Success
                }
                else { Write-InstallLogAction -Message "User '$upn' already belongs to environment security group '$groupId'." }
            }
            $filter = [Uri]::EscapeDataString("azureactivedirectoryobjectid eq $userId")
            $systemUserUrl = "$baseUrl/systemusers?`$select=systemuserid,isdisabled&`$filter=$filter"
            $token = Get-PnPAccessToken -Scopes "$($Config.Settings.DynamicsEnvironmentUrl.TrimEnd('/'))/user_impersonation" -ErrorAction Stop
            $dvHeaders = @{Authorization="Bearer $token";Accept='application/json'}
            $response = Invoke-RestMethod -Uri $systemUserUrl -Headers $dvHeaders -Method Get -ErrorAction Stop
            if (-not @($response.value).Count) {
                Sync-PowerPlatformUser -UserObjectId $userId -EnvironmentId $Environment.EnvironmentId | Out-Null
                for ($attempt=1; $attempt -le 16; $attempt++) {
                    $response = Invoke-RestMethod -Uri $systemUserUrl -Headers $dvHeaders -Method Get -ErrorAction Stop
                    if (@($response.value).Count) { break }
                    if ($attempt -lt 16) {
                        Write-InstallLogAction -Message "Waiting for '$upn' to appear in Dataverse. Checking again in one minute ($attempt of 15 waits)..."
                        Start-Sleep -Seconds 60
                    }
                }
                if (-not @($response.value).Count) { throw 'User is still absent from Dataverse after synchronization and verification retries.' }
            }
            if (@($response.value).Count -ne 1) { throw 'Expected exactly one Dataverse systemuser for the Entra object ID.' }
            Write-InstallLogAction -Message "Verified Dataverse systemuser for '$upn': $($response.value[0].systemuserid)." -Level Success
            if ($response.value[0].isdisabled) { Write-InstallLogAction -Message "Dataverse user '$upn' is disabled; review environment access and licensing." -Level Warning }
        }
        catch { throw "Failed to prepare environment access for '$upn': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
    }
}

function Set-PowerPlatformUserSecurityRoles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config, [Parameter(Mandatory = $true)]$Settings)
    $environmentUrl = ([string]$Config.Settings.DynamicsEnvironmentUrl).TrimEnd('/')
    $baseUrl = "$environmentUrl/api/data/v9.2"
    $token = Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop
    $requestHeaders = @{Authorization="Bearer $token";Accept='application/json';'OData-Version'='4.0';'OData-MaxVersion'='4.0'}
    $graphToken = Get-PnPAccessToken -Scopes 'https://graph.microsoft.com/.default' -ErrorAction Stop
    foreach ($upn in @($Settings.Users.Email | Select-Object -Unique)) {
        try {
            $encodedUpn = [Uri]::EscapeDataString($upn)
            $entraUser = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$($encodedUpn)?`$select=id" -Headers @{Authorization="Bearer $graphToken"} -Method Get -ErrorAction Stop
            $entraId = [Guid]::Parse($entraUser.id).ToString()
            $filter = [Uri]::EscapeDataString("azureactivedirectoryobjectid eq $entraId")
            $users = Invoke-RestMethod -Uri "$baseUrl/systemusers?`$select=systemuserid,_businessunitid_value&`$filter=$filter" -Headers $requestHeaders -Method Get -ErrorAction Stop
            if (@($users.value).Count -ne 1) { throw 'Expected one Dataverse systemuser for the Entra user.' }
            $userId = [Guid]::Parse($users.value[0].systemuserid).ToString()
            $businessUnitId = [Guid]::Parse($users.value[0]._businessunitid_value).ToString()
            foreach ($roleName in @('Sales Manager','Customer Service Representative','Field Engagement Security Role')) {
                # Resolve the role copy belonging to the user's business unit.
                $filter = [Uri]::EscapeDataString("name eq '$($roleName.Replace("'","''"))' and _businessunitid_value eq $businessUnitId")
                $roles = Invoke-RestMethod -Uri "$baseUrl/roles?`$select=roleid,name&`$filter=$filter" -Headers $requestHeaders -Method Get -ErrorAction Stop
                if (@($roles.value).Count -ne 1) { throw "Expected exactly one '$roleName' security role in business unit '$businessUnitId'; found $(@($roles.value).Count)." }
                $roleId = [Guid]::Parse($roles.value[0].roleid).ToString()
                $assignedFilter = [Uri]::EscapeDataString("roleid eq $roleId")
                $associationUrl = "$baseUrl/systemusers($userId)/systemuserroles_association"
                $checkUrl = "$($associationUrl)?`$select=roleid&`$filter=$assignedFilter"
                $assigned = Invoke-RestMethod -Uri $checkUrl -Headers $requestHeaders -Method Get -ErrorAction Stop
                if (@($assigned.value).Count) {
                    Write-InstallLogAction -Message "User '$upn' already has security role '$roleName'."
                    continue
                }
                $body = @{'@odata.id'="$baseUrl/roles($roleId)"} | ConvertTo-Json
                Invoke-RestMethod -Uri "$associationUrl/`$ref" -Headers $requestHeaders -Method Post -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
                $assigned = Invoke-RestMethod -Uri $checkUrl -Headers $requestHeaders -Method Get -ErrorAction Stop
                if (-not @($assigned.value).Count) { throw "Security role '$roleName' was not present after assignment." }
                Write-InstallLogAction -Message "Assigned and verified security role '$roleName' for '$upn'." -Level Success
            }
        } catch { throw "Failed to assign Dataverse security roles for '$upn': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
    }
}

function Test-GlobalAdminPreRequisite {
    $retVal = $false
    try {
        $globalAdminRoleTemplateId = "62e90394-69f5-4237-9190-012177145e10"
        $memberOfRoles = (Invoke-RestMethod -Uri "$graphBaseUrl/me/memberOf/microsoft.graph.directoryRole" -Headers $headers -Method Get).value

        if ($memberOfRoles | Where-Object { $_.roleTemplateId -eq $globalAdminRoleTemplateId }) {
            Write-InstallLogAction -Message "Current user is a Global Administrator."
            $retVal = $true
        }
        else {
            Write-Host "Current user is not a Global Administrator. This solution requires the installing user to be a Global Administrator on the tenant." -ForegroundColor Red
        }
    }
    catch {
        $message = "Failed to check Global Administrator role: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-Host $message -ForegroundColor Red
        exit 1
    }
    return $retVal
}

function Sync-PowerPlatformUser {
    <#
    .SYNOPSIS
    Requests synchronization of an existing Entra user into Dataverse.
    .PARAMETER UserObjectId
    Microsoft Entra object ID, not the Dataverse systemuser ID.
    .PARAMETER EnvironmentId
    Power Platform environment ID, not the organization ID or URL.
    .EXAMPLE
    Sync-PowerPlatformUser -UserObjectId '24a5b286-2abe-46b4-9ba5-9de73169ab9c' -EnvironmentId '5e96694f-e031-e8fa-8164-e9ba17d6175b'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid]$UserObjectId,
        [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$EnvironmentId
    )
    if ($UserObjectId -eq [guid]::Empty) { throw 'UserObjectId must not be an empty GUID.' }
    $EnvironmentId = $EnvironmentId.Trim()
    if ($EnvironmentId -notmatch '^(?i:Default-)?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw 'EnvironmentId must be a Power Platform environment GUID or Default-<tenant GUID>.'
    }
    $moduleName = 'Microsoft.PowerApps.Administration.PowerShell'
    Write-InstallLogAction -Message "Checking for module $moduleName..."
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-InstallLogAction -Message 'Installing Power Platform administration module from PSGallery for the current user. Downloading dependencies may take a few minutes...'
        Write-Progress -Activity 'Installing Power Platform administration module' -Status 'Downloading and installing from PSGallery'
        try {
            if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) { throw 'Install-Module is unavailable. Install PowerShellGet and try again.' }
            Install-Module -Name $moduleName -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            if (-not (Get-Module -ListAvailable -Name $moduleName)) { throw 'Installation finished, but the module could not be found.' }
            Write-InstallLogAction -Message 'Power Platform administration module installed.' -Level Success
        }
        catch { throw "Unable to install $moduleName. User synchronization has not started: $($_.Exception.Message)" }
        finally { Write-Progress -Activity 'Installing Power Platform administration module' -Completed }
    }
    else { Write-InstallLogAction -Message 'Power Platform administration module is already installed.' }
    Write-InstallLogAction -Message "Loading module $moduleName..."
    Import-Module $moduleName -ErrorAction Stop
    Write-InstallLogAction -Message "Sign in as an administrator for environment '$EnvironmentId'..."
    Add-PowerAppsAccount -Endpoint prod -ErrorAction Stop | Out-Null
    Write-InstallLogAction -Message "Requesting synchronization of Entra user '$UserObjectId' into environment '$EnvironmentId'..."
    for ($syncAttempt=1; $syncAttempt -le 16; $syncAttempt++) {
        $result = $null
        try {
            $result = Add-AdminPowerAppsSyncUser -EnvironmentName $EnvironmentId -PrincipalObjectId $UserObjectId.ToString() -ErrorAction Stop
    # Some module versions return HTTP error objects without throwing.
    foreach ($item in @($result)) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['Code']) {
            $httpCode = 0
            if ([int]::TryParse([string]$item.Code, [ref]$httpCode) -and $httpCode -ge 400) {
                # Never serialize the whole response: it can contain Authorization headers.
                throw "User synchronization failed (HTTP $httpCode): $($item.Error.code) $($item.Error.message)"
            }
        }
    }
            break
        }
        catch {
            $details = "$($_.Exception.Message) $($_.ErrorDetails.Message)"
            if ($details -notmatch 'userNotPartOfSecurityGroup' -or $syncAttempt -eq 16) { throw }
            Write-InstallLogAction -Message "Dataverse has not recognized security group membership for '$UserObjectId' yet. Retrying synchronization in one minute ($syncAttempt of 15 waits)..."
            Start-Sleep -Seconds 60
        }
    }
    Write-InstallLogAction -Message "User synchronization request completed for '$UserObjectId'. Check the environment's Dataverse users list." -Level Success
    if ($null -ne $result) { Write-Output $result }
}

function Test-PowerPlatformEnvironmentPermissions {
    param(
        [Parameter(Mandatory = $false)]
        $Settings
    )
    # TODO: Stubbed until Power Platform auth/module scaffolding is added to this installer.
    return $true
}

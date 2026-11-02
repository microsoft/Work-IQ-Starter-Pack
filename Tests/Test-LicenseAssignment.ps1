# Offline regression tests. Run with: pwsh -NoProfile -File Tests/Test-LicenseAssignment.ps1
$ErrorActionPreference = 'Stop'
$graphBaseUrl = 'https://graph.invalid/v1.0'
$headers = @{}
$script:results = @()

function Assert-Equal($Actual, $Expected, $Message) {
    if ($Actual -ne $Expected) { throw "$Message (expected: $Expected; actual: $Actual)" }
}

function Assert-AssignedSkus([string[]]$Expected) {
    $actual = @($script:requests | ForEach-Object { $_.addLicenses } | ForEach-Object { $_.skuId } | Sort-Object)
    Assert-Equal ($actual -join ',') (($Expected | Sort-Object) -join ',') 'Unexpected license payload'
}

function Assert-Throws([scriptblock]$Action) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Assert-Equal $thrown $true 'Expected the missing license requirement to fail'
}

function Reset-Scenario {
    $script:settings = Get-Content (Join-Path $PSScriptRoot '../Configuration/settings.json') -Raw | ConvertFrom-Json
    $script:settings.Users = @()
    $script:settings.Licenses.Office = @('MICROSOFT_365_E7')
    $script:settings.Licenses.Copilot = @('MICROSOFT_365_E7')
    $script:settings.Licenses.Teams = @('TEAMS_ENTERPRISE')
    $script:settings.Licenses.Dynamics = @('DYN365_ENTERPRISE_SALES')
    $script:config = @{ Settings = @{ InstallDemoUsers = $true; InstallDynamicsContent = $false; TenantPrefix = 'demo' } }
    $script:fakeSkus = @()
    $script:fakeUsers = @{}
    $script:requests = @()
    $script:logs = @()
    $script:staleReads = 0
    $script:hideAssignments = $false
    $script:assignmentPosted = $false
    $script:sleeps = 0
}

function Add-TestSku($Name, $Id, $Enabled = 5, $Consumed = 0, $Status = 'Enabled') {
    $script:fakeSkus += [PSCustomObject]@{
        skuPartNumber = $Name; skuId = $Id; capabilityStatus = $Status
        prepaidUnits = [PSCustomObject]@{ enabled = $Enabled }; consumedUnits = $Consumed
    }
}

function Add-TestUser($Id, [string[]]$SkuIds = @()) {
    $user = [PSCustomObject]@{
        id = $Id; userPrincipalName = "$Id@demo.invalid"; usageLocation = 'IT'
        assignedLicenses = @($SkuIds | ForEach-Object { [PSCustomObject]@{ skuId = $_; disabledPlans = @() } })
    }
    $script:fakeUsers[$Id] = $user
    $script:settings.Users += [PSCustomObject]@{ Email = $user.userPrincipalName; UsageLocation = 'IT' }
}

function Write-InstallLogAction { param($Message, $Level); $script:logs += $Message }
function Start-Sleep { param($Seconds); $script:sleeps++ }

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $ContentType, $Body)
    if ($Uri -eq "$graphBaseUrl/subscribedSkus" -and $Method -eq 'Get') {
        return @{ value = @($script:fakeSkus) }
    }
    if ($Uri.StartsWith("$graphBaseUrl/users?") -and $Method -eq 'Get') {
        if ($Uri -notmatch "userPrincipalName eq '([^']+)'") { throw "Unexpected user query: $Uri" }
        $upn = $Matches[1]
        return @{ value = @($script:fakeUsers.Values | Where-Object { $_.userPrincipalName -eq $upn }) }
    }
    if ($Uri -match ('^' + [regex]::Escape($graphBaseUrl) + '/users/([^/?]+)(.*)$')) {
        $userId = $Matches[1]
        $suffix = $Matches[2]
        $user = $script:fakeUsers[$userId]
        if (-not $user) { throw "Unknown test user: $userId" }
        if ($Method -eq 'Get' -and $suffix.StartsWith('?')) {
            if ($script:assignmentPosted -and ($script:hideAssignments -or $script:staleReads -gt 0)) {
                if ($script:staleReads -gt 0) { $script:staleReads-- }
                return @{ assignedLicenses = @() }
            }
            return $user
        }
        if ($Method -eq 'Post' -and $suffix -eq '/assignLicense') {
            $payload = $Body | ConvertFrom-Json
            $script:requests += $payload
            $ids = @($payload.addLicenses | ForEach-Object { $_.skuId })
            if ($ids.Count -ne @($ids | Select-Object -Unique).Count) { throw 'Duplicate SKU IDs in addLicenses' }
            foreach ($id in $ids) {
                if ($user.assignedLicenses.skuId -contains $id) { throw "Already assigned SKU was submitted: $id" }
                $sku = $script:fakeSkus | Where-Object { $_.skuId -eq $id } | Select-Object -First 1
                if (-not $sku -or $sku.capabilityStatus -ne 'Enabled' -or $sku.consumedUnits -ge $sku.prepaidUnits.enabled) {
                    throw "SKU unavailable: $id"
                }
                $sku.consumedUnits++
                $user.assignedLicenses += [PSCustomObject]@{ skuId = $id; disabledPlans = @() }
            }
            $script:assignmentPosted = $true
            return @{}
        }
    }
    throw "Unexpected offline Graph request: $Method $Uri"
}

Reset-Scenario
. (Join-Path $PSScriptRoot '../Installation/Services/LicensingService.ps1')
. (Join-Path $PSScriptRoot '../Installation/Services/UserService.ps1')

function Test-Scenario($Name, [scriptblock]$Action) {
    Reset-Scenario
    try {
        & $Action
        $script:results += [PSCustomObject]@{ Name = $Name; Passed = $true }
        Write-Host "PASS $Name"
    }
    catch {
        $script:results += [PSCustomObject]@{ Name = $Name; Passed = $false }
        Write-Host "FAIL $Name`: $($_.Exception.Message)"
    }
}

Test-Scenario 'E7 in both configured categories is assigned once' {
    $script:settings.Licenses = (Get-Content (Join-Path $PSScriptRoot '../Configuration/settings.json') -Raw | ConvertFrom-Json).Licenses
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1
    Add-TestUser 'new-user'
    Set-LicenseForUser -UserId 'new-user'
    Assert-Equal $script:requests.Count 1 'Expected one assignment request'
    Assert-AssignedSkus @('e7')
}

Test-Scenario 'Pending E7 covers Copilot before a standalone SKU is selected' {
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot', 'MICROSOFT_365_E7')
    Add-TestSku 'MICROSOFT_365_E7' 'e7'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    Set-LicenseForUser -UserId 'new-user'
    Assert-AssignedSkus @('e7')
}

Test-Scenario 'Existing E7 at the end of the priority list needs no free seats or POST' {
    $script:settings.Licenses.Office = @('SPE_E5', 'MICROSOFT_365_E7')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1 1
    Add-TestUser 'existing-user' @('e7')
    Set-LicenseForUser -UserId 'existing-user'
    Assert-Equal $script:requests.Count 0 'Already licensed user must not trigger a POST'
}

Test-Scenario 'Existing E3 and Copilot satisfy requirements before earlier E5 is selected' {
    $script:settings.Licenses.Office = @('SPE_E5', 'SPE_E3')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'SPE_E3' 'e3' 1 1
    Add-TestSku 'Microsoft_365_Copilot' 'copilot' 1 1
    Add-TestUser 'existing-user' @('e3', 'copilot')
    Set-LicenseForUser -UserId 'existing-user'
    Assert-Equal $script:requests.Count 0 'Existing Office and Copilot must be preserved'
}

Test-Scenario 'Existing Office receives only its missing Copilot license' {
    $script:settings.Licenses.Office = @('SPE_E5', 'SPE_E3')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'SPE_E3' 'e3' 1 1
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'existing-user' @('e3')
    Set-LicenseForUser -UserId 'existing-user'
    Assert-AssignedSkus @('copilot')
}

Test-Scenario 'Separate Office and Copilot are assigned when both are missing' {
    $script:settings.Licenses.Office = @('SPE_E5')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    Set-LicenseForUser -UserId 'new-user'
    Assert-AssignedSkus @('e5', 'copilot')
}

Test-Scenario 'Existing Copilot receives only its missing Office license' {
    $script:settings.Licenses.Office = @('SPE_E5')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot' 1 1
    Add-TestUser 'existing-user' @('copilot')
    Set-LicenseForUser -UserId 'existing-user'
    Assert-AssignedSkus @('e5')
}

Test-Scenario 'Preflight rejects one E7 seat shared by two different users' {
    $script:settings.Licenses.Office = @('SPE_E3', 'MICROSOFT_365_E7')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot', 'MICROSOFT_365_E7')
    Add-TestSku 'SPE_E3' 'e3' 1 1
    Add-TestSku 'Microsoft_365_Copilot' 'copilot' 1 1
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1
    Add-TestUser 'office-user' @('e3')
    Add-TestUser 'copilot-user' @('copilot')
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $false 'One E7 seat cannot serve two users'
    Assert-Equal $script:requests.Count 0 'Preflight must be read-only'
}

Test-Scenario 'Preflight and assignment agree on two E7 seats for two users' {
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 2
    Add-TestUser 'first-user'
    Add-TestUser 'second-user'
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $true 'Two E7 seats cover both users'
    Assert-Equal $script:requests.Count 0 'Preflight must be read-only'
    Set-LicenseForUser -UserId 'first-user'
    Set-LicenseForUser -UserId 'second-user'
    Assert-AssignedSkus @('e7', 'e7')
    Assert-Equal $script:fakeSkus[0].consumedUnits 2 'Each user consumes one E7 seat'
}

Test-Scenario 'Preflight recognizes users not yet provisioned' {
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1
    $script:settings.Users = @([PSCustomObject]@{ Email = 'future@<TENANTPREFIX>.invalid' })
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $true 'One seat covers Office and Copilot for a future user'
    Assert-Equal $script:requests.Count 0 'Preflight must not provision the user'
}

Test-Scenario 'Real existing users with E7 are not assigned another Office license' {
    $script:config.Settings.InstallDemoUsers = $false
    $script:settings.Licenses.Office = @('SPE_E5', 'MICROSOFT_365_E7')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1 1
    Add-TestUser 'real-user' @('e7')
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $true 'Existing E7 does not require a free seat'
    Add-Users -Settings $settings
    Assert-Equal $script:requests.Count 0 'Real user with E7 must not receive duplicate or extra licenses'
}

Test-Scenario 'Office without Teams receives Teams and Copilot' {
    $script:settings.Licenses.Office = @('Microsoft_365_E5_(no_Teams)')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'Microsoft_365_E5_(no_Teams)' 'office-no-teams'
    Add-TestSku 'TEAMS_ENTERPRISE' 'teams'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $true 'Separate Teams seat is available'
    Set-LicenseForUser -UserId 'new-user'
    Assert-AssignedSkus @('office-no-teams', 'teams', 'copilot')
}

Test-Scenario 'Existing separate Teams license is preserved' {
    $script:settings.Licenses.Office = @('Microsoft_365_E5_(no_Teams)')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'Microsoft_365_E5_(no_Teams)' 'office-no-teams' 1 1
    Add-TestSku 'TEAMS_ENTERPRISE' 'teams' 1 1
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'existing-user' @('office-no-teams', 'teams')
    Set-LicenseForUser -UserId 'existing-user'
    Assert-AssignedSkus @('copilot')
}

Test-Scenario 'Missing Teams fails before any partial assignment' {
    $script:settings.Licenses.Office = @('Microsoft_365_E5_(no_Teams)')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'Microsoft_365_E5_(no_Teams)' 'office-no-teams'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $false 'Teams is required'
    Assert-Throws { Set-LicenseForUser -UserId 'new-user' }
    Assert-Equal $script:requests.Count 0 'Incomplete plan must not be sent'
}

Test-Scenario 'Optional Dynamics is assigned alongside E7 exactly once' {
    $script:config.Settings.InstallDynamicsContent = $true
    Add-TestSku 'MICROSOFT_365_E7' 'e7'
    Add-TestSku 'DYN365_ENTERPRISE_SALES' 'dynamics'
    Add-TestUser 'new-user'
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $true 'Dynamics seat is available'
    Set-LicenseForUser -UserId 'new-user'
    Assert-AssignedSkus @('e7', 'dynamics')
}

Test-Scenario 'Disabled and absent subscriptions are skipped' {
    $script:settings.Licenses.Office = @('ABSENT', 'MICROSOFT_365_E7', 'SPE_E5')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 5 0 'Suspended'
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    Set-LicenseForUser -UserId 'new-user'
    Assert-AssignedSkus @('e5', 'copilot')
}

Test-Scenario 'Exhausted or empty subscriptions cause no assignment' {
    Add-TestSku 'MICROSOFT_365_E7' 'e7' 1 1
    Add-TestUser 'new-user'
    Assert-Equal (Test-License-PreRequisites -Settings $settings) $false 'No seats remain'
    Assert-Throws { Set-LicenseForUser -UserId 'new-user' }
    Assert-Equal $script:requests.Count 0 'No unavailable SKU may be submitted'
    $script:fakeSkus = @()
    Assert-Throws { Set-LicenseForUser -UserId 'new-user' }
}

Test-Scenario 'Actual assignment is re-read until propagation completes' {
    $script:settings.Licenses.Office = @('SPE_E5')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    $script:staleReads = 1
    Set-LicenseForUser -UserId 'new-user'
    Assert-Equal $script:sleeps 1 'Stale assignment must trigger a retry'
    Assert-Equal $script:requests.Count 1 'Propagation retries must not repeat the POST'
}

Test-Scenario 'A successful POST does not replace verification of actual licenses' {
    $script:settings.Licenses.Office = @('SPE_E5')
    $script:settings.Licenses.Copilot = @('Microsoft_365_Copilot')
    Add-TestSku 'SPE_E5' 'e5'
    Add-TestSku 'Microsoft_365_Copilot' 'copilot'
    Add-TestUser 'new-user'
    $script:hideAssignments = $true
    Assert-Throws { Set-LicenseForUser -UserId 'new-user' }
    Assert-Equal $script:sleeps 5 'Failed propagation should exhaust the existing retries'
    Assert-Equal $script:requests.Count 1 'Failed verification must not repeat the POST'
}

$failed = @($script:results | Where-Object { -not $_.Passed })
Write-Host "$($script:results.Count - $failed.Count)/$($script:results.Count) license regression scenarios passed."
if ($failed.Count -gt 0) { exit 1 }

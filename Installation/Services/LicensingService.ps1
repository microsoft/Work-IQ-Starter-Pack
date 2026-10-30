function Test-NoTeamsSku {
    # Office SKUs that do not include Teams, e.g. Microsoft_365_E3_(no_Teams) or O365_w/o_Teams_Bundle_M5
    param($SkuPartNumber)
    return [bool]($SkuPartNumber -match '\(no_Teams\)|w/o[ _]Teams')
}

function Get-LicenseCoverage {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $AvailableSkus,
        [string[]] $AssignedSkuIds = @(),
        [bool] $RequireDynamics = $false
    )

    # Check all assigned SKUs before considering the configured priority for new assignments.
    # Existing assignments do not need another free seat in the subscription.
    $assignedSkus = @($AvailableSkus | Where-Object { $AssignedSkuIds -contains $_.skuId })
    $officeSkus = @($assignedSkus | Where-Object { $Settings.Licenses.Office -contains $_.skuPartNumber })
    $hasOffice = $officeSkus.Count -gt 0
    $hasCopilot = [bool]($assignedSkus | Where-Object { $Settings.Licenses.Copilot -contains $_.skuPartNumber })
    $hasDynamics = [bool]($assignedSkus | Where-Object { $Settings.Licenses.Dynamics -contains $_.skuPartNumber })
    $hasTeams = [bool]($assignedSkus | Where-Object { $Settings.Licenses.Teams -contains $_.skuPartNumber })
    if ($officeSkus | Where-Object { -not (Test-NoTeamsSku -SkuPartNumber $_.skuPartNumber) }) {
        $hasTeams = $true
    }
    $needsTeams = $hasOffice -and -not $hasTeams

    $missingCategories = @()
    if (-not $hasOffice) { $missingCategories += 'Office' }
    if (-not $hasCopilot) { $missingCategories += 'Copilot' }
    if ($RequireDynamics -and -not $hasDynamics) { $missingCategories += 'Dynamics' }
    if ($needsTeams) { $missingCategories += 'Teams' }

    return [PSCustomObject]@{
        HasOffice = $hasOffice
        HasCopilot = $hasCopilot
        HasDynamics = $hasDynamics
        HasTeams = $hasTeams
        NeedsTeams = $needsTeams
        MissingCategories = @($missingCategories)
    }
}

function Get-LicenseSeatAvailability {
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $AvailableSkus
    )
    $remainingSeats = @{}
    foreach ($sku in $AvailableSkus) {
        if ($sku.skuId) {
            $remainingSeats[[string]$sku.skuId] = [Math]::Max(0, [long]$sku.prepaidUnits.enabled - [long]$sku.consumedUnits)
        }
    }
    return $remainingSeats
}

function Get-UserLicensePlan {
    param(
        [Parameter(Mandatory = $true)] $Settings,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]] $AvailableSkus,
        [object[]] $AssignedLicenses = @(),
        [hashtable] $RemainingSeats,
        [bool] $RequireDynamics = $false
    )
    if ($null -eq $RemainingSeats) {
        $RemainingSeats = Get-LicenseSeatAvailability -AvailableSkus $AvailableSkus
    }

    # A hashtable provides a case-insensitive set of assigned and pending SKU IDs.
    $effectiveSkuIds = @{}
    foreach ($license in $AssignedLicenses) {
        if ($license.skuId) { $effectiveSkuIds[[string]$license.skuId] = $true }
    }
    $licensesToAssign = @()
    # Resolve suites first: a suite selected for Copilot or Dynamics may also include Teams.
    foreach ($category in @('Office', 'Copilot', 'Dynamics', 'Teams')) {
        $coverage = Get-LicenseCoverage -Settings $Settings -AvailableSkus $AvailableSkus -AssignedSkuIds @($effectiveSkuIds.Keys) -RequireDynamics $RequireDynamics
        if ($coverage.MissingCategories -notcontains $category) { continue }

        foreach ($skuPartNumber in $Settings.Licenses.$category) {
            $sku = $AvailableSkus | Where-Object { $_.skuPartNumber -eq $skuPartNumber -and $_.capabilityStatus -eq 'Enabled' } | Select-Object -First 1
            if (-not $sku -or -not $sku.skuId) { continue }
            $skuId = [string]$sku.skuId
            if ($effectiveSkuIds.ContainsKey($skuId) -or -not $RemainingSeats.ContainsKey($skuId) -or $RemainingSeats[$skuId] -le 0) { continue }

            $licensesToAssign += @{ skuId = $skuId }
            $effectiveSkuIds[$skuId] = $true
            # Reserve a seat once per SKU per user, even when it covers several categories.
            $RemainingSeats[$skuId]--
            break
        }
    }

    $coverage = Get-LicenseCoverage -Settings $Settings -AvailableSkus $AvailableSkus -AssignedSkuIds @($effectiveSkuIds.Keys) -RequireDynamics $RequireDynamics
    return [PSCustomObject]@{
        AddLicenses = @($licensesToAssign)
        MissingCategories = @($coverage.MissingCategories)
    }
}

function Test-License-PreRequisites {
    param(
        [Parameter(Mandatory = $true)] $Settings
    )
    try {
        $availableSkus = @((Invoke-GraphRestMethod -Uri "$graphBaseUrl/subscribedSkus" -Headers $headers -Method Get).value)
        $remainingSeats = Get-LicenseSeatAvailability -AvailableSkus $availableSkus
        $requireDynamics = $config.Settings.InstallDynamicsContent -eq $true
        $allRequirementsMet = $true
        $checkedUsers = @{}

        foreach ($user in $Settings.Users) {
            $upn = $user.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
            if ($checkedUsers.ContainsKey($upn)) { continue }
            $checkedUsers[$upn] = $true
            $graphUser = (Invoke-GraphRestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,assignedLicenses" -Headers $headers -Method Get).value | Select-Object -First 1
            $assignedLicenses = if ($graphUser) { @($graphUser.assignedLicenses) } else { @() }
            $plan = Get-UserLicensePlan -Settings $Settings -AvailableSkus $availableSkus -AssignedLicenses $assignedLicenses -RemainingSeats $remainingSeats -RequireDynamics $requireDynamics

            foreach ($license in $plan.AddLicenses) {
                $sku = $availableSkus | Where-Object { $_.skuId -eq $license.skuId } | Select-Object -First 1
                Write-InstallLogAction -Message "User $upn needs one seat for SKU $($sku.skuPartNumber)."
            }
            if ($plan.MissingCategories.Count -gt 0) {
                $allRequirementsMet = $false
                Write-InstallLogAction -Message "Not enough licenses for user $upn. Missing categories: $($plan.MissingCategories -join ', '). Available seats are reserved per SKU and user." -Level Error
            }
            elseif ($plan.AddLicenses.Count -eq 0) {
                Write-InstallLogAction -Message "User $upn already has all required licenses."
            }
        }
        if ($allRequirementsMet) {
            Write-InstallLogAction -Message 'Enough licenses available for all users, accounting for existing assignments and shared SKUs.' -Level Success
        }
        return $allRequirementsMet
    }
    catch {
        $message = "Failed to check license availability: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { $message += " Graph response: $($_.ErrorDetails.Message)" }
        Write-InstallLogAction -Message $message -Level Error
        throw
    }
}

function Test-CopilotCreditBalance {
    # Uses the Graph beta Copilot Cost Management API (requires CopilotCostManagement.Read.All).
    $retVal = $false
    $betaBaseUrl = "https://graph.microsoft.com/beta/copilot/costmanagement"
    try {
        $balance = Invoke-GraphRestMethod -Uri "$betaBaseUrl/gettenantcreditbalance()" -Headers $headers -Method Get
        $methodBalances = @($balance.billingMethodBalances)

        # Prepaid credits are a purchased pool, so the remaining balance is purchased minus consumed.
        # Pay-as-you-go has no purchased pool (it bills after use), so if it is listed credits are not a blocker.
        $availableCredits = 0
        $payAsYouGoEnabled = $false
        foreach ($methodBalance in $methodBalances) {
            if ($methodBalance.billingMethod -eq "prepaidCredits") {
                $availableCredits += [double]$methodBalance.purchasedQuantity - [double]$methodBalance.consumedQuantity
            }
            elseif ($methodBalance.billingMethod -eq "payAsYouGo") {
                $payAsYouGoEnabled = $true
                Write-InstallLogAction -Message "Pay-as-you-go Copilot credits consumed so far: $($methodBalance.consumedQuantity)"
            }
        }

        if ($availableCredits -gt 0) {
            Write-InstallLogAction -Message "Tenant has $availableCredits prepaid Copilot credits available." -Level Success
            $retVal = $true
        }
        elseif ($payAsYouGoEnabled) {
            Write-InstallLogAction -Message "No prepaid Copilot credits, but pay-as-you-go billing is enabled." -Level Success
            $retVal = $true
        }
        else {
            Write-InstallLogAction -Message "No Copilot credits available in the tenant. Balance response: $($balance | ConvertTo-Json -Depth 5 -Compress)" -Level Error

            # Report whether a spending policy exists, since it controls who can consume credits
            try {
                $policies = @((Invoke-GraphRestMethod -Uri "$betaBaseUrl/spendingPolicies" -Headers $headers -Method Get).value)
                Write-InstallLogAction -Message "Found $($policies.Count) Copilot spending policies." -Level Warning
            }
            catch {
                Write-InstallLogAction -Message "Unable to read Copilot spending policies: $($_.Exception.Message)" -Level Warning
            }
        }
    }
    catch {
        $message = "Failed to check Copilot credit balance: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-InstallLogAction -Message $message -Level Error
    }
    return $retVal
}

function Set-LicenseForUser {
    param(
        [Parameter(Mandatory = $true)] $UserId
    )
    try {
        # Use a fresh snapshot for every user so actual assignments reflect current seat usage.
        $availableSkus = @((Invoke-GraphRestMethod -Uri "$graphBaseUrl/subscribedSkus" -Headers $headers -Method Get).value)
        $currentLicenses = @((Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$UserId`?`$select=assignedLicenses" -Headers $headers -Method Get).assignedLicenses)
        $requireDynamics = $config.Settings.InstallDynamicsContent -eq $true
        $plan = Get-UserLicensePlan -Settings $settings -AvailableSkus $availableSkus -AssignedLicenses $currentLicenses -RequireDynamics $requireDynamics
        if ($plan.MissingCategories.Count -gt 0) {
            throw "No enabled SKU with an available seat can satisfy user $UserId. Missing categories: $($plan.MissingCategories -join ', ')."
        }

        if ($plan.AddLicenses.Count -gt 0) {
            foreach ($license in $plan.AddLicenses) {
                $sku = $availableSkus | Where-Object { $_.skuId -eq $license.skuId } | Select-Object -First 1
                Write-InstallLogAction -Message "Assigning SKU $($sku.skuPartNumber) to user with ID: $UserId"
            }
            $licenseBody = @{ addLicenses = @($plan.AddLicenses); removeLicenses = @() } | ConvertTo-Json -Depth 5
            Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$UserId/assignLicense" -Headers $headers -Method Post -ContentType 'application/json' -Body $licenseBody | Out-Null

            # Verify actual Graph assignments, not the plan or the potentially stale POST response.
            for ($attempt = 1; $attempt -le 6; $attempt++) {
                $currentLicenses = @((Invoke-GraphRestMethod -Uri "$graphBaseUrl/users/$UserId`?`$select=assignedLicenses" -Headers $headers -Method Get).assignedLicenses)
                $coverage = Get-LicenseCoverage -Settings $settings -AvailableSkus $availableSkus -AssignedSkuIds @($currentLicenses | ForEach-Object { $_.skuId }) -RequireDynamics $requireDynamics
                if ($coverage.MissingCategories.Count -eq 0) { break }
                if ($attempt -lt 6) {
                    Write-InstallLogAction -Message "Licenses for user with ID: $UserId not visible yet, retrying ($attempt/6)..."
                    Start-Sleep -Seconds 5
                }
            }
        }
        else {
            Write-InstallLogAction -Message "User with ID: $UserId already has all required licenses; no assignment needed."
        }

        $coverage = Get-LicenseCoverage -Settings $settings -AvailableSkus $availableSkus -AssignedSkuIds @($currentLicenses | ForEach-Object { $_.skuId }) -RequireDynamics $requireDynamics
        if ($coverage.MissingCategories.Count -gt 0) {
            throw "User with ID: $UserId must have all required licenses before content can be provisioned. Missing categories: $($coverage.MissingCategories -join ', ')."
        }
    }
    catch {
        $message = "Failed to assign license: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) { $message += " Graph response: $($_.ErrorDetails.Message)" }
        Write-Host $message -ForegroundColor Red
        throw
    }
}

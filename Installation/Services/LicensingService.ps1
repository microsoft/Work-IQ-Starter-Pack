## Get the available SKUs in the tenant before everything loads
$availableSkus = (Invoke-RestMethod -Uri "$graphBaseUrl/subscribedSkus" -Headers $headers -Method Get).value

function Get-AvailableSkusCount{
    param(
        [Parameter(Mandatory = $true)]
        $SkuPartNumber
    )
    $freeSeatsCount = 0
    try {
        $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
        $freeSeatsCount = $sku.prepaidUnits.enabled - $sku.consumedUnits
    }
    catch {
        $message = "Failed to get SKUs: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-Host $message -ForegroundColor Red
        exit 1
    }
    return $freeSeatsCount
}

function Get-UserLicenseStatus {
    param(
        [Parameter(Mandatory = $true)]
        $User,
        [Parameter(Mandatory = $true)]
        $Settings
    )
    $upn = $User.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
    $status = [PSCustomObject]@{ Exists = $false; HasOffice = $false; HasCopilot = $false }

    $graphUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,assignedLicenses" -Headers $headers -Method Get).value | Select-Object -First 1
    if (-not $graphUser) {
        return $status
    }
    $status.Exists = $true

    $assignedSkuIds = @($graphUser.assignedLicenses | ForEach-Object { $_.skuId })
    $officeSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $Settings.Licenses.Office -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })
    $copilotSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $Settings.Licenses.Copilot -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })

    $status.HasOffice = [bool]($assignedSkuIds | Where-Object { $officeSkuIds -contains $_ })
    $status.HasCopilot = [bool]($assignedSkuIds | Where-Object { $copilotSkuIds -contains $_ })
    return $status
}

function Test-License-PreRequisites {
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )
    $retVal = $false;
    try {
        $copilotLicenseCount = 0
        $officeLicenseCount = 0
        #Get the number of available Copilot and Office licenses in the tenant
        foreach ($skuPartNumber in $Settings.Licenses.Copilot) {
            $copilotLicenseCount += Get-AvailableSkusCount -SkuPartNumber $skuPartNumber
        }
        foreach ($skuPartNumber in $Settings.Licenses.Office) {
            $officeLicenseCount += Get-AvailableSkusCount -SkuPartNumber $skuPartNumber
        }

        #Only count seats for users that actually need a license. Demo users who are not provisioned
        #yet need both; provisioned demo users and real users only need whichever one they are missing.
        $copilotNeeded = 0
        $officeNeeded = 0
        foreach ($user in $Settings.Users) {
            $userStatus = Get-UserLicenseStatus -User $user -Settings $Settings
            $label = $user.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
            if ($config.Settings.InstallDemoUsers -and -not $userStatus.Exists) {
                Write-InstallLogAction -Message "Demo user $label is not provisioned yet; Office and Copilot licenses will be needed."
            }
            else {
                Write-InstallLogAction -Message "User $label - Office license: $($userStatus.HasOffice), Copilot license: $($userStatus.HasCopilot)"
            }
            if (-not $userStatus.HasOffice) { $officeNeeded++ }
            if (-not $userStatus.HasCopilot) { $copilotNeeded++ }
        }

        if($copilotLicenseCount -lt $copilotNeeded) {
            Write-Host "Not enough Copilot licenses available. Required: $copilotNeeded, Available: $copilotLicenseCount" -ForegroundColor Red
        }
        if($officeLicenseCount -lt $officeNeeded) {
            Write-Host "Not enough Office licenses available. Required: $officeNeeded, Available: $officeLicenseCount" -ForegroundColor Red
        }
        if($copilotLicenseCount -ge $copilotNeeded -and $officeLicenseCount -ge $officeNeeded) {
           $retVal = $true
        }
    }
    catch {
        $message = "Not Enough Licenses Available: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-Host $message -ForegroundColor Red
        exit 1
    }
    return $retVal
}

function Test-CopilotCreditBalance {
    # Uses the Graph beta Copilot Cost Management API (requires CopilotCostManagement.Read.All).
    $retVal = $false
    $betaBaseUrl = "https://graph.microsoft.com/beta/copilot/costmanagement"
    try {
        $balance = Invoke-RestMethod -Uri "$betaBaseUrl/gettenantcreditbalance()" -Headers $headers -Method Get
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
                $policies = @((Invoke-RestMethod -Uri "$betaBaseUrl/spendingPolicies" -Headers $headers -Method Get).value)
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
        [Parameter(Mandatory = $true)]
        $UserId
    )
    try {
        $currentLicenses = (Invoke-RestMethod -Uri "$graphBaseUrl/users/$UserId`?`$select=assignedLicenses" -Headers $headers -Method Get).assignedLicenses

        $licensesToAssign = @()
        #Install the M365 Licenses
        foreach ($skuPartNumber in $settings.Licenses.Office) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-InstallLogAction -Message "Assigning Office license $SkuPartNumber to user with ID: $UserId"
                $licensesToAssign += @{ skuId = $sku.skuId }
                break
            }
        }

        #Install Copilot license
        foreach ($skuPartNumber in $settings.Licenses.Copilot) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-InstallLogAction -Message "Assigning Copilot license $SkuPartNumber to user with ID: $UserId"
                $licensesToAssign += @{ skuId = $sku.skuId }
                break
            }
        }

        #If we are installing Dynamics demo add Dynamics licenses
        if($Config.Settings.InstallDynamicsContent -eq $true){
            foreach ($skuPartNumber in $settings.Licenses.Dynamics) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-InstallLogAction -Message "Assigning Copilot license $SkuPartNumber to user with ID: $UserId"
                $licensesToAssign += @{ skuId = $sku.skuId }
                break
            }
        }
        }

        if ($licensesToAssign.Count -gt 0) {
            $licenseBody = @{ addLicenses = $licensesToAssign; removeLicenses = @() } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$graphBaseUrl/users/$UserId/assignLicense" -Headers $headers -Method Post -ContentType "application/json" -Body $licenseBody
        }
        else {
            Write-InstallLogAction -Message "No licenses needed to be assigned to this UserId: $UserId" -Level Error
        }
    }
    catch {
        $message = "Failed to assign license: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-Host $message -ForegroundColor Red
        throw
    }
}
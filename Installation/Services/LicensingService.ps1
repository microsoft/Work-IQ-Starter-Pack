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
        if ($sku) {
            $freeSeatsCount = $sku.prepaidUnits.enabled - $sku.consumedUnits
            Write-InstallLogAction -Message "SKU $SkuPartNumber : $freeSeatsCount free of $($sku.prepaidUnits.enabled) purchased."
        }
        else {
            Write-InstallLogAction -Message "SKU $SkuPartNumber was not found (or is not enabled) in this tenant." -Level Warning
        }
    }
    catch {
        $message = "Failed to get SKUs: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-InstallLogAction -Message $message -Level Error
        exit 1
    }
    return $freeSeatsCount
}

function Test-NoTeamsSku {
    # Office SKUs that do not include Teams, e.g. Microsoft_365_E3_(no_Teams) or O365_w/o_Teams_Bundle_M5
    param(
        $SkuPartNumber
    )
    return [bool]($SkuPartNumber -match '\(no_Teams\)|w/o[ _]Teams')
}

function Get-OfficeSkuToAssign {
    # Mirrors the SKU selection in Set-LicenseForUser: first enabled Office SKU with a free seat
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )
    foreach ($skuPartNumber in $Settings.Licenses.Office) {
        $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $skuPartNumber -and $_.capabilityStatus -eq "Enabled"}
        if ($sku -and ($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0)) {
            return $sku
        }
    }
    return $null
}

function Get-UserLicenseStatus {
    param(
        [Parameter(Mandatory = $true)]
        $User,
        [Parameter(Mandatory = $true)]
        $Settings
    )
    $upn = $User.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
    $status = [PSCustomObject]@{ Exists = $false; HasOffice = $false; HasCopilot = $false; NeedsTeams = $false }

    $graphUser = (Invoke-RestMethod -Uri "$graphBaseUrl/users?`$filter=userPrincipalName eq '$upn'&`$select=id,assignedLicenses" -Headers $headers -Method Get).value | Select-Object -First 1
    if (-not $graphUser) {
        # Not provisioned yet: Teams is needed if the Office SKU that will be assigned has no Teams
        $officeSku = Get-OfficeSkuToAssign -Settings $Settings
        $status.NeedsTeams = [bool]($officeSku -and (Test-NoTeamsSku -SkuPartNumber $officeSku.skuPartNumber))
        return $status
    }
    $status.Exists = $true

    $assignedSkuIds = @($graphUser.assignedLicenses | ForEach-Object { $_.skuId })
    $officeSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $Settings.Licenses.Office -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })
    $copilotSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $Settings.Licenses.Copilot -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })

    $status.HasOffice = [bool]($assignedSkuIds | Where-Object { $officeSkuIds -contains $_ })
    $status.HasCopilot = [bool]($assignedSkuIds | Where-Object { $copilotSkuIds -contains $_ })

    # Teams is only needed when the user's Office SKU (assigned now or still to be assigned) has no Teams
    $teamsSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $Settings.Licenses.Teams -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })
    $hasTeams = [bool]($assignedSkuIds | Where-Object { $teamsSkuIds -contains $_ })
    if ($status.HasOffice) {
        $assignedOfficeSkus = @($availableSkus | Where-Object { $assignedSkuIds -contains $_.skuId -and $officeSkuIds -contains $_.skuId })
        $officeHasNoTeams = [bool]($assignedOfficeSkus | Where-Object { Test-NoTeamsSku -SkuPartNumber $_.skuPartNumber })
    }
    else {
        $officeSku = Get-OfficeSkuToAssign -Settings $Settings
        $officeHasNoTeams = [bool]($officeSku -and (Test-NoTeamsSku -SkuPartNumber $officeSku.skuPartNumber))
    }
    $status.NeedsTeams = ($officeHasNoTeams -and -not $hasTeams)
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
        $teamsLicenseCount = 0
        Write-InstallLogAction -Message "Checking license availability. Copilot SKUs: $($Settings.Licenses.Copilot -join ', '). Office SKUs: $($Settings.Licenses.Office -join ', ')."
        #Get the number of available Copilot and Office licenses in the tenant
        foreach ($skuPartNumber in $Settings.Licenses.Copilot) {
            $copilotLicenseCount += Get-AvailableSkusCount -SkuPartNumber $skuPartNumber
        }
        foreach ($skuPartNumber in $Settings.Licenses.Office) {
            $officeLicenseCount += Get-AvailableSkusCount -SkuPartNumber $skuPartNumber
        }
        foreach ($skuPartNumber in $Settings.Licenses.Teams) {
            $teamsLicenseCount += Get-AvailableSkusCount -SkuPartNumber $skuPartNumber
        }

        #Only count seats for users that actually need a license. Demo users who are not provisioned
        #yet need both; provisioned demo users and real users only need whichever one they are missing.
        $copilotNeeded = 0
        $officeNeeded = 0
        $teamsNeeded = 0
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
            if ($userStatus.NeedsTeams) {
                Write-InstallLogAction -Message "User $label has an Office license without Teams; a Teams license will be needed."
                $teamsNeeded++
            }
        }

        if($copilotLicenseCount -lt $copilotNeeded) {
            Write-InstallLogAction -Message "Not enough Copilot licenses available. Required: $copilotNeeded (users without a Copilot license), Available: $copilotLicenseCount. SKUs checked: $($Settings.Licenses.Copilot -join ', ')." -Level Error
        }
        if($officeLicenseCount -lt $officeNeeded) {
            Write-InstallLogAction -Message "Not enough Office licenses available. Required: $officeNeeded (users without an Office license), Available: $officeLicenseCount. SKUs checked: $($Settings.Licenses.Office -join ', ')." -Level Error
        }
        if($teamsNeeded -gt 0 -and $teamsLicenseCount -lt $teamsNeeded) {
            Write-InstallLogAction -Message "Not enough Teams licenses available. Required: $teamsNeeded (users with an Office license that does not include Teams), Available: $teamsLicenseCount. SKUs checked: $($Settings.Licenses.Teams -join ', ')." -Level Error
        }
        if($copilotLicenseCount -ge $copilotNeeded -and $officeLicenseCount -ge $officeNeeded -and ($teamsNeeded -eq 0 -or $teamsLicenseCount -ge $teamsNeeded)) {
           Write-InstallLogAction -Message "Enough licenses available. Copilot: $copilotNeeded needed, $copilotLicenseCount available. Office: $officeNeeded needed, $officeLicenseCount available. Teams: $teamsNeeded needed, $teamsLicenseCount available." -Level Success
           $retVal = $true
        }
    }
    catch {
        $message = "Not Enough Licenses Available: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-InstallLogAction -Message $message -Level Error
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
        $availableSkus = (Invoke-RestMethod -Uri "$graphBaseUrl/subscribedSkus" -Headers $headers -Method Get).value
        $currentLicenses = (Invoke-RestMethod -Uri "$graphBaseUrl/users/$UserId`?`$select=assignedLicenses" -Headers $headers -Method Get).assignedLicenses
        $officeSkuIds = @($availableSkus | Where-Object { $settings.Licenses.Office -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })
        $copilotSkuIds = @($availableSkus | Where-Object { $settings.Licenses.Copilot -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })

        $licensesToAssign = @()
        #Install the M365 Licenses
        $officeSku = $null
        foreach ($skuPartNumber in $settings.Licenses.Office) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                $officeSku = $sku
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-InstallLogAction -Message "Assigning Office license $SkuPartNumber to user with ID: $UserId"
                $licensesToAssign += @{ skuId = $sku.skuId }
                $officeSku = $sku
                break
            }
        }

        #Office licenses without Teams (e.g. "(no_Teams)") need a separate Teams license
        if ($officeSku -and (Test-NoTeamsSku -SkuPartNumber $officeSku.skuPartNumber)) {
            $teamsSkuIds = @($availableSkus | Where-Object { $_.skuPartNumber -and $settings.Licenses.Teams -contains $_.skuPartNumber } | ForEach-Object { $_.skuId })
            if ($currentLicenses | Where-Object { $teamsSkuIds -contains $_.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has a Teams license, skipping."
            }
            else {
                $teamsAssigned = $false
                foreach ($skuPartNumber in $settings.Licenses.Teams) {
                    $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
                    if ($sku -and ($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0)) {
                        Write-InstallLogAction -Message "Office license $($officeSku.skuPartNumber) does not include Teams. Assigning Teams license $SkuPartNumber to user with ID: $UserId"
                        $licensesToAssign += @{ skuId = $sku.skuId }
                        $teamsAssigned = $true
                        break
                    }
                }
                if (-not $teamsAssigned) {
                    Write-InstallLogAction -Message "Office license $($officeSku.skuPartNumber) does not include Teams and no Teams license is available for user with ID: $UserId" -Level Warning
                }
            }
        }

        #Install Copilot license
        foreach ($skuPartNumber in $settings.Licenses.Copilot) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $copilotSkuIds -contains $_.skuId }) {
                Write-InstallLogAction -Message "User with ID: $UserId already has a Copilot license, skipping."
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
            $currentLicenses = (Invoke-RestMethod -Uri "$graphBaseUrl/users/$UserId/assignLicense" -Headers $headers -Method Post -ContentType "application/json" -Body $licenseBody).assignedLicenses
        }
        else {
            Write-InstallLogAction -Message "No licenses needed to be assigned to this UserId: $UserId" -Level Warning
        }

        if (-not ($currentLicenses | Where-Object { $officeSkuIds -contains $_.skuId }) -or
            -not ($currentLicenses | Where-Object { $copilotSkuIds -contains $_.skuId })) {
            throw "User with ID: $UserId must have both an Office license and a Microsoft 365 Copilot license before content can be provisioned."
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
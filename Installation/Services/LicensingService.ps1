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
        Write-Host "Failed to get SKUs: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    return $freeSeatsCount
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

        if($copilotLicenseCount -lt $Settings.Users.Count) {
            Write-Host "Not enough Copilot licenses available. Required: $($Settings.Users.Count), Available: $copilotLicenseCount" -ForegroundColor Red
        }
        if($officeLicenseCount -lt $Settings.Users.Count) {
            Write-Host "Not enough Office licenses available. Required: $($Settings.Users.Count), Available: $officeLicenseCount" -ForegroundColor Red
        }
        if($copilotLicenseCount -ge $Settings.Users.Count -and $officeLicenseCount -ge $Settings.Users.Count) {
           $retVal = $true
        }
    }
    catch {
        Write-Host "Not Enough Licenses Available: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
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
        foreach ($skuPartNumber in $settings.Licenses.Office) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-Host "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-Host "Assigning Office license $SkuPartNumber to user with ID: $UserId"
                $licensesToAssign += @{ skuId = $sku.skuId }
                break
            }
        }

        foreach ($skuPartNumber in $settings.Licenses.Copilot) {
            $sku = $availableSkus | Where-Object {$_.skuPartNumber -eq $SkuPartNumber -and $_.capabilityStatus -eq "Enabled"}
            if ($currentLicenses | Where-Object { $_.skuId -eq $sku.skuId }) {
                Write-Host "User with ID: $UserId already has the $SkuPartNumber license, skipping."
                break
            }
            if($sku.prepaidUnits.enabled - $sku.consumedUnits -gt 0) {
                Write-Host "Assigning Copilot license $SkuPartNumber to user with ID: $UserId"
                #$licensesToAssign += @{ skuId = $sku.skuId }
                break
            }
        }

        if ($licensesToAssign.Count -gt 0) {
            $licenseBody = @{ addLicenses = $licensesToAssign; removeLicenses = @() } | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$graphBaseUrl/users/$UserId/assignLicense" -Headers $headers -Method Post -ContentType "application/json" -Body $licenseBody
        }
        else {
            Write-Host "No licenses found to assign for user with ID: $UserId" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Failed to assign license: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}
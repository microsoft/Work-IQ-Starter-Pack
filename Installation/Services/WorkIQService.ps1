function Enable-WorkIQServicePrincipal {
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )
    try {
        $appId = $Settings.WorkIQAppId
        $existing = (Invoke-RestMethod -Uri "$graphBaseUrl/servicePrincipals?`$filter=appId eq '$appId'" -Headers $headers -Method Get).value | Select-Object -First 1
        if ($existing) {
            Write-Host "Work IQ service principal already exists in this tenant (AppId: $appId)."
            return $true
        }

        $body = @{ appId = $appId } | ConvertTo-Json
        Invoke-RestMethod -Uri "$graphBaseUrl/servicePrincipals" -Headers $headers -Method Post -ContentType "application/json" -Body $body | Out-Null
        Write-Host "Work IQ service principal created in this tenant (AppId: $appId)."
        return $true
    }
    catch {
        Write-Host "Failed to enable the Work IQ service principal: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
}

function Test-WorkIQServicePrincipalEnabled {
    param(
        [Parameter(Mandatory = $true)]
        $Settings
    )
    $retVal = $false
    try {
        $appId = $Settings.WorkIQAppId
        $servicePrincipal = (Invoke-RestMethod -Uri "$graphBaseUrl/servicePrincipals?`$filter=appId eq '$appId'" -Headers $headers -Method Get).value | Select-Object -First 1

        if (-not $servicePrincipal) {
            Write-Host "Work IQ service principal not found in this tenant (AppId: $appId)." -ForegroundColor Red
            $retVal = $false
        }

        if ($servicePrincipal.accountEnabled) {
            Write-Host "Work IQ service principal is enabled."
            $retVal = $true
        }
        else {
            Write-Host "Work IQ service principal is disabled." -ForegroundColor Red
            $retVal = $false
        }
    }
    catch {
        Write-Host "Failed to check Work IQ service principal status: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    return $retVal
}

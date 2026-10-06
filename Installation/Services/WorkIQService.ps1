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

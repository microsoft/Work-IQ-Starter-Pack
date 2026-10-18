#Requires -Version 7.4

# Independently clean Dynamics and F&O demo records using source IDs/codes.
$cleanupSucceeded = $false
. (Join-Path $PSScriptRoot 'Installation/Services/InstallLogService.ps1')
Initialize-InstallLog -Title 'WorkIQ Starter Pack Mini Cleanup Log' -FileName 'CleanUpMiniLog.md' -IncludePasswords $false

function Read-MiniCleanupChoice {
    param([string]$Prompt)
    do {
        $answer = (Read-Host "$Prompt (yes/no, default: no)").Trim().ToLowerInvariant()
    } while ($answer -notin @('', 'yes', 'y', 'no', 'n'))
    $selected = $answer -in @('yes', 'y')
    Write-InstallLogInput -Prompt $Prompt -Response $(if ($selected) { 'Yes' } else { 'No' })
    return $selected
}

try {
    $configPath = Join-Path $PSScriptRoot 'Configuration/config.json'
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $contentPath = Join-Path $PSScriptRoot 'Content/content_dynamics.json'
    $content = Get-Content -LiteralPath $contentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

    Write-Host "Dynamics cleanup deletes demo emails, cases, invoices, orders, quotes, opportunities, leads, accounts, and product catalog records by their IDs in Content/content_dynamics.json from $($config.Settings.DynamicsEnvironmentUrl)."
    $deleteDynamics = Read-MiniCleanupChoice 'Do you want to delete the Dynamics demo data?'
    Write-Host "F&O cleanup deletes $(@($content.Orders).Count) demo sales orders and their lines, $(@($content.Accounts).Count) demo customers by account code in company '$($config.Settings.DynamicsFOLegalEntityId)' and $(@($content.Products).Count) shared products by product number from $($config.Settings.DynamicsFOEnvironmentUrl). Shared products apply across companies."
    $deleteFO = Read-MiniCleanupChoice 'Do you want to delete the Dynamics F&O demo data?'
    if (-not $deleteDynamics -and -not $deleteFO) {
        Write-InstallLogAction -Message 'No cleanup selected.'
        $cleanupSucceeded = $true
        return
    }
    $requiredSettings = @('TenantPrefix','ClientId')
    if ($deleteDynamics) { $requiredSettings += 'DynamicsEnvironmentUrl' }
    if ($deleteFO) { $requiredSettings += @('DynamicsFOEnvironmentUrl','DynamicsFOLegalEntityId') }
    foreach ($setting in $requiredSettings) {
        if ([string]::IsNullOrWhiteSpace($config.Settings.$setting)) { throw "Settings.$setting is required in Configuration/config.json." }
    }
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force -ErrorAction Stop
    }
    Import-Module PnP.PowerShell -ErrorAction Stop
    Connect-PnPOnline -Url "https://$($config.Settings.TenantPrefix).sharepoint.com" -ClientId $config.Settings.ClientId -Interactive -ErrorAction Stop

    $failures = @()
    if ($deleteDynamics) {
        try {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsService.ps1')
            Remove-DynamicsFieldEngagements -Config $config -ContentPath $contentPath
            Remove-DynamicsEmails -Config $config -ContentPath $contentPath
            Remove-DynamicsIncidents -Config $config -ContentPath $contentPath
            Remove-DynamicsInvoices -Config $config -ContentPath $contentPath
            Remove-DynamicsOrders -Config $config -ContentPath $contentPath
            Remove-DynamicsQuotes -Config $config -ContentPath $contentPath
            Remove-DynamicsOpportunities -Config $config -ContentPath $contentPath
            Remove-DynamicsProductCatalog -Config $config -ContentPath $contentPath
            Remove-DynamicsLeads -Config $config -ContentPath $contentPath
            Remove-DynamicsAccounts -Config $config -ContentPath $contentPath
            Write-Host 'Dynamics demo data deletion completed.'
            Write-Host 'Removing the managed Field Engagement solution also removes its custom table, app, and any remaining Field Engagement records.'
            if (Read-MiniCleanupChoice 'Do you also want to remove the Caldova Field Engagement solution?') {
                Remove-DynamicsFieldEngagementSolution -Config $config
            }
        }
        catch {
            $failures += "Dynamics: $($_.Exception.Message)"
            Write-InstallLogAction -Message $failures[-1] -Level Error
        }
    }
    if ($deleteFO) {
        try {
            . (Join-Path $PSScriptRoot 'Installation/Services/DynamicsFOService.ps1')
            Remove-DynamicsFOContent -Config $config -ContentPath $contentPath
        }
        catch {
            $failures += "Dynamics F&O: $($_.Exception.Message)"
            Write-InstallLogAction -Message $failures[-1] -Level Error
        }
    }
    if ($failures.Count) { throw ($failures -join ' | ') }
    $cleanupSucceeded = $true
    Write-InstallLogAction -Message 'Selected mini cleanup operations complete.' -Level Success
}
catch {
    Write-InstallLogAction -Message "Mini cleanup failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if (Get-Command Disconnect-PnPOnline -ErrorAction SilentlyContinue) { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
    Save-InstallLog -Success $cleanupSucceeded
    Write-Host "Cleanup log: $script:installLogPath"
}

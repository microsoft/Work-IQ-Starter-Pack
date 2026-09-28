$configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
$config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

$tenantPrefix = $config.Settings.TenantPrefix
$clientId = $config.Settings.ClientId
$siteId = Read-Host "Enter the SiteId (GUID) of the orphaned site"

Connect-PnPOnline -Url "https://$tenantPrefix-admin.sharepoint.com" -ClientId $clientId -Interactive

$targetSite = Get-PnPTenantSite -Detailed | Where-Object { $_.SiteId -eq $siteId }

if (-not $targetSite) {
    Write-Host "No active site found with SiteId '$siteId' - it may already be deleted or sitting in the recycle bin." -ForegroundColor Yellow
    return
}

Write-Host "Site: $($targetSite.Url)"
Write-Host "GroupId: $($targetSite.GroupId)"

# The site is still reporting a non-empty GroupId, which is why Remove-PnPTenantSite refuses it -
# check whether that group is soft-deleted (mid-cascade) or fully gone (orphaned) before doing
# anything destructive to it.
. (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")
$graphBaseUrl = "https://graph.microsoft.com/v1.0"
$headers = @{ Authorization = "Bearer $(Get-WorkIQGraphAccessToken)" }

try {
    $activeGroup = Invoke-RestMethod -Uri "$graphBaseUrl/groups/$($targetSite.GroupId)" -Headers $headers -Method Get
    Write-Host "Group is still ACTIVE in Entra ID: $($activeGroup.displayName). Delete the group (not the site) to trigger the site's automatic cleanup." -ForegroundColor Cyan
}
catch {
    Write-Host "Group is not active (expected, since you already deleted it). Checking deleted items..." -ForegroundColor Yellow

    try {
        $deletedGroup = Invoke-RestMethod -Uri "$graphBaseUrl/directory/deletedItems/$($targetSite.GroupId)" -Headers $headers -Method Get
        Write-Host "Group '$($deletedGroup.displayName)' is soft-deleted (deletedDateTime: $($deletedGroup.deletedDateTime)). Permanently purging it now to force the site cleanup cascade to complete - this is irreversible, the group can no longer be restored from Deleted Groups after this." -ForegroundColor Cyan

        $null = Invoke-RestMethod -Uri "$graphBaseUrl/directory/deletedItems/$($targetSite.GroupId)" -Headers $headers -Method Delete
        Write-Host "Group permanently purged. Give it a few minutes to propagate, then re-run the site removal (Remove-PnPTenantSite / Remove-PnPTenantDeletedSite) against '$($targetSite.Url)'." -ForegroundColor Green
    }
    catch {
        Write-Host "Group '$($targetSite.GroupId)' was not found in Entra ID's deleted items either - it looks fully purged. This site is now orphaned; a Microsoft 365 support ticket is likely needed to remove it." -ForegroundColor Red
    }
}

# Dynamics 365 and SharePoint integration services.

function Test-DynamicsSharePointIntegration {
    <#
    .SYNOPSIS
    Checks for active SharePoint document-management sites configured in Dynamics.
    .DESCRIPTION
    Returns a Boolean and logs the configured active SharePoint sites and their
    last validation status. This is a configuration check, not a live SharePoint
    connectivity test or a check of document management on individual tables.
    .EXAMPLE
    Test-DynamicsSharePointIntegration -Config $config
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)]$Config)

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw 'DynamicsEnvironmentUrl must be an HTTPS environment root URL.'
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $tenantPrefix = ([string]$Config.Settings.TenantPrefix).Trim() -replace '\.onmicrosoft\.com$', ''
    if ($tenantPrefix -notmatch '^[a-zA-Z0-9-]+$') { throw 'Settings.TenantPrefix must contain a valid tenant prefix.' }
    Write-InstallLogAction -Message "Tenant SharePoint URL: https://$tenantPrefix.sharepoint.com"
    Write-InstallLogAction -Message "Checking SharePoint integration configuration in '$environmentUrl'..."
    try {
        $token = Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop
        $requestHeaders = @{Authorization="Bearer $token";Accept='application/json';'OData-Version'='4.0';'OData-MaxVersion'='4.0'}
        # Exclude OneDrive and Teams site records: only service type 0 is SharePoint.
        $filter = [Uri]::EscapeDataString('statecode eq 0 and servicetype eq 0')
        $url = "$environmentUrl/api/data/v9.2/sharepointsites?`$select=sharepointsiteid,name,absoluteurl,validationstatus,isdefault&`$filter=$filter"
        $sites = @()
        do {
            $uri = [Uri]::new([Uri]"$environmentUrl/", $url)
            if ($uri.GetLeftPart([UriPartial]::Authority) -ne $environmentUrl) { throw 'SharePoint-site pagination URL points outside the Dynamics environment.' }
            $response = Invoke-RestMethod -Uri $uri.AbsoluteUri -Headers $requestHeaders -Method Get -ErrorAction Stop
            $sites += @($response.value | Where-Object { $_ })
            $url = $response.'@odata.nextLink'
        } while ($url)
        if (-not $sites.Count) {
            Write-InstallLogAction -Message 'No active SharePoint document-management sites are configured in Dynamics.' -Level Warning
            return $false
        }
        Write-InstallLogAction -Message "SharePoint integration is configured with $($sites.Count) active site(s)." -Level Success
        $validationLabels = @{1='Not validated';2='In progress';3='Invalid';4='Valid';5='Could not validate'}
        foreach ($site in $sites) {
            $status = $validationLabels[[int]$site.validationstatus]
            if (-not $status) { $status = 'Unknown' }
            Write-InstallLogAction -Message "SharePoint site: '$($site.name)' ($($site.absoluteurl)); last validation: $status; default: $($site.isdefault)."
        }
        return $true
    }
    catch { throw "Failed to check Dynamics SharePoint integration: $($_.Exception.Message) $($_.ErrorDetails.Message)" }
}

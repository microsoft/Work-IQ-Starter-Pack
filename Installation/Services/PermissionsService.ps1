function Test-GlobalAdminPreRequisite {
    $retVal = $false
    try {
        $globalAdminRoleTemplateId = "62e90394-69f5-4237-9190-012177145e10"
        $memberOfRoles = (Invoke-RestMethod -Uri "$graphBaseUrl/me/memberOf/microsoft.graph.directoryRole" -Headers $headers -Method Get).value

        if ($memberOfRoles | Where-Object { $_.roleTemplateId -eq $globalAdminRoleTemplateId }) {
            Write-InstallLogAction -Message "Current user is a Global Administrator."
            $retVal = $true
        }
        else {
            Write-Host "Current user is not a Global Administrator. This solution requires the installing user to be a Global Administrator on the tenant." -ForegroundColor Red
        }
    }
    catch {
        $message = "Failed to check Global Administrator role: $($_.Exception.Message)"
        if ($_.ErrorDetails.Message) {
            $message += " Graph response: $($_.ErrorDetails.Message)"
        }
        Write-Host $message -ForegroundColor Red
        exit 1
    }
    return $retVal
}

function Test-PowerPlatformEnvironmentPermissions {
    param(
        [Parameter(Mandatory = $false)]
        $Settings
    )
    # TODO: Stubbed until Power Platform auth/module scaffolding is added to this installer.
    return $true
}

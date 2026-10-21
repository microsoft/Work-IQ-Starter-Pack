try {
    if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) {
        Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
    }
    Import-Module PnP.PowerShell
}
catch {
    Write-Host "Failed to install or import the PnP.PowerShell module: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Ask the user a yes/no question for configuration
function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$Default = $true
    )

    $suffix = if ($Default) { " (yes/no, default: yes)" } else { " (yes/no, default: no)" }

    do {
        $answer = (Read-Host "$Prompt$suffix").Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $Default
        }
    } while ($answer -notin @("yes", "no", "y", "n"))

    return $answer -in @("yes", "y")
}

# Remove a file the installer generated, if present
function Remove-GeneratedFile {
    param(
        [string]$Path,
        [string]$Description
    )

    if (Test-Path $Path) {
        Remove-Item -Path $Path -Recurse -Force
        Write-InstallLogAction -Message "Removed $Description at $Path."
    }
    else {
        Write-InstallLogAction -Message "No $Description found, skipping."
    }
}

$cleanupSucceeded = $false
try {
    # Load the configuration file from file system
    $configPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/config.json"
    $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json

    # Load the installation settings file from file system
    $settingsPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/settings.json"
    $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
    foreach ($user in $settings.Users) {
        $user.Email = $user.Email -replace '<TENANTPREFIX>', $config.Settings.TenantPrefix
    }

    # The sites to remove always come from the pristine content.json; the custom (persona-swapped)
    # copy defines the same sites.
    $contentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.json"
    $customContentPath = Join-Path -Path $PSScriptRoot -ChildPath "Content/content.custom.json"
    $customUsersPath = Join-Path -Path $PSScriptRoot -ChildPath "Configuration/users.custom.json"
    $logsPath = Join-Path -Path $PSScriptRoot -ChildPath "Logs"

    # Record what the cleanup does in Logs/CleanUpLog.md, using the same log service as the installer
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/InstallLogService.ps1")
    Initialize-InstallLog -Title "WorkIQ Starter Pack Cleanup Log" -FileName "CleanUpLog.md" -IncludePasswords $false

    # The PnP and Graph connections both need the tenant and app registration client ID. Without
    # them nothing can be cleaned up (and nothing was installed), so stop here before prompting.
    if ([string]::IsNullOrWhiteSpace($config.Settings.ClientId) -or [string]::IsNullOrWhiteSpace($config.Settings.TenantPrefix)) {
        Write-InstallLogAction -Message "No ClientId and/or TenantPrefix found in Configuration/config.json, so the cleanup cannot connect to your tenant. Nothing was removed. Set Settings.ClientId and Settings.TenantPrefix in config.json and run the cleanup again." -Level Warning
        exit 0
    }

    $confirmed = Read-YesNo "This will remove the demo Teams (and their groups and sites), demo users, and generated files from https://$($config.Settings.TenantPrefix).sharepoint.com. Continue?"

    if (-not $confirmed) {
        Write-Host "Cleanup cancelled."
        exit 0
    }

    # Ask up front so the rest of the cleanup can run unattended
    $removeLogs = Read-YesNo "Do you also want to delete the installation logs (Logs/ - these contain the demo users' temporary passwords)?"
    $removeAppRegistration = Read-YesNo "Do you also want to remove the application registration (ClientId: $($config.Settings.ClientId)) and its service principal from Entra ID, and delete the local Teams chat migration certificate? Only do this if this script originally created the app registration for you - skip if you supplied a pre-existing one."

    Write-InstallLogInput -Prompt "Remove demo Teams, users and generated files?" -Response "Yes"
    Write-InstallLogInput -Prompt "Delete the installation logs?" -Response $(if ($removeLogs) { "Yes" } else { "No" })
    Write-InstallLogInput -Prompt "Remove the application registration and migration certificate?" -Response $(if ($removeAppRegistration) { "Yes" } else { "No" })

    # Make sure there are no existing connections sitting out there
    Disconnect-PnPOnline -ErrorAction SilentlyContinue

    # Load services files
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/AppRegistrationService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/UserService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/TeamsService.ps1")
    . (Join-Path -Path $PSScriptRoot -ChildPath "Installation/Services/EmailService.ps1")

    $sharePointUrl = "https://$($config.Settings.TenantPrefix).sharepoint.com"
    try {
        Connect-PnPOnline -Url $sharePointUrl -ClientId $config.Settings.ClientId -Interactive -ErrorAction Stop
    }
    catch {
        Write-InstallLogAction -Message "Could not connect to $sharePointUrl with ClientId $($config.Settings.ClientId): $($_.Exception.Message) Nothing was removed. Check the ClientId and TenantPrefix in Configuration/config.json and that the app registration has been granted admin consent." -Level Error
        exit 1
    }
    $global:workIQPnPClientId = $config.Settings.ClientId

    # Set the global Graph variables, reusing the PnP connection made above
    Connect-WorkIQGraph -SharePointUrl $sharePointUrl -ClientId $config.Settings.ClientId

    # Deleting from real user mailboxes requires a Teams chat migration certificate and access token. 
    $migrationCertificatePath = Join-Path -Path $PSScriptRoot -ChildPath "Installation/.certs/teams-chat-migration.pfx"
    if (((Test-Path $customUsersPath) -or (Test-Path $customContentPath)) -and (Test-Path $migrationCertificatePath)) {
        try {
            $mailToken = Get-TeamsChatMigrationAccessToken -ClientId $config.Settings.ClientId `
                -TenantPrefix $config.Settings.TenantPrefix -CertificatePath $migrationCertificatePath
            $mailSettings = $null
            if (Test-Path $customUsersPath) {
                $mailSettings = [PSCustomObject]@{ Users = (Get-Content -Path $customUsersPath -Raw | ConvertFrom-Json) }
            }
            Remove-ImportedEmails -Settings $mailSettings -ContentPath $customContentPath -MailHeaders @{ Authorization = "Bearer $mailToken" }
        }
        catch {
            Write-InstallLogAction -Message "Could not remove imported emails: $($_.Exception.Message)" -Level Warning
        }
    }

    # Tear down in the reverse order the installer creates things: Teams/groups/sites first, then users.
    Remove-Teams -ContentPath $contentPath -Config $config
    Remove-Users -Settings $settings

    # Generated files: the real-user mapping and persona-swapped content from "existing users" installs
    Remove-GeneratedFile -Path $customUsersPath -Description "custom users file"
    Remove-GeneratedFile -Path $customContentPath -Description "custom content file"

    if ($removeLogs) {
        Remove-GeneratedFile -Path $logsPath -Description "installation logs"
    }

    if ($removeAppRegistration) {
        Remove-AppRegistration -ClientId $config.Settings.ClientId
        Remove-TeamsChatMigrationCertificate
    }

    if ($script:sitesNotRemoved -and $script:sitesNotRemoved.Count -gt 0) {
        Write-InstallLogAction -Message "Cleanup finished, but $($script:sitesNotRemoved.Count) site(s) could not be fully removed. Please clean these up manually in the SharePoint admin center (active sites and deleted sites) or with PowerShell:" -Level Warning
        foreach ($remaining in $script:sitesNotRemoved) {
            Write-InstallLogAction -Message "  - $($remaining.Title): $($remaining.Url) ($($remaining.Reason))" -Level Warning
        }
    }
    else {
        Write-InstallLogAction -Message "Cleanup complete." -Level Success
    }
    $cleanupSucceeded = $true
}
catch {
    Write-InstallLogAction -Message "Failed to clean up the Work IQ Starter Pack: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    Disconnect-PnPOnline -ErrorAction SilentlyContinue

    # Always write the cleanup log, even on failure - unless the admin chose to delete the logs
    # folder, in which case writing it again would just recreate it.
    if ($script:installLogPath -and -not $removeLogs) {
        Save-InstallLog -Success ($cleanupSucceeded -eq $true)
        $logLink = "file://$($script:installLogPath -replace '\\', '/')"
        Write-Host ""
        Write-Host "Cleanup log: $logLink" -ForegroundColor Cyan
    }
}

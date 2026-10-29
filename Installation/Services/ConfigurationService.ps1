function Get-WorkIQConfigurationPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        throw 'Provide a configuration file path with -Config.'
    }
    $file = Get-Item -LiteralPath $ConfigPath -ErrorAction Stop
    if ($file.PSIsContainer -or $file.PSProvider.Name -ne 'FileSystem') {
        throw "Configuration path '$ConfigPath' must point to a file."
    }
    $config = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($config -isnot [PSCustomObject] -or $config.Settings -isnot [PSCustomObject]) {
        throw "Configuration file '$($file.FullName)' must contain a Settings object."
    }

    $defaultConfigPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'Configuration/config.json'))
    if ([IO.Path]::GetRelativePath($defaultConfigPath, $file.FullName) -eq '.') {
        $customContentPath = Join-Path $RepositoryRoot 'Content/content.custom.json'
        $customUsersPath = Join-Path $RepositoryRoot 'Configuration/users.custom.json'
        $certificateDirectory = Join-Path $RepositoryRoot 'Installation/.certs'
        $importedPostsPath = Join-Path $RepositoryRoot 'Installation/.state/imported-posts.json'
        $logDirectory = Join-Path $RepositoryRoot 'Logs'
    }
    else {
        $generatedRoot = Join-Path $file.DirectoryName 'Generated'
        $customContentPath = Join-Path $generatedRoot 'content.custom.json'
        $customUsersPath = Join-Path $generatedRoot 'users.custom.json'
        $certificateDirectory = Join-Path $generatedRoot '.certs'
        $importedPostsPath = Join-Path $generatedRoot '.state/imported-posts.json'
        $logDirectory = Join-Path $generatedRoot 'Logs'
    }
    Write-InstallLogAction -Message "Certificate directory: $certificateDirectory., Certificate path: $(Join-Path $certificateDirectory 'teams-chat-migration.pfx')" -Level Info
    return [PSCustomObject]@{
        ConfigPath = $file.FullName
        Config = $config
        CustomContentPath = $customContentPath
        CustomUsersPath = $customUsersPath
        CertificateDirectory = $certificateDirectory
        CertificatePath = Join-Path $certificateDirectory 'teams-chat-migration.pfx'
        ImportedPostsPath = $importedPostsPath
        LogDirectory = $logDirectory
    }
}

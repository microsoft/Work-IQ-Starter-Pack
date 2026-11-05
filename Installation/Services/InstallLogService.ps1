function Wait-InstallPollingInterval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [ValidateRange(1, 3600)][int]$Seconds = 30
    )
    # This bar measures the wait until the next check, not task completion.
    try {
        for ($remaining = $Seconds; $remaining -gt 0; $remaining--) {
            Write-Progress -Id 41 -Activity $Activity -Status "Next check in $remaining seconds" -SecondsRemaining $remaining -PercentComplete ([int](100 * ($Seconds - $remaining) / $Seconds))
            Start-Sleep -Seconds 1
        }
    }
    finally { Write-Progress -Id 41 -Activity $Activity -Completed }
}

function Invoke-InstallStep {
    param([string]$Description, [scriptblock]$Action)
    Write-Host ''
    Write-InstallLogAction -Message "$Description..."
    $errorsBefore = @($script:installLogActions | Where-Object Level -eq 'Error').Count
    & $Action
    if (@($script:installLogActions | Where-Object Level -eq 'Error').Count -gt $errorsBefore) {
        Write-InstallLogAction -Message "$Description finished with errors. Review the messages above." -Level Warning
    }
    else { Write-InstallLogAction -Message "Completed: $Description." -Level Success }
}

function Initialize-InstallLog {
    param(
        [string]$Title = "WorkIQ Starter Pack Installation Log",
        [string]$FileName = "InstallLog.md",
        [bool]$IncludePasswords = $true,
        [bool]$IncludeTaps = $false,
        [string]$LogDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Logs'))
    )

    $script:installLogTitle = $Title
    $script:installLogIncludePasswords = $IncludePasswords
    $script:installLogIncludeTaps = $IncludeTaps
    $script:installLogStartTime = Get-Date

    # Each run gets its own file (e.g. InstallLog-2026102701.md) so earlier logs, and the passwords in them, are kept
    $logDir = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Logs"))
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $extension = [System.IO.Path]::GetExtension($FileName)
    $datePart = Get-Date -Format "yyyyMMdd"
    $lastRun = 0
    if (Test-Path $logDir) {
        foreach ($existing in Get-ChildItem -Path $logDir -File -Filter "$baseName-$datePart*$extension") {
            if ($existing.Name -match "^$([regex]::Escape($baseName))-$datePart(\d{2,})$([regex]::Escape($extension))$") {
                $lastRun = [Math]::Max($lastRun, [int]$Matches[1])
            }
        }
    }
    $script:installLogPath = Join-Path -Path $logDir -ChildPath ("{0}-{1}{2:00}{3}" -f $baseName, $datePart, ($lastRun + 1), $extension)
    $script:installLogInputs = [System.Collections.Generic.List[object]]::new()
    $script:installLogActions = [System.Collections.Generic.List[object]]::new()
    $script:installLogPasswords = [System.Collections.Generic.List[object]]::new()
    $script:installLogTaps = [System.Collections.Generic.List[object]]::new()
}

function Write-InstallLogInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [Parameter(Mandatory = $true)]
        [string]$Response
    )

    $script:installLogInputs.Add([PSCustomObject]@{ Prompt = $Prompt; Response = $Response })
}

function Write-InstallLogAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $color = switch ($Level) {
        "Success" { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
        default   { $null }
    }

    if ($color) {
        Write-Host $Message -ForegroundColor $color
    }
    else {
        Write-Host $Message
    }

    $script:installLogActions.Add([PSCustomObject]@{ Time = (Get-Date).ToString("HH:mm:ss"); Level = $Level; Message = $Message })
}

function Write-InstallLogPassword {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $script:installLogPasswords.Add([PSCustomObject]@{ Email = $Email; Password = $Password })
}

function Write-InstallLogTap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Email,
        [Parameter(Mandatory = $true)]
        [string]$TemporaryAccessPass,
        [Parameter(Mandatory = $true)]
        [datetime]$ExpiresAt,
        [Parameter(Mandatory = $true)]
        [bool]$IsUsableOnce
    )

    $script:installLogTaps.Add([PSCustomObject]@{ Email = $Email; Tap = $TemporaryAccessPass; ExpiresAt = $ExpiresAt; IsUsableOnce = $IsUsableOnce })
}

function Save-InstallLog {
    param(
        [bool]$Success = $true
    )

    if (-not $script:installLogPath) {
        return
    }

    $logDir = Split-Path -Path $script:installLogPath -Parent
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $endTime = Get-Date
    $status = if ($Success) { "Succeeded" } else { "Failed" }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# $($script:installLogTitle)")
    $lines.Add("")
    $lines.Add("## Run Summary")
    $lines.Add("- Started: $($script:installLogStartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("- Finished: $($endTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    $lines.Add("- Status: $status")
    $lines.Add("")

    $lines.Add("## User Inputs")
    $lines.Add("")
    if ($script:installLogInputs.Count -gt 0) {
        $lines.Add("| Prompt | Response |")
        $lines.Add("|---|---|")
        foreach ($entry in $script:installLogInputs) {
            $lines.Add("| $($entry.Prompt) | $($entry.Response) |")
        }
    }
    else {
        $lines.Add("_No inputs recorded._")
    }
    $lines.Add("")

    $lines.Add("## Actions Taken")
    $lines.Add("")
    if ($script:installLogActions.Count -gt 0) {
        foreach ($entry in $script:installLogActions) {
            $lines.Add("- [$($entry.Time)] $($entry.Message)")
        }
    }
    else {
        $lines.Add("_No actions recorded._")
    }
    $lines.Add("")

    if ($script:installLogIncludePasswords) {
        $lines.Add("## Demo User Passwords")
        $lines.Add("")
        if ($script:installLogPasswords.Count -gt 0) {
            $lines.Add("**Store this information securely and delete this file once the passwords have been distributed.**")
            $lines.Add("")
            $lines.Add("| Email | Temporary Password |")
            $lines.Add("|---|---|")
            foreach ($entry in $script:installLogPasswords) {
                $lines.Add("| $($entry.Email) | $($entry.Password) |")
            }
        }
        else {
            $lines.Add("_No new users were created in this run._")
        }
        $lines.Add("")
    }

    if ($script:installLogIncludeTaps) {
        $lines.Add("## Temporary Access Passes")
        $lines.Add("")
        if ($script:installLogTaps.Count -gt 0) {
            $lines.Add("**Store this information securely and delete this file once the codes have been distributed.** Each code can only be shown once.")
            $lines.Add("")
            $lines.Add("| Email | Temporary Access Pass | Expires (UTC) | Use |")
            $lines.Add("|---|---|---|---|")
            foreach ($entry in $script:installLogTaps) {
                $use = if ($entry.IsUsableOnce) { 'Single use' } else { 'Multi use' }
                $lines.Add("| $($entry.Email) | $($entry.Tap) | $($entry.ExpiresAt.ToString('yyyy-MM-dd HH:mm')) | $use |")
            }
        }
        else {
            $lines.Add("_No Temporary Access Passes were issued in this run._")
        }
        $lines.Add("")
    }

    Set-Content -LiteralPath $script:installLogPath -Value ($lines -join "`n")
}

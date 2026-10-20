param([scriptblock]$AccessTokenProvider)

function Initialize-DynamicsIdentityMap {
    param($Config, $Settings)
    $script:dynamicsIdentityAliases = @{}
    $script:dynamicsUserIds = @{}
    $source = Get-Content (Join-Path $PSScriptRoot '../../Configuration/settings.json') -Raw | ConvertFrom-Json
    for ($i=0; $i -lt $source.Users.Count; $i++) {
        $demoEmail = $source.Users[$i].Email.Replace('<TENANTPREFIX>', $Config.Settings.TenantPrefix)
        $script:dynamicsIdentityAliases[$demoEmail] = $Settings.Users[$i].Email
    }
    $script:dynamicsTenantPrefix = $Config.Settings.TenantPrefix
}

function Resolve-DynamicsUserUpn {
    param([Parameter(Mandatory = $true)][string]$Email)
    $upn = $Email.Replace('<TENANTPREFIX>', [string]$script:dynamicsTenantPrefix)
    if ($script:dynamicsIdentityAliases -and $script:dynamicsIdentityAliases.ContainsKey($upn)) { $upn = $script:dynamicsIdentityAliases[$upn] }
    return $upn.Replace('<TENANTPREFIX>', [string]$script:dynamicsTenantPrefix)
}

function Resolve-DynamicsUserId {
    param($Context, [Parameter(Mandatory = $true)][string]$Email)
    $upn = Resolve-DynamicsUserUpn -Email $Email
    $key = "$($Context.BaseUrl)|$upn"
    if (-not $script:dynamicsUserIds) { $script:dynamicsUserIds = @{} }
    if ($script:dynamicsUserIds.ContainsKey($key)) { return $script:dynamicsUserIds[$key] }
    $literal = $upn.Replace("'","''")
    $filter = [Uri]::EscapeDataString("isdisabled eq false and (domainname eq '$literal' or internalemailaddress eq '$literal')")
    $users = Invoke-RestMethod -Uri "$($Context.BaseUrl)/systemusers?`$select=systemuserid&`$filter=$filter" -Headers $Context.Headers -Method Get -ErrorAction Stop
    if (@($users.value).Count -ne 1) { throw "Expected one enabled Dataverse user for '$upn'; found $(@($users.value).Count)." }
    $id = [Guid]::Parse($users.value[0].systemuserid).ToString()
    $script:dynamicsUserIds[$key] = $id
    return $id
}

function Set-DynamicsDemoOwners {
    param($Config, [string]$ContentPath = (Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    $content = Get-Content $ContentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $context = Get-DynamicsRequestContext -Config $Config
    $sets = @{Accounts='accounts';Contacts='contacts';Leads='leads';Opportunities='opportunities';Quotes='quotes';Orders='salesorders';Invoices='invoices';Incidents='incidents';Emails='emails';FieldEngagements='cal_fieldengagements'}
    foreach ($collection in $sets.Keys) {
        foreach ($record in $content.$collection) {
            if (-not $record.Owner) { continue }
            $id = [Guid]::Parse($record.Id).ToString()
            $ownerId = Resolve-DynamicsUserId -Context $context -Email $record.Owner
            $uri = "$($context.BaseUrl)/$($sets[$collection])($id)"
            $existing = Invoke-RestMethod -Uri "$($uri)?`$select=_ownerid_value" -Headers $context.Headers -Method Get -ErrorAction Stop
            if ($existing._ownerid_value -eq $ownerId) { continue }
            $body = @{'ownerid@odata.bind'="/systemusers($ownerId)"} | ConvertTo-Json
            $requestHeaders = $context.Headers.Clone(); $requestHeaders['If-Match']='*'
            Invoke-RestMethod -Uri $uri -Headers $requestHeaders -Method Patch -ContentType 'application/json' -Body $body -ErrorAction Stop | Out-Null
            $ownerUpn = Resolve-DynamicsUserUpn -Email $record.Owner
            Write-InstallLogAction -Message "Assigned $collection record '$id' to '$ownerUpn'." -Level Success
        }
    }
}

function New-DynamicsEmailParty {
    param($Context, $Participant, [int]$Mask)
    $address = if ($Participant -is [string]) { $Participant } else { $Participant.Email }
    if ([string]::IsNullOrWhiteSpace($address)) { throw 'Email participant requires an Email address.' }
    if ($Participant -isnot [string] -and $Participant.ContactId) {
        return @{participationtypemask=$Mask;'partyid_contact@odata.bind'="/contacts($([Guid]::Parse($Participant.ContactId)))";addressused=$address}
    }
    $userId = Resolve-DynamicsUserId -Context $Context -Email $address
    return @{participationtypemask=$Mask;'partyid_systemuser@odata.bind'="/systemusers($userId)"}
}

function Invoke-DynamicsSolutionRequest {
    param([Parameter(Mandatory = $true)][string]$Step,
        [Parameter(Mandatory = $true)][hashtable]$Request)
    try { Invoke-RestMethod @Request -ErrorAction Stop }
    catch {
        $details = $_.ErrorDetails.Message
        if ([string]::IsNullOrWhiteSpace($details) -and $_.Exception.Response.Content) {
            try { $details = $_.Exception.Response.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        }
        throw "D365 Sales & CS solution step '$Step' failed: $($_.Exception.Message) Dataverse response: $details"
    }
}

function Install-DynamicsFieldEngagementSolution {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$SolutionPath = (Join-Path $PSScriptRoot '../../Content/DataverseSolutions/CaldovaFieldEngagamentSolution_1_0_0_0_managed.zip'))
    $SolutionPath = [IO.Path]::GetFullPath($SolutionPath)
    Write-Host "Checking solution ZIP file: $SolutionPath"
    if (-not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
        throw "Solution ZIP file was not found: '$SolutionPath'. Restore the managed solution ZIP in Content/DataverseSolutions before running installation."
    }
    Write-InstallLogAction -Message "Solution ZIP file found: '$SolutionPath'."
    # Read the actual unique name from the package, including its original spelling.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($SolutionPath))
    try {
        $reader = [IO.StreamReader]::new($zip.GetEntry('solution.xml').Open())
        try { [xml]$manifest = $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
    $name = [string]$manifest.ImportExportXml.SolutionManifest.UniqueName
    if ([string]::IsNullOrWhiteSpace($name)) { throw 'Solution package has no unique name.' }
    $context = Get-DynamicsRequestContext -Config $Config
    $filter = [Uri]::EscapeDataString("uniquename eq '$($name.Replace("'","''"))'")
    $solutionUrl = "$($context.BaseUrl)/solutions?`$select=solutionid,uniquename,version&`$filter=$filter"
    Write-InstallLogAction -Message "Checking whether D365 Sales & CS solution '$name' is installed..."
    $found = Invoke-DynamicsSolutionRequest -Step 'Check installed solution' -Request @{Uri=$solutionUrl;Headers=$context.Headers;Method='Get'}
    if (@($found.value).Count) {
        $message = "Solution '$name' is installed (version $($found.value[0].version)); skipping import."
        Write-InstallLogAction -Message $message
        return
    }
    $message = "Solution '$name' was not found. Installing managed solution from '$SolutionPath'..."
    Write-InstallLogAction -Message $message
    $jobId = [Guid]::NewGuid().ToString()
    $body = @{
        CustomizationFile = [Convert]::ToBase64String([IO.File]::ReadAllBytes([IO.Path]::GetFullPath($SolutionPath)))
        ImportJobId = $jobId; OverwriteUnmanagedCustomizations = $false; PublishWorkflows = $true
        # Omit ComponentParameters when there are no component overrides.
        # An empty crmbaseentity collection can fail Dataverse deserialization.
    } | ConvertTo-Json -Depth 5
    $synchronousImport = $false
    try {
        $result = Invoke-DynamicsSolutionRequest -Step 'Submit ImportSolutionAsync' -Request @{
        Uri="$($context.BaseUrl)/ImportSolutionAsync";Headers=$context.Headers;Method='Post'
        ContentType='application/json; charset=utf-8';Body=[Text.Encoding]::UTF8.GetBytes($body)
        }
    }
    catch {
        # Retry only an explicitly rejected async submission, never an ambiguous failure.
        if ($_.Exception.Message -notmatch '0x80040315') { throw }
        Write-InstallLogAction -Message 'Async operations are disabled in this organization. Importing the solution synchronously; this may take several minutes.' -Level Warning
        Invoke-DynamicsSolutionRequest -Step 'Submit ImportSolution' -Request @{
            Uri="$($context.BaseUrl)/ImportSolution";Headers=$context.Headers;Method='Post'
            ContentType='application/json; charset=utf-8';Body=[Text.Encoding]::UTF8.GetBytes($body)
            TimeoutSec=1800
        } | Out-Null
        $synchronousImport = $true
    }
    if (-not $synchronousImport) {
    if ($result.ImportJobKey) { $jobId = [Guid]::Parse($result.ImportJobKey).ToString() }
    if (-not $result.AsyncOperationId) { throw 'ImportSolutionAsync returned no AsyncOperationId; demo provisioning has been stopped.' }
    $asyncId = [Guid]::Parse($result.AsyncOperationId).ToString()
    $message = "Solution import started. Async job: $asyncId; import job: $jobId. Checking progress every 30 seconds."
    Write-InstallLogAction -Message $message
    try {
    do {
        Wait-InstallPollingInterval -Activity 'Waiting for D365 Sales & CS Solution Import' -Seconds 30
        # Refresh the token during long imports.
        $context = Get-DynamicsRequestContext -Config $Config
        $job = Invoke-DynamicsSolutionRequest -Step "Monitor async job $asyncId" -Request @{
            Uri="$($context.BaseUrl)/asyncoperations($asyncId)?`$select=statecode,statuscode,message,friendlymessage";Headers=$context.Headers;Method='Get'
        }
        $progress = 'not yet available'
        $importPercent = -1
        try {
            $import = Invoke-RestMethod -Uri "$($context.BaseUrl)/importjobs($jobId)?`$select=progress" -Headers $context.Headers -Method Get -ErrorAction Stop
            $progress = "$($import.progress)%"
            $importPercent = [int][Math]::Min(100, [Math]::Max(0, [double]$import.progress))
        } catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw "Failed to retrieve import job ${jobId}: $($_.Exception.Message) $($_.ErrorDetails.Message)" } }
        $statusLabels = @{0='Waiting for resources';10='Waiting';20='In progress';21='Pausing';22='Canceling';30='Succeeded';31='Failed';32='Canceled'}
        $statusLabel = $statusLabels[[int]$job.statuscode]
        Write-Progress -Id 40 -Activity "Installing D365 Sales & CS Solution '$name'" -Status "$progress; $statusLabel" -PercentComplete $importPercent
        $message = "Solution '$name' import progress: $progress; $statusLabel (status $($job.statuscode))."
        Write-InstallLogAction -Message $message
    } while ([int]$job.statecode -ne 3)
    } finally { Write-Progress -Id 40 -Activity "Installing D365 Sales & CS Solution '$name'" -Completed }
    if ([int]$job.statuscode -ne 30) { throw "Solution '$name' import failed or was canceled (job $asyncId): $($job.message) $($job.friendlymessage)" }
    }
    $context = Get-DynamicsRequestContext -Config $Config
    $found = Invoke-DynamicsSolutionRequest -Step 'Verify imported solution' -Request @{Uri=$solutionUrl;Headers=$context.Headers;Method='Get'}
    if (-not @($found.value).Count) { throw "Import job succeeded but solution '$name' could not be found." }
    Write-InstallLogAction -Message "Solution '$name' installation completed successfully. Starting D365 Sales & CS demo data provisioning." -Level Success
}

function Remove-DynamicsFieldEngagementSolution {
    param([Parameter(Mandatory = $true)]$Config,
        [ValidateRange(1, 240)][int]$TimeoutMinutes = 30)
    $name = 'CaldovaFieldEngagamentSolution'
    $context = Get-DynamicsRequestContext -Config $Config
    Write-Host "Checking D365 Sales & CS solution '$name' for removal..."
    $filter = [Uri]::EscapeDataString("uniquename eq '$name'")
    $response = Invoke-RestMethod -Uri "$($context.BaseUrl)/solutions?`$select=solutionid&`$filter=$filter" -Headers $context.Headers -Method Get -ErrorAction Stop
    $solutions = @($response.value)
    if (-not $solutions.Count) {
        Write-InstallLogAction -Message "Solution '$name' is not installed; skipping removal."
        return
    }
    if ($solutions.Count -ne 1) { throw "Expected exactly one solution named '$name'." }
    $id = [Guid]::Parse($solutions[0].solutionid).ToString()
    Write-Host "Removing D365 Sales & CS solution '$name'..."
    $result = Invoke-RestMethod -Uri "$($context.BaseUrl)/UninstallSolutionAsync" -Headers $context.Headers -Method Post `
        -ContentType 'application/json' -Body (@{ SolutionUniqueName = $name } | ConvertTo-Json) -ErrorAction Stop
    if (-not $result.AsyncOperationId) { throw 'Solution uninstall returned no async job ID. Check the solution history before retrying.' }
    $asyncId = [guid]::Parse($result.AsyncOperationId).ToString()
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    Write-InstallLogAction -Message "Solution uninstall started (job $asyncId). Checking every 30 seconds..."
    try {
        do {
            if ([DateTime]::UtcNow -ge $deadline) { throw "Solution uninstall timed out after $TimeoutMinutes minutes. Job $asyncId may still be running; check solution history before retrying." }
            $context = Get-DynamicsRequestContext -Config $Config
            $job = Invoke-RestMethod -Uri "$($context.BaseUrl)/asyncoperations($asyncId)?`$select=statecode,statuscode,message,friendlymessage" -Headers $context.Headers -Method Get -ErrorAction Stop
            $labels = @{ 0='Waiting for Resources'; 10='Waiting'; 20='In Progress'; 21='Pausing'; 22='Canceling'; 30='Succeeded'; 31='Failed'; 32='Canceled' }
            $status = $labels[[int]$job.statuscode]
            if (-not $status) { $status = "Status $($job.statuscode)" }
            Write-Progress -Id 42 -Activity 'Uninstalling the Caldova Field Engagement Solution' -Status $status -PercentComplete -1
            Write-InstallLogAction -Message "Solution '$name' uninstall: $status."
            if ([int]$job.statecode -eq 3) {
                if ([int]$job.statuscode -ne 30) { throw "Solution uninstall failed or was canceled (job ${asyncId}): $($job.message) $($job.friendlymessage)" }
                break
            }
            Wait-InstallPollingInterval -Activity 'Waiting for Solution Uninstall' -Seconds 30
        } while ($true)
        # Verify the solution itself is gone before reporting success.
        do {
            $context = Get-DynamicsRequestContext -Config $Config
            $remaining = Invoke-RestMethod -Uri "$($context.BaseUrl)/solutions?`$select=solutionid&`$filter=$filter" -Headers $context.Headers -Method Get -ErrorAction Stop
            if (-not @($remaining.value).Count) { break }
            if ([DateTime]::UtcNow -ge $deadline) { throw "Uninstall job $asyncId succeeded, but solution '$name' is still present after $TimeoutMinutes minutes." }
            Wait-InstallPollingInterval -Activity 'Verifying Solution Removal' -Seconds 30
        } while ($true)
    }
    finally { Write-Progress -Id 42 -Activity 'Uninstalling the Caldova Field Engagement Solution' -Completed }
    Write-InstallLogAction -Message "Solution '$name' removed successfully." -Level Success
}

function Add-DynamicsFieldEngagements {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = (Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    Write-Host 'Creating D365 Sales & CS Field Engagement demo records...'
    foreach ($engagement in $content.FieldEngagements) {
        try {
            $id = [Guid]::Parse($engagement.Id)
            $accountId = [Guid]::Parse($engagement.AccountId).ToString()
            $contactId = [Guid]::Parse($engagement.ContactId).ToString()
            if (-not @($content.Accounts | Where-Object Id -eq $accountId).Count -or
                -not @($content.Contacts | Where-Object { $_.Id -eq $contactId -and $_.AccountId -eq $accountId }).Count) { throw 'Invalid engagement account/contact references.' }
            if ([string]::IsNullOrWhiteSpace($engagement.Name)) { throw 'Engagement Name is required.' }
            foreach ($choice in @(@('Priority',2),@('Type',6),@('CurrentStatus',4))) {
                $value = $engagement.($choice[0])
                if ($null -eq $value -or "$value" -notmatch '^\d+$' -or [int]$value -gt $choice[1]) { throw "Invalid engagement choice '$($choice[0])'." }
            }
            $body = @{cal_name=$engagement.Name;cal_description=$engagement.Description
                cal_priority=[int]$engagement.Priority;cal_type=[int]$engagement.Type;cal_currentstatus=[int]$engagement.CurrentStatus
                'cal_accountid@odata.bind'="/accounts($accountId)"; 'cal_contactid@odata.bind'="/contacts($contactId)"}
            if ($engagement.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $engagement.Owner))" }
            if ($null -ne $engagement.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$engagement.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet cal_fieldengagements -Id $id -Body $body
        } catch {
            $failed++
            Write-InstallLogAction -Message "Failed to create Field Engagement '$($engagement.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Failed to create $failed Field Engagement record(s)." }
}

function Remove-DynamicsFieldEngagements {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = (Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $ids = @($content.FieldEngagements | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id).ToString() })
    if (-not $ids.Count) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    foreach ($id in $ids) {
        try {
            Invoke-RestMethod -Uri "$($context.BaseUrl)/cal_fieldengagements($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted Field Engagement '$id'." -Level Success
        } catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw } }
    }
}

function Remove-DynamicsLeads {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "DynamicsEnvironmentUrl must be an HTTPS environment root URL."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # Validate every ID before issuing any delete requests.
    $leadIds = @($content.Leads | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id).ToString() } | Select-Object -Unique)
    if ($leadIds.Count -eq 0) {
        Write-InstallLogAction -Message "No D365 Sales & CS Lead IDs found in $ContentPath."
        return
    }
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
    $dynamicsHeaders = @{
        Authorization = "Bearer $token"
        Accept = "application/json"
        'OData-MaxVersion' = "4.0"
        'OData-Version' = "4.0"
    }
    $failed = 0
    foreach ($leadId in $leadIds) {
        try {
            Invoke-RestMethod -Uri "$environmentUrl/api/data/v9.2/leads($leadId)" -Headers $dynamicsHeaders -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS Lead $leadId." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                continue
            }
            $failed++
            $message = "Failed to delete D365 Sales & CS Lead ${leadId}: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
    if ($failed -gt 0) {
        throw "Could not delete $failed D365 Sales & CS Lead(s). Review the cleanup log."
    }
}

function Remove-DynamicsAccounts {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "DynamicsEnvironmentUrl must be an HTTPS environment root URL."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # Validate every ID before issuing any delete requests.
    $accountIds = @($content.Accounts | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id).ToString() } | Select-Object -Unique)
    if ($accountIds.Count -eq 0) {
        Write-InstallLogAction -Message "No D365 Sales & CS Account IDs found in $ContentPath."
        return
    }
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
    $dynamicsHeaders = @{
        Authorization = "Bearer $token"
        Accept = "application/json"
        'OData-MaxVersion' = "4.0"
        'OData-Version' = "4.0"
    }
    $failed = 0
    foreach ($accountId in $accountIds) {
        try {
            Invoke-RestMethod -Uri "$environmentUrl/api/data/v9.2/accounts($accountId)" -Headers $dynamicsHeaders -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS Account $accountId." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                continue
            }
            $failed++
            $message = "Failed to delete D365 Sales & CS Account ${accountId}: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
    if ($failed -gt 0) {
        throw "Could not delete $failed D365 Sales & CS Account(s). Review the cleanup log."
    }
}

function Add-DynamicsAccounts {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "DynamicsEnvironmentUrl must be an HTTPS environment root URL."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $accounts = @($content.Accounts | Where-Object { $_ })
    if ($accounts.Count -eq 0) {
        Write-InstallLogAction -Message "No D365 Sales & CS Accounts found in $ContentPath."
        return
    }
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
    $dynamicsHeaders = @{
        Authorization = "Bearer $token"
        Accept = "application/json"
        'OData-MaxVersion' = "4.0"
        'OData-Version' = "4.0"
        'If-None-Match' = '*'
    }

    foreach ($account in $accounts) {
        try {
            $accountId = [Guid]::Parse($account.Id).ToString()
            if ([string]::IsNullOrWhiteSpace($account.Name)) {
                throw "An Account requires Name."
            }
            $body = @{
                name                  = $account.Name
                accountnumber         = $account.AccountNumber
                description           = $account.Description
                websiteurl            = $account.Website
                telephone1            = $account.Phone
                address1_city         = $account.City
                address1_stateorprovince = $account.State
                address1_country      = $account.Country
            }
            if ($null -ne $account.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$account.CreatedOffset).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            # PrimaryContactId is deferred until contacts are provisioned.
            if ($account.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context @{BaseUrl="$environmentUrl/api/data/v9.2";Headers=$dynamicsHeaders} -Email $account.Owner))" }
            # Industry is also
            # omitted because the demo label Healthcare is not a standard choice.
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/api/data/v9.2/accounts($accountId)" -Headers $dynamicsHeaders -Method Patch `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created D365 Sales & CS Account '$($account.Name)' ($accountId)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 412) {
                Write-InstallLogAction -Message "D365 Sales & CS Account '$($account.Name)' already exists, skipping creation."
                continue
            }
            $message = "Failed to create D365 Sales & CS Account '$($account.Name)': $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
}

function Get-DynamicsRequestContext {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "DynamicsEnvironmentUrl must be an HTTPS environment root URL."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
    return @{
        BaseUrl = "$environmentUrl/api/data/v9.2"
        Headers = @{
            Authorization = "Bearer $token"
            Accept = "application/json"
            'OData-MaxVersion' = "4.0"
            'OData-Version' = "4.0"
        }
    }
}

function Add-DynamicsContacts {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $contacts = @($content.Contacts | Where-Object { $_ })
    if ($contacts.Count -eq 0) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $context.Headers['If-None-Match'] = '*'
    foreach ($contact in $contacts) {
        try {
            $contactId = [Guid]::Parse($contact.Id).ToString()
            if ([string]::IsNullOrWhiteSpace($contact.LastName)) { throw "A Contact requires LastName." }
            $body = @{
                firstname = $contact.FirstName
                lastname = $contact.LastName
                jobtitle = $contact.JobTitle
                emailaddress1 = $contact.Email
                telephone1 = $contact.Phone
                description = $contact.Description
            }
            if ($contact.AccountId) {
                $accountId = [Guid]::Parse($contact.AccountId).ToString()
                $body['parentcustomerid_account@odata.bind'] = "/accounts($accountId)"
            }
            if ($null -ne $contact.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$contact.CreatedOffset).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            if ($contact.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $contact.Owner))" }
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$($context.BaseUrl)/contacts($contactId)" -Headers $context.Headers -Method Patch `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created D365 Sales & CS Contact '$($contact.FirstName) $($contact.LastName)' ($contactId)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 412) {
                Write-InstallLogAction -Message "D365 Sales & CS Contact '$($contact.FirstName) $($contact.LastName)' already exists, skipping creation."
                continue
            }
            $message = "Failed to create D365 Sales & CS Contact '$($contact.FirstName) $($contact.LastName)': $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
}

function Update-DynamicsAccountPrimaryContacts {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $accounts = @($content.Accounts | Where-Object { $_.PrimaryContactId })
    if ($accounts.Count -eq 0) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    # Update only: never create a partial account if account provisioning failed.
    $context.Headers['If-Match'] = '*'
    foreach ($account in $accounts) {
        try {
            $accountId = [Guid]::Parse($account.Id).ToString()
            $contactId = [Guid]::Parse($account.PrimaryContactId).ToString()
            $contact = @($content.Contacts | Where-Object { $_.Id -eq $contactId -and $_.AccountId -eq $accountId })
            if ($contact.Count -ne 1) { throw "PrimaryContactId must reference a demo Contact belonging to this Account." }
            $json = @{ 'primarycontactid@odata.bind' = "/contacts($contactId)" } | ConvertTo-Json
            Invoke-RestMethod -Uri "$($context.BaseUrl)/accounts($accountId)" -Headers $context.Headers -Method Patch `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Set primary Contact $contactId on D365 Sales & CS Account '$($account.Name)'." -Level Success
        }
        catch {
            $message = "Failed to set primary Contact on D365 Sales & CS Account '$($account.Name)': $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
}

function Get-DynamicsTableDisplayName {
    param([Parameter(Mandatory = $true)][string]$EntitySet)
    $names = @{
        products = 'Products'; uoms = 'Units'; uomschedules = 'Unit Groups'
        pricelevels = 'Price Lists'; productpricelevels = 'Price List Items'
        accounts = 'Accounts'; contacts = 'Contacts'; leads = 'Leads'
        opportunities = 'Opportunities'; opportunityproducts = 'Opportunity Products'
        quotes = 'Quotes'; quotedetails = 'Quote Products'
        salesorders = 'Orders'; salesorderdetails = 'Order Products'
        invoices = 'Invoices'; invoicedetails = 'Invoice Products'
        incidents = 'Cases'; emails = 'Email Messages'
        cal_fieldengagements = 'Field Engagements'
    }
    if ($names.ContainsKey($EntitySet)) { return $names[$EntitySet] }
    return $EntitySet
}

function Invoke-DynamicsCreateRecord {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)][string]$EntitySet,
        [Parameter(Mandatory = $true)][Guid]$Id,
        [Parameter(Mandatory = $true)][hashtable]$Body
    )
    $requestHeaders = $Context.Headers.Clone()
    $requestHeaders['If-None-Match'] = '*'
    # Some Sales validators run before the create-only precondition check.
    # Read first to avoid duplicate-name and read-only-parent errors on reruns.
    try {
        Invoke-RestMethod -Uri "$($Context.BaseUrl)/$EntitySet($Id)" -Headers $Context.Headers -Method Get -ErrorAction Stop | Out-Null
        Write-InstallLogAction -Message "D365 Sales & CS $(Get-DynamicsTableDisplayName $EntitySet): record $Id already exists, skipping creation."
        return
    }
    catch {
        if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
    }
    try {
        $json = $Body | ConvertTo-Json -Depth 6
        Invoke-RestMethod -Uri "$($Context.BaseUrl)/$EntitySet($Id)" -Headers $requestHeaders -Method Patch `
            -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
        Write-InstallLogAction -Message "Created D365 Sales & CS $(Get-DynamicsTableDisplayName $EntitySet): record $Id." -Level Success
    }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 412) {
            Write-InstallLogAction -Message "D365 Sales & CS $(Get-DynamicsTableDisplayName $EntitySet): record $Id already exists, skipping creation."
            return
        }
        throw
    }
}

function Get-DynamicsDefaultCurrencyId {
    param(
        [Parameter(Mandatory = $true)]$Context
    )
    $uri = "$($Context.BaseUrl)/organizations?`$select=_basecurrencyid_value&`$top=2"
    $organizations = @((Invoke-RestMethod -Uri $uri -Headers $Context.Headers -Method Get -ErrorAction Stop).value)
    if ($organizations.Count -ne 1 -or [string]::IsNullOrWhiteSpace($organizations[0]._basecurrencyid_value)) {
        throw 'Could not retrieve the D365 Sales & CS environment base currency. Catalog import cannot continue.'
    }
    return [Guid]::Parse($organizations[0]._basecurrencyid_value).ToString()
}

function Add-DynamicsPriceLists {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.PriceLists) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $currencyId = Get-DynamicsDefaultCurrencyId -Context $context
    foreach ($priceList in $content.PriceLists) {
        try {
            if ([string]::IsNullOrWhiteSpace($priceList.Name)) { throw 'A Price List requires Name.' }
            $nameFilter = [Uri]::EscapeDataString("name eq '$($priceList.Name.Replace("'", "''"))'")
            $matches = @((Invoke-RestMethod -Uri "$($context.BaseUrl)/pricelevels?`$select=pricelevelid&`$filter=$nameFilter" -Headers $context.Headers -Method Get -ErrorAction Stop).value)
            if (@($matches | Where-Object { $_.pricelevelid -ne $priceList.Id }).Count) {
                throw "Price List name '$($priceList.Name)' exists under a different GUID ($($matches[0].pricelevelid)); configured GUID is $($priceList.Id). Align the content Price List ID and all references."
            }
            $body = @{
                name = $priceList.Name
                description = $priceList.Description
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
            }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet 'pricelevels' -Id ([Guid]::Parse($priceList.Id)) -Body $body
        }
        catch {
            Write-InstallLogAction -Message "Failed to create D365 Sales & CS Price List '$($priceList.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
}

function Get-DynamicsProductUnit {
    param(
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Content,
        [Parameter(Mandatory = $true)]$Product
    )
    $groupId = [Guid]::Parse($Product.UnitGroupId).ToString()
    $unitId = [Guid]::Parse($Product.UnitId).ToString()
    $groups = @($Content.UnitGroups | Where-Object { $_.Id -eq $groupId })
    $units = @($Content.Units | Where-Object { $_.Id -eq $unitId -and $_.UnitGroupId -eq $groupId })
    if ($groups.Count -ne 1 -or $units.Count -ne 1) {
        throw 'Product must reference a defined Unit and its Unit Group.'
    }
    $group = $groups[0]
    $unit = $units[0]
    # Dynamics generates the base unit; the selling unit has a configured ID.
    Invoke-DynamicsCreateRecord -Context $Context -EntitySet 'uomschedules' -Id $groupId -Body @{
        name = $group.Name; baseuomname = $group.BaseUnitName
    }
    $uri = "$($Context.BaseUrl)/uoms?`$filter=_uomscheduleid_value eq $groupId and isschedulebaseuom eq true&`$select=uomid&`$top=2"
    $baseUnits = @((Invoke-RestMethod -Uri $uri -Headers $Context.Headers -Method Get -ErrorAction Stop).value)
    if ($baseUnits.Count -ne 1) { throw "Could not resolve base Unit for '$($group.Name)'." }
    Invoke-DynamicsCreateRecord -Context $Context -EntitySet 'uoms' -Id $unitId -Body @{
        name = $unit.Name
        quantity = [decimal]$unit.Quantity
        'uomscheduleid@odata.bind' = "/uomschedules($groupId)"
        'baseuom@odata.bind' = "/uoms($($baseUnits[0].uomid))"
    }
    return @{ GroupId = $groupId; UnitId = $unitId }
}
function Add-DynamicsProducts {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.Products) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $currencyId = Get-DynamicsDefaultCurrencyId -Context $context
    $unitCache = @{}
    foreach ($product in $content.Products) {
        try {
            $productId = [Guid]::Parse($product.Id).ToString()
            $priceListId = [Guid]::Parse($product.PriceListId).ToString()
            $priceList = @($content.PriceLists | Where-Object { $_.Id -eq $priceListId })
            if ($priceList.Count -ne 1) { throw 'Product must reference a Price List defined in the content file.' }
            if ([string]::IsNullOrWhiteSpace($product.Name) -or [string]::IsNullOrWhiteSpace($product.ProductNumber)) { throw 'Product requires Name and ProductNumber.' }
            if ([decimal]$product.UnitPrice -lt 0) { throw 'UnitPrice cannot be negative.' }
            # Read first: product validation can report duplicate product numbers before
            # a create-only PATCH returns its expected precondition failure.
            $existing = $null
            try {
                $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)?`$select=statecode,productnumber,_defaultuomid_value,_defaultuomscheduleid_value,_pricelevelid_value" -Headers $context.Headers -Method Get -ErrorAction Stop
            }
            catch {
                if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            }
            if ($existing -and $existing.productnumber -ne $product.ProductNumber) {
                throw "Configured Product GUID belongs to Product number '$($existing.productnumber)'."
            }
            if (-not $existing) {
                $numberFilter = [Uri]::EscapeDataString("productnumber eq '$($product.ProductNumber.Replace("'", "''"))'")
                $matches = @((Invoke-RestMethod -Uri "$($context.BaseUrl)/products?`$select=productid,statecode&`$filter=$numberFilter&`$top=2" -Headers $context.Headers -Method Get -ErrorAction Stop).value)
                if ($matches.Count) {
                    throw "Product number '$($product.ProductNumber)' already exists with GUID '$($matches[0].productid)' (state $($matches[0].statecode)); the content GUID is '$productId'. Align the content IDs and references before importing."
                }
            }
            if (-not $unitCache.ContainsKey($product.UnitId)) {
                $unitCache[$product.UnitId] = Get-DynamicsProductUnit -Context $context -Content $content -Product $product
            }
            $unit = $unitCache[$product.UnitId]
            $body = @{
                name = $product.Name; productnumber = $product.ProductNumber; description = $product.Description
                quantitydecimal = 0; productstructure = 1; statecode = 2; statuscode = 0
                price = [decimal]$product.UnitPrice
                'defaultuomscheduleid@odata.bind' = "/uomschedules($($unit.GroupId))"
                'defaultuomid@odata.bind' = "/uoms($($unit.UnitId))"
                'pricelevelid@odata.bind' = "/pricelevels($priceListId)"
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
            }
            if ($null -ne $product.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$product.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            if (-not $existing) {
                Invoke-DynamicsCreateRecord -Context $context -EntitySet 'products' -Id $productId -Body $body
                $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)?`$select=statecode,_defaultuomid_value,_defaultuomscheduleid_value,_pricelevelid_value" -Headers $context.Headers -Method Get -ErrorAction Stop
            }
            else {
                Write-InstallLogAction -Message "D365 Sales & CS Product '$($product.Name)' already exists (state $($existing.statecode)); reusing it."
            }
            $requestHeaders = $context.Headers.Clone()
            $requestHeaders['If-Match'] = '*'
            # Reconcile catalog records created by earlier imports with generated unit IDs.
            if ($existing._defaultuomid_value -ne $unit.UnitId -or $existing._defaultuomscheduleid_value -ne $unit.GroupId) {
                if ($existing.statecode -eq 0) {
                    throw 'Active Product has different Units than the content file. Revise its Units or align the content before importing.'
                }
                $json = @{
                    'defaultuomscheduleid@odata.bind' = "/uomschedules($($unit.GroupId))"
                    'defaultuomid@odata.bind' = "/uoms($($unit.UnitId))"
                } | ConvertTo-Json
                Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)" -Headers $requestHeaders -Method Patch -ContentType 'application/json' -Body $json -ErrorAction Stop | Out-Null
            }
            $itemBody = @{
                'productid@odata.bind' = "/products($productId)"
                'pricelevelid@odata.bind' = "/pricelevels($priceListId)"
                'uomid@odata.bind' = "/uoms($($unit.UnitId))"
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
                amount = [decimal]$product.UnitPrice; pricingmethodcode = 1; quantitysellingcode = 1
            }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet 'productpricelevels' -Id ([Guid]::Parse($product.PriceListItemId)) -Body $itemBody
            # Existing price list items also need the configured unit on reruns.
            $json = $itemBody | ConvertTo-Json
            Invoke-RestMethod -Uri "$($context.BaseUrl)/productpricelevels($($product.PriceListItemId))" -Headers $requestHeaders -Method Patch -ContentType 'application/json' -Body $json -ErrorAction Stop | Out-Null
            # Set the default after the product is present in this price list.
            $json = @{ 'pricelevelid@odata.bind' = "/pricelevels($priceListId)" } | ConvertTo-Json
            Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)" -Headers $requestHeaders -Method Patch -ContentType 'application/json' -Body $json -ErrorAction Stop | Out-Null
            $verified = Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)?`$select=_pricelevelid_value,_defaultuomid_value,_defaultuomscheduleid_value" -Headers $context.Headers -Method Get -ErrorAction Stop
            if ($verified._pricelevelid_value -ne $priceListId -or $verified._defaultuomid_value -ne $unit.UnitId -or $verified._defaultuomscheduleid_value -ne $unit.GroupId) {
                throw "Product catalog assignment did not persist: Price List '$($verified._pricelevelid_value)', Unit '$($verified._defaultuomid_value)', Unit Group '$($verified._defaultuomscheduleid_value)'."
            }
            if ($existing.statecode -ne 0) {
                $requestHeaders = $context.Headers.Clone()
                $requestHeaders['If-Match'] = '*'
                $json = @{ statecode = 0; statuscode = 1 } | ConvertTo-Json
                Invoke-RestMethod -Uri "$($context.BaseUrl)/products($productId)" -Headers $requestHeaders -Method Patch -ContentType 'application/json' -Body $json -ErrorAction Stop | Out-Null
                Write-InstallLogAction -Message "Published D365 Sales & CS Product '$($product.Name)'." -Level Success
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to provision D365 Sales & CS Product '$($product.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
}

function Remove-DynamicsProductCatalog {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # Validate all IDs before deleting anything; children must be deleted first.
    $records = @(
        foreach ($product in $content.Products) {
            if ($product.PriceListItemId) { @{ EntitySet = 'productpricelevels'; Id = [Guid]::Parse($product.PriceListItemId) } }
        }
        foreach ($product in $content.Products) { @{ EntitySet = 'products'; Id = [Guid]::Parse($product.Id) } }
        foreach ($priceList in $content.PriceLists) { @{ EntitySet = 'pricelevels'; Id = [Guid]::Parse($priceList.Id) } }
        foreach ($unit in $content.Units) { @{ EntitySet = 'uoms'; Id = [Guid]::Parse($unit.Id) } }
        # Deleting the group also removes its automatically generated base unit.
        foreach ($group in $content.UnitGroups) { @{ EntitySet = 'uomschedules'; Id = [Guid]::Parse($group.Id) } }
    )
    if ($records.Count -eq 0) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($record in $records) {
        try {
            Invoke-RestMethod -Uri "$($context.BaseUrl)/$($record.EntitySet)($($record.Id))" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS $(Get-DynamicsTableDisplayName $record.EntitySet) record $($record.Id)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete D365 Sales & CS $(Get-DynamicsTableDisplayName $record.EntitySet) record $($record.Id): $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed -gt 0) { throw "Could not delete $failed Product catalog record(s). Review the cleanup log." }
}

function Add-DynamicsLeads {
    param(
        [Parameter(Mandatory = $true)]
        $Config,
        [string]$ContentPath = [System.IO.Path]::GetFullPath((Join-Path -Path $PSScriptRoot -ChildPath "../../Content/contentDynamics.json"))
    )

    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw "DynamicsEnvironmentUrl must be an HTTPS environment root URL, e.g. https://contoso.crm.dynamics.com."
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $leads = @($content.Leads | Where-Object { $_ })
    if ($leads.Count -eq 0) {
        Write-InstallLogAction -Message "No D365 Sales & CS Leads found in $ContentPath."
        return
    }

    try {
        # Request the environment-specific scope directly. Older PnP versions
        # do not allow -ResourceUrl and -Scopes in the same parameter set.
        $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/user_impersonation" } else { Get-PnPAccessToken -Scopes "$environmentUrl/user_impersonation" -ErrorAction Stop }
    }
    catch {
        throw "Could not obtain a Dataverse token for $environmentUrl. Ensure the app registration has D365 Sales & CS CRM delegated user_impersonation permission with consent and the signed-in user has access to the environment. $($_.Exception.Message)"
    }
    $dynamicsHeaders = @{
        Authorization      = "Bearer $token"
        Accept             = "application/json"
        'OData-MaxVersion' = "4.0"
        'OData-Version'    = "4.0"
        # Create only: an existing GUID returns 412 instead of updating the lead.
        'If-None-Match'    = '*'
    }
    $ratings = @{ Hot = 1; Warm = 2; Cold = 3 }
    $sources = @{
        Advertisement = 1; 'Employee Referral' = 2; 'External Referral' = 3
        'Customer referral' = 3; Partner = 4; 'Public Relations' = 5
        Seminar = 6; 'Trade Show' = 7; Web = 8; 'Word of Mouth' = 9; Other = 10
    }

    foreach ($lead in $leads) {
        try {
            $leadId = [Guid]::Parse($lead.Id).ToString()
            if ([string]::IsNullOrWhiteSpace($lead.Subject) -or [string]::IsNullOrWhiteSpace($lead.LastName)) {
                throw "A Lead requires Subject and LastName."
            }
            if ($lead.Status -and $lead.Status -ne 'Open') {
                throw "Only Open demo Leads are supported at this stage."
            }
            $body = @{
                subject       = $lead.Subject
                firstname     = $lead.FirstName
                lastname      = $lead.LastName
                companyname   = $lead.CompanyName
                emailaddress1 = $lead.Email
                description   = $lead.Description
            }
            if ($lead.Rating) {
                if (-not $ratings.ContainsKey($lead.Rating)) { throw "Unknown Lead rating '$($lead.Rating)'." }
                $body.leadqualitycode = $ratings[$lead.Rating]
            }
            if ($lead.LeadSource) {
                if (-not $sources.ContainsKey($lead.LeadSource)) { throw "Unknown Lead source '$($lead.LeadSource)'." }
                $body.leadsourcecode = $sources[$lead.LeadSource]
            }
            if ($null -ne $lead.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$lead.CreatedOffset).ToString("yyyy-MM-ddTHH:mm:ssZ")
            }
            if ($lead.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context @{BaseUrl="$environmentUrl/api/data/v9.2";Headers=$dynamicsHeaders} -Email $lead.Owner))" }
            # Related account/contact/product records are intentionally
            # omitted: this first import only creates standalone leads.
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/api/data/v9.2/leads($leadId)" -Headers $dynamicsHeaders -Method Patch `
                -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created D365 Sales & CS Lead '$($lead.Subject)' ($leadId)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 412) {
                Write-InstallLogAction -Message "D365 Sales & CS Lead '$($lead.Subject)' already exists, skipping creation."
                continue
            }
            $message = "Failed to create D365 Sales & CS Lead '$($lead.Subject)': $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { $message += " Dataverse response: $($_.ErrorDetails.Message)" }
            Write-InstallLogAction -Message $message -Level Error
        }
    }
}

function Add-DynamicsOpportunities {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.Opportunities) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $currencyId = Get-DynamicsDefaultCurrencyId -Context $context
    foreach ($opportunity in $content.Opportunities) {
        try {
            if ($opportunity.Status -notin @('Open', 'Won', 'Lost')) { throw 'Supported Opportunity statuses are Open, Won, and Lost.' }
            $id = [Guid]::Parse($opportunity.Id).ToString()
            $accountId = [Guid]::Parse($opportunity.AccountId).ToString()
            $contactId = [Guid]::Parse($opportunity.ContactId).ToString()
            if (@($content.Contacts | Where-Object { $_.Id -eq $contactId -and $_.AccountId -eq $accountId }).Count -ne 1) {
                throw 'Opportunity Contact must belong to its Account.'
            }
            $body = @{
                name = $opportunity.Name
                description = $opportunity.Description
                'customerid_account@odata.bind' = "/accounts($accountId)"
                'parentaccountid@odata.bind' = "/accounts($accountId)"
                'parentcontactid@odata.bind' = "/contacts($contactId)"
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
                'pricelevelid@odata.bind' = "/pricelevels($([Guid]::Parse($opportunity.PriceListId)))"
                isrevenuesystemcalculated = $false
                estimatedvalue = [decimal]$opportunity.EstimatedRevenue
                closeprobability = [int]$opportunity.Probability
                statecode = 0
                statuscode = 1
            }
            if ($null -ne $opportunity.CreatedOffset) {
                $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$opportunity.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ')
            }
            if ($null -ne $opportunity.EstimatedCloseOffset) {
                $body.estimatedclosedate = (Get-Date).ToUniversalTime().AddDays([int]$opportunity.EstimatedCloseOffset).ToString('yyyy-MM-dd')
            }
            if ($opportunity.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $opportunity.Owner))" }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet 'opportunities' -Id $id -Body $body
            Add-DynamicsSalesLines -Context $context -Content $content -Record $opportunity -EntitySet opportunities -CurrencyId $currencyId
            if ($opportunity.Status -in @('Won', 'Lost')) {
                $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/opportunities($id)?`$select=statecode" -Headers $context.Headers -Method Get -ErrorAction Stop
                if ($existing.statecode -eq 0) {
                    $close = @{
                        'opportunityid@odata.bind' = "/opportunities($id)"
                        subject = $opportunity.Name
                        actualrevenue = [decimal]$opportunity.ActualRevenue
                    }
                    if ($null -ne $opportunity.ActualCloseOffset) {
                        $close.actualend = (Get-Date).ToUniversalTime().AddDays([int]$opportunity.ActualCloseOffset).ToString('yyyy-MM-ddTHH:mm:ssZ')
                    }
                    $json = @{ OpportunityClose = $close; Status = -1 } | ConvertTo-Json -Depth 6
                    $action = if ($opportunity.Status -eq 'Won') { 'WinOpportunity' } else { 'LoseOpportunity' }
                    Invoke-RestMethod -Uri "$($context.BaseUrl)/$action" -Headers $context.Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
                    Write-InstallLogAction -Message "Closed D365 Sales & CS Opportunity '$($opportunity.Name)' as $($opportunity.Status.ToLowerInvariant())." -Level Success
                }
            }
        }
        catch {
            Write-InstallLogAction -Message "Failed to provision D365 Sales & CS Opportunity '$($opportunity.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
}

function Remove-DynamicsOpportunities {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content -Path $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ids = @($content.Opportunities | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id).ToString() } | Select-Object -Unique)
    if (-not $ids.Count) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($id in $ids) {
        try {
            Invoke-RestMethod -Uri "$($context.BaseUrl)/opportunities($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS Opportunity $id." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete D365 Sales & CS Opportunity ${id}: $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed Opportunity record(s). Review the cleanup log." }
}
function Add-DynamicsSalesLines {
    param($Context, $Content, $Record, [string]$EntitySet, [string]$CurrencyId)
    $mapping = @{
        opportunities = @{ Details = 'opportunityproducts'; Lookup = 'opportunityid' }
        quotes = @{ Details = 'quotedetails'; Lookup = 'quoteid' }
        salesorders = @{ Details = 'salesorderdetails'; Lookup = 'salesorderid' }
        invoices = @{ Details = 'invoicedetails'; Lookup = 'invoiceid' }
    }
    $map = $mapping[$EntitySet]
    if (-not $map) { throw "Unsupported sales table $EntitySet." }
    foreach ($line in $Record.Lines) {
        $lineId = [Guid]::Parse($line.Id)
        try {
            Invoke-RestMethod -Uri "$($Context.BaseUrl)/$($map.Details)($lineId)" -Headers $Context.Headers -Method Get -ErrorAction Stop | Out-Null
            continue
        }
        catch {
            if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
        }
        $parent = Invoke-RestMethod -Uri "$($Context.BaseUrl)/$EntitySet($($Record.Id))?`$select=statecode" -Headers $Context.Headers -Method Get -ErrorAction Stop
        if ($parent.statecode -ne 0) { throw "Missing line $lineId cannot be added to closed/read-only $EntitySet record $($Record.Id)." }
        $product = @($Content.Products | Where-Object Id -eq $line.ProductId)
        if ($product.Count -ne 1 -or $product[0].UnitId -ne $line.UnitId) { throw 'Invalid product/unit in sales line.' }
        $productUri = "$($Context.BaseUrl)/products($($line.ProductId))"
        $catalogProduct = Invoke-RestMethod -Uri "$productUri`?`$select=statecode" -Headers $Context.Headers -Method Get -ErrorAction Stop
        if ($catalogProduct.statecode -eq 2) {
            $headers = $Context.Headers.Clone(); $headers['If-Match'] = '*'
            $json = @{statecode=0;statuscode=1} | ConvertTo-Json
            Invoke-RestMethod -Uri $productUri -Headers $headers -Method Patch -ContentType application/json -Body $json -ErrorAction Stop | Out-Null
            $catalogProduct = Invoke-RestMethod -Uri "$productUri`?`$select=statecode" -Headers $Context.Headers -Method Get -ErrorAction Stop
        }
        if ($catalogProduct.statecode -ne 0) { throw "Product '$($product[0].Name)' is not active (state $($catalogProduct.statecode)). Review the catalog import errors." }
        $body = @{
            'productid@odata.bind' = "/products($([Guid]::Parse($line.ProductId)))"
            'uomid@odata.bind' = "/uoms($([Guid]::Parse($line.UnitId)))"
            'transactioncurrencyid@odata.bind' = "/transactioncurrencies($CurrencyId)"
            quantity = [decimal]$line.Quantity
            priceperunit = [decimal]$line.UnitPrice
            isproductoverridden = $false
            ispriceoverridden = $true
            tax = 0
            manualdiscountamount = 0
        }
        $body[$map.Lookup + '@odata.bind'] = "/$EntitySet($([Guid]::Parse($Record.Id)))"
        Invoke-DynamicsCreateRecord -Context $Context -EntitySet $map.Details -Id ([Guid]::Parse($line.Id)) -Body $body
    }
}

function Add-DynamicsQuotes {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.Quotes) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $currencyId = Get-DynamicsDefaultCurrencyId -Context $context
    foreach ($quote in $content.Quotes) {
        try {
            if ($quote.Status -notin @('Draft', 'Active', 'Won')) { throw 'Unsupported Quote status.' }
            $id = [Guid]::Parse($quote.Id).ToString()
            $body = @{
                name = $quote.Name; quotenumber = $quote.QuoteNumber; description = $quote.Description
                'customerid_account@odata.bind' = "/accounts($([Guid]::Parse($quote.AccountId)))"
                'opportunityid@odata.bind' = "/opportunities($([Guid]::Parse($quote.OpportunityId)))"
                'pricelevelid@odata.bind' = "/pricelevels($([Guid]::Parse($quote.PriceListId)))"
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
                statecode = 0; statuscode = 1
            }
            if ($null -ne $quote.CreatedOffset) { $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$quote.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
            if ($null -ne $quote.ValidUntilOffset) { $body.effectiveto = (Get-Date).ToUniversalTime().AddDays([int]$quote.ValidUntilOffset).ToString('yyyy-MM-dd') }
            if ($quote.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $quote.Owner))" }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet quotes -Id $id -Body $body
            Add-DynamicsSalesLines -Context $context -Content $content -Record $quote -EntitySet quotes -CurrencyId $currencyId
            $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/quotes($id)?`$select=statecode" -Headers $context.Headers -Method Get -ErrorAction Stop
            $headers = $context.Headers.Clone(); $headers['If-Match'] = '*'
            if ($quote.Status -in @('Active','Won') -and $existing.statecode -eq 0) {
                $json = @{statecode=1;statuscode=2} | ConvertTo-Json
                Invoke-RestMethod -Uri "$($context.BaseUrl)/quotes($id)" -Headers $headers -Method Patch -ContentType application/json -Body $json -ErrorAction Stop | Out-Null
                $existing.statecode = 1
            }
            if ($quote.Status -eq 'Won' -and $existing.statecode -eq 1) {
                $json = @{
                    QuoteClose = @{ 'quoteid@odata.bind' = "/quotes($id)"; subject = $quote.Name }
                    Status = -1
                } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Uri "$($context.BaseUrl)/WinQuote" -Headers $context.Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            Write-InstallLogAction -Message "Provisioned D365 Sales & CS Quote '$($quote.Name)'." -Level Success
        }
        catch { Write-InstallLogAction -Message "Failed to provision D365 Sales & CS Quote '$($quote.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error }
    }
}

function Remove-DynamicsQuotes {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json'))
    )
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ids = @($content.Quotes | ForEach-Object { [Guid]::Parse($_.Id) })
    if (-not $ids.Count) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($id in $ids) {
        try {
            # Quote details are deleted with their parent quote.
            Invoke-RestMethod -Uri "$($context.BaseUrl)/quotes($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS Quote $id." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete Quote ${id}: $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed Quote(s)." }
}

function Add-DynamicsOrders {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    Add-DynamicsOrderInvoiceRecords -Config $Config -ContentPath $ContentPath -Collection Orders
}

function Add-DynamicsInvoices {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    Add-DynamicsOrderInvoiceRecords -Config $Config -ContentPath $ContentPath -Collection Invoices
}

function Add-DynamicsOrderInvoiceRecords {
    param([Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][ValidateSet('Orders', 'Invoices')][string]$Collection)
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.$Collection) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $currencyId = Get-DynamicsDefaultCurrencyId -Context $context
    $isOrder = $Collection -eq 'Orders'
    $entitySet = if ($isOrder) { 'salesorders' } else { 'invoices' }
    foreach ($record in $content.$Collection) {
        try {
            if ($isOrder -and $record.Status -notin @('Active', 'Fulfilled', 'Canceled')) { throw 'Supported Order statuses are Active, Fulfilled, and Canceled.' }
            if (-not $isOrder -and $record.Status -notin @('Active', 'Paid', 'Canceled')) { throw 'Supported Invoice statuses are Active, Paid, and Canceled.' }
            $invoiceReason = $null
            if (-not $isOrder) {
                $reasons = @{ New=1; 'Partially Shipped'=2; Billed=4; Complete=100001; Partial=100002; Canceled=100003 }
                $reasonName = if ($record.StatusReason) { $record.StatusReason } elseif ($record.Status -eq 'Paid') { 'Complete' } elseif ($record.Status -eq 'Canceled') { 'Canceled' } else { 'New' }
                if (-not $reasons.ContainsKey($reasonName)) { throw "Unsupported Invoice status reason '$reasonName'." }
                $invoiceReason = $reasons[$reasonName]
                $reasonState = if ($invoiceReason -ge 100003) { 'Canceled' } elseif ($invoiceReason -ge 100001) { 'Paid' } else { 'Active' }
                if ($reasonState -ne $record.Status) { throw "Invoice reason '$reasonName' requires status $reasonState." }
            }
            $id = [Guid]::Parse($record.Id).ToString()
            $accountId = [Guid]::Parse($record.AccountId).ToString()
            $body = @{
                name = $record.Name; description = $record.Description
                'customerid_account@odata.bind' = "/accounts($accountId)"
                'pricelevelid@odata.bind' = "/pricelevels($([Guid]::Parse($record.PriceListId)))"
                'transactioncurrencyid@odata.bind' = "/transactioncurrencies($currencyId)"
                statecode = 0; statuscode = 1
                freightamount = 0; discountamount = 0
            }
            if ($isOrder) {
                $quote = @($content.Quotes | Where-Object { $_.Id -eq $record.QuoteId -and $_.AccountId -eq $accountId -and $_.OpportunityId -eq $record.OpportunityId })
                if ($quote.Count -ne 1) { throw 'Order must reference a Quote for its Account and Opportunity.' }
                $body.ordernumber = $record.OrderNumber
                $body['quoteid@odata.bind'] = "/quotes($([Guid]::Parse($record.QuoteId)))"
                $body['opportunityid@odata.bind'] = "/opportunities($([Guid]::Parse($record.OpportunityId)))"
                if ($null -ne $record.RequestedDeliveryOffset) { $body.requestdeliveryby = (Get-Date).ToUniversalTime().AddDays([int]$record.RequestedDeliveryOffset).ToString('yyyy-MM-dd') }
            }
            else {
                $order = @($content.Orders | Where-Object { $_.Id -eq $record.OrderId -and $_.AccountId -eq $accountId })
                if ($order.Count -ne 1) { throw 'Invoice must reference an Order for its Account.' }
                $body.invoicenumber = $record.InvoiceNumber
                $body['salesorderid@odata.bind'] = "/salesorders($([Guid]::Parse($record.OrderId)))"
                $body.paymenttermscode = 1 # Net 30
                if ($null -ne $record.DueOffset) { $body.duedate = (Get-Date).ToUniversalTime().AddDays([int]$record.DueOffset).ToString('yyyy-MM-dd') }
            }
            if ($null -ne $record.CreatedOffset) { $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$record.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
            # Avoid writing lines to a fulfilled order on subsequent imports.
            $existing = $null
            try {
                $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/$entitySet($id)?`$select=statecode" -Headers $context.Headers -Method Get -ErrorAction Stop
            }
            catch {
                if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw }
            }
            if ($existing -and $existing.statecode -ne 0) {
                if (-not $isOrder -and (($record.Status -eq 'Paid' -and $existing.statecode -eq 2) -or ($record.Status -eq 'Canceled' -and $existing.statecode -eq 3))) {
                    Write-InstallLogAction -Message "D365 Sales & CS Invoice '$($record.Name)' is already $($record.Status), skipping."
                    continue
                }
                if ($isOrder -and (($record.Status -eq 'Fulfilled' -and $existing.statecode -eq 3) -or ($record.Status -eq 'Canceled' -and $existing.statecode -eq 2))) {
                    Write-InstallLogAction -Message "D365 Sales & CS Order '$($record.Name)' is already $($record.Status), skipping."
                    continue
                }
                throw "Existing $(Get-DynamicsTableDisplayName $entitySet) record has unexpected state $($existing.statecode)."
            }
            if ($record.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $record.Owner))" }
            if (-not $existing) { Invoke-DynamicsCreateRecord -Context $context -EntitySet $entitySet -Id $id -Body $body }
            Add-DynamicsSalesLines -Context $context -Content $content -Record $record -EntitySet $entitySet -CurrencyId $currencyId
            if ($isOrder -and $record.Status -in @('Fulfilled', 'Canceled')) {
                if ($record.Status -eq 'Fulfilled') {
                    # Fulfillment is a collection-bound action, not an unbound action or SetState.
                    $close = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.orderclose'; 'salesorderid@odata.bind' = "/salesorders($id)"; subject = $record.Name }
                    if ($null -ne $record.FulfilledOffset) { $close.actualend = (Get-Date).ToUniversalTime().AddDays([int]$record.FulfilledOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    $json = @{OrderClose=$close;Status=100001} | ConvertTo-Json -Depth 5
                    Invoke-RestMethod -Uri "$($context.BaseUrl)/salesorders/Microsoft.Dynamics.CRM.FulfillSalesOrder" -Headers $context.Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
                }
                else {
                    $close = @{ '@odata.type' = 'Microsoft.Dynamics.CRM.orderclose'; 'salesorderid@odata.bind' = "/salesorders($id)"; subject = $record.Name }
                    if ($null -ne $record.CanceledOffset) { $close.actualend = (Get-Date).ToUniversalTime().AddDays([int]$record.CanceledOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                    $json = @{OrderClose=$close;Status=4} | ConvertTo-Json -Depth 5
                    Invoke-RestMethod -Uri "$($context.BaseUrl)/CancelSalesOrder" -Headers $context.Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
                }
            }
            if (-not $isOrder) {
                $stateCode = if ($record.Status -eq 'Paid') { 2 } elseif ($record.Status -eq 'Canceled') { 3 } else { 0 }
                $state = @{statecode=$stateCode;statuscode=$invoiceReason}
                $json = $state | ConvertTo-Json
                $headers = $context.Headers.Clone(); $headers['If-Match'] = '*'
                Invoke-RestMethod -Uri "$($context.BaseUrl)/invoices($id)" -Headers $headers -Method Patch -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            Write-InstallLogAction -Message "Provisioned D365 Sales & CS $(Get-DynamicsTableDisplayName $entitySet) record '$($record.Name)'." -Level Success
        }
        catch { Write-InstallLogAction -Message "Failed to provision D365 Sales & CS $(Get-DynamicsTableDisplayName $entitySet) record '$($record.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error }
    }
}

function Remove-DynamicsOrders {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    Remove-DynamicsOrderInvoiceRecords -Config $Config -ContentPath $ContentPath -Collection Orders
}

function Remove-DynamicsInvoices {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    Remove-DynamicsOrderInvoiceRecords -Config $Config -ContentPath $ContentPath -Collection Invoices
}

function Remove-DynamicsOrderInvoiceRecords {
    param([Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$ContentPath,
        [Parameter(Mandatory = $true)][ValidateSet('Orders', 'Invoices')][string]$Collection)
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ids = @($content.$Collection | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id) } | Select-Object -Unique)
    if (-not $ids.Count) { return }
    $entitySet = if ($Collection -eq 'Orders') { 'salesorders' } else { 'invoices' }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($id in $ids) {
        try {
            # Dataverse cascades deletion to the parent's product lines.
            Invoke-RestMethod -Uri "$($context.BaseUrl)/$entitySet($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS $(Get-DynamicsTableDisplayName $entitySet) record $id." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete $(Get-DynamicsTableDisplayName $entitySet) ${id}: $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed $entitySet record(s)." }
}

function Add-DynamicsIncidents {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.Incidents) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $priorities = @{ High = 1; Normal = 2; Low = 3 }
    $origins = @{ Phone = 1; Email = 2; Web = 3 }
    foreach ($incident in $content.Incidents) {
        try {
            if ($incident.Status -notin @('In Progress', 'Resolved')) { throw 'Supported incident statuses are In Progress and Resolved.' }
            if (-not $priorities.ContainsKey($incident.Priority) -or -not $origins.ContainsKey($incident.Origin)) { throw 'Unsupported incident priority or origin.' }
            $id = [Guid]::Parse($incident.Id).ToString()
            $accountId = [Guid]::Parse($incident.AccountId).ToString()
            if (@($content.Contacts | Where-Object { $_.Id -eq $incident.ContactId -and $_.AccountId -eq $accountId }).Count -ne 1) { throw 'Incident Contact must belong to its Account.' }
            # Standard cases have no order/invoice lookup; retain their numbers in the description.
            $description = $incident.Description
            foreach ($relation in @(@{Field='OrderId';Table='Orders';Number='OrderNumber'}, @{Field='InvoiceId';Table='Invoices';Number='InvoiceNumber'})) {
                if ($incident.($relation.Field)) {
                    $related = @($content.($relation.Table) | Where-Object { $_.Id -eq $incident.($relation.Field) -and $_.AccountId -eq $accountId })
                    if ($related.Count -ne 1) { throw "Invalid incident $($relation.Field) reference." }
                    $description += "`n$($relation.Number): $($related[0].($relation.Number))"
                }
            }
            $body = @{
                title = $incident.Title; ticketnumber = $incident.TicketNumber; description = $description
                'customerid_account@odata.bind' = "/accounts($accountId)"
                'primarycontactid@odata.bind' = "/contacts($([Guid]::Parse($incident.ContactId)))"
                'productid@odata.bind' = "/products($([Guid]::Parse($incident.ProductId)))"
                prioritycode = $priorities[$incident.Priority]; caseorigincode = $origins[$incident.Origin]
                statecode = 0; statuscode = 1
            }
            if ($null -ne $incident.CreatedOffset) { $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$incident.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
            if ($incident.Owner) { $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $incident.Owner))" }
            Invoke-DynamicsCreateRecord -Context $context -EntitySet incidents -Id $id -Body $body
            $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/incidents($id)?`$select=statecode" -Headers $context.Headers -Method Get -ErrorAction Stop
            if ($incident.Status -eq 'Resolved' -and $existing.statecode -eq 0) {
                if ([string]::IsNullOrWhiteSpace($incident.Resolution)) { throw 'Resolved incident requires Resolution.' }
                $resolution = @{ 'incidentid@odata.bind' = "/incidents($id)"; subject = $incident.Title; description = $incident.Resolution }
                if ($null -ne $incident.ResolvedOffset) { $resolution.actualend = (Get-Date).ToUniversalTime().AddDays([int]$incident.ResolvedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                $json = @{ IncidentResolution = $resolution; Status = 5 } | ConvertTo-Json -Depth 5
                Invoke-RestMethod -Uri "$($context.BaseUrl)/CloseIncident" -Headers $context.Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            elseif (($incident.Status -eq 'Resolved' -and $existing.statecode -ne 1) -or ($incident.Status -eq 'In Progress' -and $existing.statecode -ne 0)) { throw "Existing incident has unexpected state $($existing.statecode)." }
            Write-InstallLogAction -Message "Provisioned D365 Sales & CS incident '$($incident.Title)' as $($incident.Status)." -Level Success
        }
        catch { Write-InstallLogAction -Message "Failed to provision D365 Sales & CS incident '$($incident.Title)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error }
    }
}

function Remove-DynamicsIncidents {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ids = @($content.Incidents | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id) } | Select-Object -Unique)
    if (-not $ids.Count) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($id in $ids) {
        try {
            Invoke-RestMethod -Uri "$($context.BaseUrl)/incidents($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS incident $id." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete incident ${id}: $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed incident(s)." }
}

function Add-DynamicsEmails {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    $content = Get-Content $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if (-not $content.Emails) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $regarding = @{Accounts=@{Set='accounts';Type='account'};Incidents=@{Set='incidents';Type='incident'}}
    foreach ($email in $content.Emails) {
        try {
            $id = [Guid]::Parse($email.Id).ToString()
            if ($email.Status -notin @('Draft','Sent','Received')) { throw 'Unsupported Email status.' }
            if ($email.Direction -notin @('Outgoing','Incoming')) { throw 'Unsupported Email direction.' }
            $existing = $null
            try { $existing = Invoke-RestMethod -Uri "$($context.BaseUrl)/emails($id)?`$select=statecode,statuscode" -Headers $context.Headers -Method Get -ErrorAction Stop }
            catch { if (-not $_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404) { throw } }
            $targetReason = switch ($email.Status) { Draft {1} Sent {3} Received {4} }
            if ($existing) {
                $expectedParties = @(New-DynamicsEmailParty -Context $context -Participant $email.From -Mask 1)
                foreach ($participant in $email.To) { $expectedParties += New-DynamicsEmailParty -Context $context -Participant $participant -Mask 2 }
                foreach ($participant in $email.Cc) { $expectedParties += New-DynamicsEmailParty -Context $context -Participant $participant -Mask 3 }
                $actualParties = Invoke-RestMethod -Uri "$($context.BaseUrl)/emails($id)/email_activity_parties?`$select=participationtypemask,_partyid_value" -Headers $context.Headers -Method Get -ErrorAction Stop
                $expectedKeys = @($expectedParties | ForEach-Object {
                    $binding = if ($_['partyid_systemuser@odata.bind']) { $_['partyid_systemuser@odata.bind'] } else { $_['partyid_contact@odata.bind'] }
                    $partyId = $binding.Substring($binding.IndexOf('(') + 1).TrimEnd(')')
                    "$($_.participationtypemask):$partyId"
                } | Sort-Object)
                $actualKeys = @($actualParties.value | Where-Object { $_.participationtypemask -in @(1,2,3) } | ForEach-Object { "$($_.participationtypemask):$($_._partyid_value)" } | Sort-Object)
                if (($expectedKeys -join '|') -ne ($actualKeys -join '|')) { throw 'Existing demo Email has different participants. Remove the old demo Email with cleanup and redeploy to import the source From, To, and Cc.' }
            }
            if ($existing -and $existing.statuscode -eq $targetReason) { continue }
            if ($existing -and $existing.statecode -ne 0) { throw 'Existing Email is closed with a different status.' }
            if (-not $existing) {
                $parties = @(New-DynamicsEmailParty -Context $context -Participant $email.From -Mask 1)
                foreach ($participant in $email.To) { $parties += New-DynamicsEmailParty -Context $context -Participant $participant -Mask 2 }
                foreach ($participant in $email.Cc) { $parties += New-DynamicsEmailParty -Context $context -Participant $participant -Mask 3 }
                $body = @{subject=$email.Subject;description=$email.Body;directioncode=($email.Direction -eq 'Outgoing');statecode=0;statuscode=1;email_activity_parties=$parties}
                $body['ownerid@odata.bind'] = "/systemusers($(Resolve-DynamicsUserId -Context $context -Email $email.Owner))"
                if ($email.RegardingId) {
                    $map = $regarding[$email.RegardingTable]
                    if (-not $map) { throw 'Unsupported Email regarding table.' }
                    if (@($content.($email.RegardingTable) | Where-Object Id -eq $email.RegardingId).Count -ne 1) { throw 'Invalid Email regarding reference.' }
                    $body['regardingobjectid_' + $map.Type + '_email@odata.bind'] = "/$($map.Set)($([Guid]::Parse($email.RegardingId)))"
                }
                if ($null -ne $email.CreatedOffset) { $body.overriddencreatedon = (Get-Date).ToUniversalTime().AddDays([int]$email.CreatedOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                Invoke-DynamicsCreateRecord -Context $context -EntitySet emails -Id $id -Body $body
            }
            if ($email.Status -ne 'Draft') {
                # Import historical activities without delivering messages through a mailbox.
                # senton is read-only; actualend preserves the source message date.
                $state = @{statecode=1;statuscode=$targetReason}
                if ($email.Date) {
                    $date = [datetime]::ParseExact($email.Date,'yyyy-MM-dd HH:mm',[Globalization.CultureInfo]::InvariantCulture)
                    $state.actualend = $date.ToString('yyyy-MM-ddTHH:mm:ssZ')
                }
                elseif ($null -ne $email.SentOffset) { $state.actualend = (Get-Date).ToUniversalTime().AddDays([int]$email.SentOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                $json = $state | ConvertTo-Json
                $headers = $context.Headers.Clone(); $headers['If-Match']='*'
                Invoke-RestMethod -Uri "$($context.BaseUrl)/emails($id)" -Headers $headers -Method Patch -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            Write-InstallLogAction -Message "Imported D365 Sales & CS Email '$($email.Subject)' as $($email.Status)." -Level Success
        }
        catch { Write-InstallLogAction -Message "Failed to import D365 Sales & CS Email '$($email.Subject)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error }
    }
}

function Remove-DynamicsEmails {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    $content = Get-Content $ContentPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $ids = @($content.Emails | Where-Object { $_ } | ForEach-Object { [Guid]::Parse($_.Id) } | Select-Object -Unique)
    if (-not $ids.Count) { return }
    $context = Get-DynamicsRequestContext -Config $Config
    $failed = 0
    foreach ($id in $ids) {
        try {
            Invoke-RestMethod -Uri "$($context.BaseUrl)/emails($id)" -Headers $context.Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 Sales & CS Email $id." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { continue }
            $failed++
            Write-InstallLogAction -Message "Failed to delete Email ${id}: $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed Email(s)." }
}

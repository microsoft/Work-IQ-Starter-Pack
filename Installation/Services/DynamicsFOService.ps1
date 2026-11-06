param([scriptblock]$AccessTokenProvider)

function Get-DynamicsFORecords {
    param([string]$Url, [string]$EnvironmentUrl, [hashtable]$Headers)
    do {
        $uri = [Uri]::new([Uri]($EnvironmentUrl + '/'), $Url)
        if ($uri.GetLeftPart([UriPartial]::Authority) -ne $EnvironmentUrl) { throw 'D365 F&O pagination URL points outside the configured environment.' }
        $response = Invoke-RestMethod -Uri $uri.AbsoluteUri -Headers $Headers -Method Get -ErrorAction Stop
        $response.value | Where-Object { $_ }
        $Url = $response.'@odata.nextLink'
    } while ($Url)
}

function Select-DynamicsFORecord {
    param([object[]]$Records, [string]$CodeField, [string]$NameField, [string]$Prompt, [string]$SavedCode, [switch]$UseConfig)
    if (-not $Records.Count) { throw "No records available: $Prompt" }
    if ($Records.Count -eq 1) {
        $message = "Automatically selected the only available entry: $($Records[0].$CodeField) - $($Records[0].$NameField)"
        Write-InstallLogAction -Message $message
        return $Records[0]
    }
    if ($UseConfig) {
        $match = @($Records | Where-Object { $_.$CodeField -eq $SavedCode })
        if ($match.Count -ne 1) { throw "Saved selection '$SavedCode' is unavailable: $Prompt. Run interactively to select a value." }
        return $match[0]
    }
    for ($i=0; $i -lt $Records.Count; $i++) { Write-Host ("{0}. {1} - {2}" -f ($i+1), $Records[$i].$CodeField, $Records[$i].$NameField) }
    do {
        $answer = Read-Host $Prompt
        $number = 0
        $valid = [int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Records.Count
        if (-not $valid) { Write-Host "Enter a number from 1 to $($Records.Count)." }
    } while (-not $valid)
    return $Records[$number-1]
}

function Add-DynamicsFOContent {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Settings,
        [string]$ConfigPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Configuration/config.json')),
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')),
        [switch]$UseConfig
    )
    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsFOEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw 'Settings.DynamicsFOEnvironmentUrl must be an HTTPS environment root URL.'
    }
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/Odata.FullAccess" } else { Get-PnPAccessToken -Scopes "$environmentUrl/Odata.FullAccess" -ErrorAction Stop }
    $headers = @{Authorization="Bearer $token"; Accept='application/json'}
    Write-InstallLogAction -Message 'Retrieving D365 F&O Companies...'
    $companies = @(Get-DynamicsFORecords -Url "$environmentUrl/data/LegalEntities?cross-company=true&`$select=LegalEntityId,Name" -EnvironmentUrl $environmentUrl -Headers $headers | Sort-Object LegalEntityId)
    Write-Host "Retrieved $($companies.Count) Companies."
    $company = Select-DynamicsFORecord -Records $companies -CodeField LegalEntityId -NameField Name -Prompt 'Select the Company number' -SavedCode $Config.Settings.DynamicsFOLegalEntityId -UseConfig:$UseConfig
    $companyId = [string]$company.LegalEntityId
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOLegalEntityId -NotePropertyValue $companyId -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Selected D365 F&O Company '$companyId': $($company.Name)"

    Write-Host "Retrieving the default accounting currency for $companyId..."
    $ledgers = @(Get-DynamicsFORecords -Url "$environmentUrl/data/Ledgers?cross-company=true" -EnvironmentUrl $environmentUrl -Headers $headers |
        Where-Object { $_.LegalEntityId -eq $companyId })
    if ($ledgers.Count -ne 1 -or [string]::IsNullOrWhiteSpace($ledgers[0].AccountingCurrency)) {
        $ledgerSetupUrl = 'https://learn.microsoft.com/en-us/dynamics365/finance/general-ledger/configure-ledger'
        Write-Host "Could not resolve one ledger with an accounting currency for Company '$companyId'." -ForegroundColor Yellow
        Write-Host "In F&O, select Company '$companyId' and configure Accounting currency under General ledger > Ledger setup > Ledger."
        Write-Host "Microsoft ledger configuration instructions: $ledgerSetupUrl"
        throw "Configure the ledger and accounting currency for Company '$companyId' before running the installer again. See $ledgerSetupUrl"
    }
    $salesCurrencyCode = [string]$ledgers[0].AccountingCurrency
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOSalesCurrencyCode -NotePropertyValue $salesCurrencyCode -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Using D365 F&O Company '$companyId' accounting currency '$salesCurrencyCode' for Customers."

    Write-Host "Retrieving Customer Groups for $companyId..."
    $groups = @(Get-DynamicsFORecords -Url "$environmentUrl/data/CustomerGroups?cross-company=true" -EnvironmentUrl $environmentUrl -Headers $headers | Where-Object { $_.dataAreaId -eq $companyId } | Sort-Object CustomerGroupId)
    $group = Select-DynamicsFORecord -Records $groups -CodeField CustomerGroupId -NameField Description -Prompt 'Select the Customer Group number' -SavedCode $Config.Settings.DynamicsFOCustomerGroupId -UseConfig:$UseConfig
    $groupId = [string]$group.CustomerGroupId
    if ([string]::IsNullOrWhiteSpace($groupId)) { throw 'Customer Group response has no CustomerGroupId.' }
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOCustomerGroupId -NotePropertyValue $groupId -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Selected D365 F&O Customer Group '$groupId' in '$companyId'."

    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $failed = 0
    Write-InstallLogAction -Message "Starting D365 F&O Customer creation in '$companyId' (existing Customer codes will be skipped)..."
    foreach ($account in $content.Accounts) {
        try {
            if ([string]::IsNullOrWhiteSpace($account.AccountNumber) -or [string]::IsNullOrWhiteSpace($account.Name)) { throw 'Account requires AccountNumber and Name.' }
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$($companyId.Replace("'","''"))' and CustomerAccount eq '$($account.AccountNumber.Replace("'","''"))'")
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/Customers?cross-company=true&`$filter=$filter&`$select=CustomerAccount" -EnvironmentUrl $environmentUrl -Headers $headers)
            if ($existing.Count) {
                Write-InstallLogAction -Message "D365 F&O Customer '$($account.AccountNumber)' already exists in '$companyId', skipping."
                continue
            }
            $contact = @($content.Contacts | Where-Object { $_.Id -eq $account.PrimaryContactId -and $_.AccountId -eq $account.Id })
            $body = @{
                dataAreaId=$companyId; CustomerAccount=$account.AccountNumber; PartyType='Organization'
                Name=$account.Name; CustomerGroupId=$groupId; SalesCurrencyCode=$salesCurrencyCode
                LanguageId= if ([string]::IsNullOrWhiteSpace($Config.Settings.DynamicsFOLanguageId)) { 'en-us' } else { $Config.Settings.DynamicsFOLanguageId }
                TaxRegistrationId=''; DestinationCode=''; AddressCountryRegionId='USA'
                AddressCity=$account.City; AddressState=$account.State
                AddressZipCode=''; AddressStreet=''; AddressCounty=''; AddressBooks=''
                PrimaryContactPhone=$account.Phone; PrimaryContactFax=''; PrimaryContactPhoneExtension=''
                PrimaryContactEmail= if ($contact.Count -eq 1) { $contact[0].Email } else { '' }
            }
            # Send these reference codes only when configured for the selected environment.
            foreach ($field in @('DeliveryTerms','DeliveryMode','SalesTaxGroup','PaymentTerms')) {
                $settingName = 'DynamicsFO' + $field
                if (-not [string]::IsNullOrWhiteSpace($Config.Settings.$settingName)) { $body[$field] = $Config.Settings.$settingName }
            }
            if ($account.Country -and $account.Country -ne 'United States') { throw "No D365 F&O country mapping configured for '$($account.Country)'." }
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/data/Customers" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created D365 F&O Customer '$($account.AccountNumber)' ($($account.Name)) in '$companyId'." -Level Success
        }
        catch {
            $failed++
            Write-InstallLogAction -Message "Failed to create D365 F&O Customer '$($account.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Failed to create $failed D365 F&O Customer(s). Review the installation log." }
    Write-InstallLogAction -Message 'Finished creating D365 F&O Customers.' -Level Success
    Write-Host 'Starting D365 F&O Product creation (existing Product numbers will be skipped)...'
    $failedProducts = 0
    foreach ($product in $content.Products) {
        try {
            if ([string]::IsNullOrWhiteSpace($product.ProductNumber) -or [string]::IsNullOrWhiteSpace($product.Name)) { throw 'Product requires ProductNumber and Name.' }
            # ProductsV2 contains shared products, so do not filter by legal entity.
            $filter = [Uri]::EscapeDataString("ProductNumber eq '$($product.ProductNumber.Replace("'","''"))'")
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/ProductsV2?cross-company=true&`$filter=$filter&`$select=ProductNumber" -EnvironmentUrl $environmentUrl -Headers $headers)
            if ($existing.Count) {
                Write-InstallLogAction -Message "D365 F&O Product '$($product.ProductNumber)' already exists, skipping."
                continue
            }
            $body = @{
                ProductNumber=$product.ProductNumber; ProductType='Item'; ProductSubType='Product'
                ProductName=$product.Name; ProductDescription=$product.Description
                ProductSearchName=$product.ProductNumber.Substring(0, [Math]::Min(20, $product.ProductNumber.Length))
            }
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/data/ProductsV2" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created shared D365 F&O Product '$($product.ProductNumber)' ($($product.Name))." -Level Success
        }
        catch {
            $failedProducts++
            Write-InstallLogAction -Message "Failed to create D365 F&O Product '$($product.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failedProducts) { throw "Failed to create $failedProducts D365 F&O Product(s). Review the installation log." }
    Write-InstallLogAction -Message 'Finished creating D365 F&O Shared Products.' -Level Success
    Write-InstallLogAction -Message 'Releasing D365 F&O Products to the selected Company...'
    Add-DynamicsFOReleasedProducts -Config $Config -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId -ConfigPath $ConfigPath -UseConfig:$UseConfig
    Write-InstallLogAction -Message 'Finished releasing D365 F&O Products.' -Level Success
    Write-InstallLogAction -Message 'Creating D365 F&O Sales Orders and their Lines...'
    Add-DynamicsFOSalesOrders -Config $Config -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId -CurrencyCode $salesCurrencyCode -ConfigPath $ConfigPath -UseConfig:$UseConfig
    Write-InstallLogAction -Message 'Finished creating D365 F&O Sales Orders and their Lines.' -Level Success
}

function Remove-DynamicsFOContent {
    param([Parameter(Mandatory = $true)]$Config,
        [string]$ContentPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Content/contentDynamics.json')))
    $environmentUri = $null
    if (-not [Uri]::TryCreate($Config.Settings.DynamicsFOEnvironmentUrl, [UriKind]::Absolute, [ref]$environmentUri) -or
        $environmentUri.Scheme -ne 'https' -or $environmentUri.UserInfo -or
        $environmentUri.AbsolutePath -ne '/' -or $environmentUri.Query -or $environmentUri.Fragment) {
        throw 'Settings.DynamicsFOEnvironmentUrl must be an HTTPS environment root URL.'
    }
    $companyId = [string]$Config.Settings.DynamicsFOLegalEntityId
    if ([string]::IsNullOrWhiteSpace($companyId)) { throw 'Settings.DynamicsFOLegalEntityId is required for D365 F&O cleanup.' }
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # Validate every code before making any delete request.
    $customers = @($content.Accounts | Where-Object { $_ } | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.AccountNumber)) { throw 'Demo Account has no AccountNumber.' }
        [string]$_.AccountNumber
    } | Select-Object -Unique)
    $products = @($content.Products | Where-Object { $_ } | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.ProductNumber)) { throw 'Demo Product has no ProductNumber.' }
        [string]$_.ProductNumber
    } | Select-Object -Unique)
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $token = if ($AccessTokenProvider) { & $AccessTokenProvider "$environmentUrl/Odata.FullAccess" } else { Get-PnPAccessToken -Scopes "$environmentUrl/Odata.FullAccess" -ErrorAction Stop }
    $headers = @{Authorization="Bearer $token";Accept='application/json'}
    $encodedCompany = [Uri]::EscapeDataString($companyId.Replace("'","''"))
    Write-InstallLogAction -Message "Deleting D365 F&O Sales Orders and their Lines in Company '$companyId'..."
    Remove-DynamicsFOSalesOrders -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId
    Write-InstallLogAction -Message "Finished deleting D365 F&O Sales Orders and their Lines in Company '$companyId'." -Level Success
    $records = @(
        foreach ($code in $customers) {
            $encodedCode = [Uri]::EscapeDataString($code.Replace("'","''"))
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$($companyId.Replace("'","''"))' and CustomerAccount eq '$($code.Replace("'","''"))'")
            @{Label="Customer '$code' in '$companyId'";Path="Customers(dataAreaId='$encodedCompany',CustomerAccount='$encodedCode')";Query="Customers?cross-company=true&`$filter=$filter";IsCustomer=$true}
        }
        foreach ($code in $products) {
            $encodedCode = [Uri]::EscapeDataString($code.Replace("'","''"))
            $filter = [Uri]::EscapeDataString("ProductNumber eq '$($code.Replace("'","''"))'")
            @{Label="Shared Product '$code'";Path="ProductsV2(ProductNumber='$encodedCode')";Query="ProductsV2?cross-company=true&`$filter=$filter";IsCustomer=$false}
        }
    )
    $failed = 0
    foreach ($recordGroup in ($records | Group-Object IsCustomer | Sort-Object Name -Descending)) {
        $description = if ($recordGroup.Group[0].IsCustomer) { "D365 F&O Customers in Company '$companyId'" } else { 'D365 F&O Shared Products' }
        Write-InstallLogAction -Message "Deleting $description..."
        $failedBefore = $failed
        foreach ($record in $recordGroup.Group) {
        try {
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/$($record.Query)" -EnvironmentUrl $environmentUrl -Headers $headers)
            if (-not $existing.Count) {
                continue
            }
            if ($existing.Count -ne 1) { throw 'Expected exactly one record for the cleanup key.' }
            # Preserve the company's canonical casing from D365 F&O and include cross-company
            # on DELETE as well as GET, so default-company scoping cannot hide the row.
            if ($record.IsCustomer) {
                if ($existing[0].dataAreaId -ne $companyId) { throw 'Customer belongs to a different Company.' }
                $returnedCompany = [Uri]::EscapeDataString(([string]$existing[0].dataAreaId).Replace("'","''"))
                $returnedCode = [Uri]::EscapeDataString(([string]$existing[0].CustomerAccount).Replace("'","''"))
                $record.Path = "Customers(dataAreaId='$returnedCompany',CustomerAccount='$returnedCode')"
            }
            Invoke-RestMethod -Uri "$environmentUrl/data/$($record.Path)?cross-company=true" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 F&O $($record.Label)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                continue
            }
            $failed++
            Write-InstallLogAction -Message "Failed to delete D365 F&O $($record.Label): $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
        }
        if ($failed -eq $failedBefore) {
            Write-InstallLogAction -Message "Finished deleting $description." -Level Success
        }
        else {
            Write-InstallLogAction -Message "Could not finish deleting $description. Review the errors above." -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed D365 F&O demo record(s). Review the cleanup log." }
}

function Add-DynamicsFOSalesOrders {
    param($Config, $Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId, [string]$CurrencyCode,
        [string]$ConfigPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Configuration/config.json')), [switch]$UseConfig)
    Write-Host "Starting D365 F&O Sales Order creation in '$CompanyId'..."
    $companyLiteral = $CompanyId.Replace("'","''")
    if (-not @($Content.Orders).Count) { return }
    Write-Host "Retrieving Shipping Warehouses for D365 F&O Company '$CompanyId'..."
    $warehouseFilter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral'")
    $warehouses = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/Warehouses?cross-company=true&`$filter=$warehouseFilter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers |
        Where-Object { $_.dataAreaId -eq $CompanyId -and -not [string]::IsNullOrWhiteSpace($_.WarehouseId) -and -not [string]::IsNullOrWhiteSpace($_.OperationalSiteId) } | Sort-Object WarehouseId)
    $savedWarehouse = if ($Config.Settings.DynamicsFOShippingCompany -eq $CompanyId) { $Config.Settings.DynamicsFOShippingWarehouseId } else { '' }
    $warehouse = Select-DynamicsFORecord -Records $warehouses -CodeField WarehouseId -NameField WarehouseName -Prompt 'Select the shipping warehouse number' -SavedCode $savedWarehouse -UseConfig:$UseConfig
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOShippingCompany -NotePropertyValue $CompanyId -Force
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOShippingWarehouseId -NotePropertyValue $warehouse.WarehouseId -Force
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOShippingSiteId -NotePropertyValue $warehouse.OperationalSiteId -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Using shipping site '$($warehouse.OperationalSiteId)' and warehouse '$($warehouse.WarehouseId)' in '$CompanyId'."
    $failed = 0
    foreach ($order in $Content.Orders) {
        try {
            if ([string]::IsNullOrWhiteSpace($order.OrderNumber)) { throw 'OrderNumber is required.' }
            $accounts = @($Content.Accounts | Where-Object Id -eq $order.AccountId)
            if ($accounts.Count -ne 1) { throw 'Invalid Order AccountId.' }
            $orderLiteral = $order.OrderNumber.Replace("'","''")
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and (CustomerRequisitionNumber eq '$orderLiteral' or SalesOrderNumber eq '$orderLiteral')")
            $existing = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            # Resolve released items before creating a header; shared products alone are not sellable.
            $items = @{}
            foreach ($line in $order.Lines) {
                $products = @($Content.Products | Where-Object Id -eq $line.ProductId)
                if ($products.Count -ne 1) { throw 'Invalid Order Product reference.' }
                $product = $products[0]
                $itemFilter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and ProductNumber eq '$($product.ProductNumber.Replace("'","''"))'")
                $released = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/ReleasedProductsV2?cross-company=true&`$filter=$itemFilter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
                if ($released.Count -ne 1) { throw "Product '$($product.ProductNumber)' must first be released and configured for sales in Company '$CompanyId'." }
                $items[$line.ProductId] = $released[0]
            }
            if (-not $existing.Count) {
                $customerFilter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and CustomerAccount eq '$($accounts[0].AccountNumber.Replace("'","''"))'")
                $customers = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/Customers?cross-company=true&`$filter=$customerFilter&`$select=CustomerAccount,LanguageId" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
                if ($customers.Count -ne 1) { throw 'Expected one D365 F&O Customer for the Sales Order.' }
                $languageId = [string]$customers[0].LanguageId
                if ([string]::IsNullOrWhiteSpace($languageId)) { $languageId = [string]$Config.Settings.DynamicsFOLanguageId }
                if ([string]::IsNullOrWhiteSpace($languageId)) { $languageId = 'en-us' }
                $body = @{dataAreaId=$CompanyId;CustomerRequisitionNumber=$order.OrderNumber;OrderingCustomerAccountNumber=$accounts[0].AccountNumber;InvoiceCustomerAccountNumber=$accounts[0].AccountNumber;CurrencyCode=$CurrencyCode;SalesOrderName=$order.Name;LanguageId=$languageId}
                if ($null -ne $order.RequestedDeliveryOffset) { $body.RequestedShippingDate=(Get-Date).ToUniversalTime().AddDays([int]$order.RequestedDeliveryOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                $json=$body | ConvertTo-Json
                Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderHeadersV2" -Headers $Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            $resolved = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            if ($resolved.Count -ne 1 -or -not $resolved[0].SalesOrderNumber) { throw 'Expected one generated D365 F&O Order for the demo reference.' }
            if ($resolved[0].OrderingCustomerAccountNumber -ne $accounts[0].AccountNumber) { throw 'Order reference belongs to a different Customer.' }
            $foOrderNumber = [string]$resolved[0].SalesOrderNumber
            Write-InstallLogAction -Message "Demo Order '$($order.OrderNumber)' maps to D365 F&O Order '$foOrderNumber' in '$CompanyId'."
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and SalesOrderNumber eq '$($foOrderNumber.Replace("'","''"))'")
            $existingLines = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderLines?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            $lineNumber=0
            foreach ($line in $order.Lines) {
                $lineNumber++
                $matches=@($existingLines | Where-Object { [decimal]$_.LineNumber -eq $lineNumber })
                $item=$items[$line.ProductId]
                if ($matches.Count) {
                    if ($matches.Count -ne 1 -or $matches[0].ItemNumber -ne $item.ItemNumber -or [decimal]$matches[0].OrderedSalesQuantity -ne [decimal]$line.Quantity -or [decimal]$matches[0].SalesPrice -ne [decimal]$line.UnitPrice) { throw "Existing Order line $lineNumber conflicts with the demo data." }
                    continue
                }
                $body=@{dataAreaId=$CompanyId;SalesOrderNumber=$foOrderNumber;LineNumber=$lineNumber;ItemNumber=$item.ItemNumber;OrderedSalesQuantity=[decimal]$line.Quantity;SalesPrice=[decimal]$line.UnitPrice;SalesPriceQuantity=1}
                $body.ShippingSiteId = $warehouse.OperationalSiteId
                $body.ShippingWarehouseId = $warehouse.WarehouseId
                if ($item.SalesUnitSymbol) { $body.SalesUnitSymbol=$item.SalesUnitSymbol }
                if ($null -ne $order.RequestedDeliveryOffset) { $body.RequestedShippingDate=(Get-Date).ToUniversalTime().AddDays([int]$order.RequestedDeliveryOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                $json=$body | ConvertTo-Json
                Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderLines" -Headers $Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            Write-InstallLogAction -Message "Provisioned D365 F&O Sales Order '$($order.OrderNumber)' and its lines in '$CompanyId'. Source Dynamics status: $($order.Status); D365 F&O posting is not performed." -Level Success
        }
        catch {
            $failed++
            Write-InstallLogAction -Message "Failed to create D365 F&O Order '$($order.OrderNumber)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Failed to provision $failed D365 F&O Sales Order(s)." }
}

function Remove-DynamicsFOSalesOrders {
    param($Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId)
    # Validate all source codes before deleting lines or headers.
    $codes=@($Content.Orders | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_.OrderNumber)) {throw 'OrderNumber is required for cleanup.'}; [string]$_.OrderNumber } | Select-Object -Unique)
    foreach ($code in $codes) {
        $referenceFilter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))' and (CustomerRequisitionNumber eq '$($code.Replace("'","''"))' or SalesOrderNumber eq '$($code.Replace("'","''"))')")
        $resolved=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$referenceFilter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        if (-not $resolved.Count) { continue }
        if ($resolved.Count -ne 1 -or -not $resolved[0].SalesOrderNumber) { throw "Multiple or invalid D365 F&O Orders for demo reference '$code'." }
        $sourceOrder=@($Content.Orders | Where-Object OrderNumber -eq $code)[0]
        $sourceAccount=@($Content.Accounts | Where-Object Id -eq $sourceOrder.AccountId)[0]
        if ($resolved[0].OrderingCustomerAccountNumber -ne $sourceAccount.AccountNumber) { throw 'Cleanup Order reference belongs to a different Customer.' }
        $code=[string]$resolved[0].SalesOrderNumber
        $filter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))' and SalesOrderNumber eq '$($code.Replace("'","''"))'")
        $lines=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderLines?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line.InventoryLotId) -or $line.dataAreaId -ne $CompanyId -or $line.SalesOrderNumber -ne $code) {throw 'Unexpected Sales Order line cleanup key.'}
            $companyKey=[Uri]::EscapeDataString(([string]$line.dataAreaId).Replace("'","''"))
            $lotKey=[Uri]::EscapeDataString(([string]$line.InventoryLotId).Replace("'","''"))
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderLines(dataAreaId='$companyKey',InventoryLotId='$lotKey')?cross-company=true" -Headers $Headers -Method Delete -ErrorAction Stop | Out-Null
        }
        $orders=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        foreach ($order in $orders) {
            if ($order.dataAreaId -ne $CompanyId -or $order.SalesOrderNumber -ne $code) {throw 'Unexpected Sales Order cleanup key.'}
            $companyKey=[Uri]::EscapeDataString(([string]$order.dataAreaId).Replace("'","''"))
            $orderKey=[Uri]::EscapeDataString(([string]$order.SalesOrderNumber).Replace("'","''"))
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderHeadersV2(dataAreaId='$companyKey',SalesOrderNumber='$orderKey')?cross-company=true" -Headers $Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted D365 F&O Sales Order '$code' and its Lines in '$CompanyId'." -Level Success
        }
    }
}

function Get-DynamicsFOTemplateMissingFields {
    param([Parameter(Mandatory = $true)]$Item)
    foreach ($field in @('InventoryUnitSymbol','SalesUnitSymbol','ProductGroupId','ItemModelGroupId','StorageDimensionGroupName','TrackingDimensionGroupName')) {
        if ([string]::IsNullOrWhiteSpace([string]$Item.$field)) { $field }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Item.PurchaseUnitSymbol) -and
        [string]::IsNullOrWhiteSpace([string]$Item.PurchUnitSymbol)) {
        'PurchaseUnitSymbol/PurchUnitSymbol'
    }
}

function Add-DynamicsFOReleasedProducts {
    param($Config, $Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId, [string]$ConfigPath, [switch]$UseConfig)
    Write-Host "Checking Released Products in '$CompanyId'..."
    $filter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))'")
    $released=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/ReleasedProductsV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
    $missing=@($Content.Products | Where-Object { $number=$_.ProductNumber; -not @($released | Where-Object ProductNumber -eq $number).Count })
    $demoNumbers = @($Content.Products | ForEach-Object { $_.ProductNumber })
    $needsDimensions = @($released | Where-Object {
        $_.ProductNumber -in $demoNumbers -and
        ([string]::IsNullOrWhiteSpace($_.StorageDimensionGroupName) -or [string]::IsNullOrWhiteSpace($_.TrackingDimensionGroupName))
    })
    if (-not $missing.Count -and -not $needsDimensions.Count) { return }
    Write-InstallLogAction -Message "Demo products inherit storage and tracking dimension groups from the setup template. Missing assignments on $($needsDimensions.Count) existing demo item(s) will be filled; existing assignments will be preserved."
    Write-Host "F&O setup template preparation (company '$CompanyId'):" -ForegroundColor Yellow
    Write-Host '  1. Open Product information management > Products > Released products and open your template item (for example, ITEM).'
    Write-Host '  2. On the top Action Pane, select Product > Dimension groups.'
    Write-Host '  3. Select both Storage dimension group and Tracking dimension group, then select OK and save.'
    Write-Host '  If the lookups are empty, create groups under Product information management > Setup > Dimension and variant groups:'
    Write-Host '    - Storage dimension groups: choose active dimensions and warehouse settings compatible with your shipping site and warehouse.'
    Write-Host '    - Tracking dimension groups: for items without batch/serial tracking, use a group with no tracking dimensions active. Select that group explicitly; do not leave the assignment blank.'
    Write-Host '  Return to the template and assign the groups. These are Supply Chain Management pages in F&O; ask your administrator to check access if they are unavailable.'
    Write-Host '  Only the template needs manual setup. On rerun, the installer fills missing groups on existing demo items and preserves existing assignments.'
    Write-Host '  Microsoft instructions: https://learn.microsoft.com/en-us/dynamics365/supply-chain/pim/tasks/complete-basic-setup-released-product-master'
    # Take valid company-specific setup from an explicitly selected existing item.
    $templates=@($released | Where-Object { @(Get-DynamicsFOTemplateMissingFields -Item $_).Count -eq 0 } | Sort-Object ItemNumber)
    if (-not $templates.Count) {
        $details = @($released | ForEach-Object {
            "Item '$($_.ItemNumber)' (Product '$($_.ProductNumber)'): missing $(@(Get-DynamicsFOTemplateMissingFields -Item $_) -join ', ')"
        }) -join '; '
        if (-not $released.Count) { $details = 'No released items were returned.' }
        throw "No usable released product setup template in company '$CompanyId'. $details. In F&O, switch to '$CompanyId' and open Product information management > Products > Released products. Create or complete an item with General > Item model group, Manage costs > Item group, and Unit under Purchase, Sell, and Manage inventory. Open the template item details, then select Product > Dimension groups on the top Action Pane. Select Storage dimension group and Tracking dimension group and click OK. If the lookups are empty, create groups under Product information management > Setup > Dimension and variant groups > Storage dimension groups / Tracking dimension groups, then return to the template to assign them. A no-tracking group must be selected explicitly; a blank assignment is not a no-tracking group. These Supply Chain Management pages require appropriate access; ask your environment administrator if they are unavailable. Save and rerun the installer; it will copy these groups to new demo products and fill missing groups on existing demo items. Changing the template item number in config.json does not populate missing setup."
    }
    Write-Host 'Select an existing item whose Units, inventory groups, and default site/warehouse will be used for the demo Products.'
    $saved=if ($Config.Settings.DynamicsFOProductTemplateCompany -eq $CompanyId) { $Config.Settings.DynamicsFOProductTemplateItemNumber } else { '' }
    $template=Select-DynamicsFORecord -Records $templates -CodeField ItemNumber -NameField SearchName -Prompt 'Select the Product setup template number' -SavedCode $saved -UseConfig:$UseConfig
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOProductTemplateCompany -NotePropertyValue $CompanyId -Force
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOProductTemplateItemNumber -NotePropertyValue $template.ItemNumber -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Using template '$($template.ItemNumber)': storage dimension group '$($template.StorageDimensionGroupName)', tracking dimension group '$($template.TrackingDimensionGroupName)'."
    foreach ($item in $needsDimensions) {
        $body = @{}
        foreach ($field in @('StorageDimensionGroupName','TrackingDimensionGroupName')) {
            if ([string]::IsNullOrWhiteSpace($item.$field)) { $body[$field] = $template.$field }
        }
        # Use the returned company and item keys, which may differ from ProductNumber.
        $companyKey = [Uri]::EscapeDataString(([string]$item.dataAreaId).Replace("'", "''"))
        $itemKey = [Uri]::EscapeDataString(([string]$item.ItemNumber).Replace("'", "''"))
        $json = $body | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/ReleasedProductsV2(dataAreaId='$companyKey',ItemNumber='$itemKey')" -Headers $Headers -Method Patch -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Completed missing dimension groups for demo item '$($item.ItemNumber)' in '$CompanyId' from template '$($template.ItemNumber)': $($body.Keys -join ', ')." -Level Success
        }
        catch { throw "Failed to complete dimension groups for demo item '$($item.ItemNumber)' in '$CompanyId': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
    }
    foreach ($product in $missing) {
        $collision=@($released | Where-Object ItemNumber -eq $product.ProductNumber)
        if ($collision.Count) { throw "Item number '$($product.ProductNumber)' already belongs to another shared Product in '$CompanyId'." }
        # Subtype is inherited from the shared product and is not insertable here.
        $body=@{dataAreaId=$CompanyId;ItemNumber=$product.ProductNumber;ProductNumber=$product.ProductNumber;SalesPrice=[decimal]$product.UnitPrice;SalesPriceQuantity=1}
        foreach ($field in @('InventoryUnitSymbol','SalesUnitSymbol','PurchaseUnitSymbol','PurchUnitSymbol','ProductGroupId','ItemModelGroupId','StorageDimensionGroupName','TrackingDimensionGroupName','DefaultOrderSettingsInventorySiteId','DefaultOrderSettingsInventoryWarehouseId','SalesSalesTaxItemGroupCode')) {
            if (-not [string]::IsNullOrWhiteSpace($template.$field)) { $body[$field]=$template.$field }
        }
        $json=$body | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/ReleasedProductsV2" -Headers $Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Released Product '$($product.ProductNumber)' in '$CompanyId' using setup from '$($template.ItemNumber)'." -Level Success
        }
        catch { throw "Failed to release Product '$($product.ProductNumber)' in '$CompanyId': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
    }
}

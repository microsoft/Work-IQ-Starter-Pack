function Get-DynamicsFORecords {
    param([string]$Url, [string]$EnvironmentUrl, [hashtable]$Headers)
    do {
        $uri = [Uri]::new([Uri]($EnvironmentUrl + '/'), $Url)
        if ($uri.GetLeftPart([UriPartial]::Authority) -ne $EnvironmentUrl) { throw 'F&O pagination URL points outside the configured environment.' }
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
        Write-Host $message
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
    $token = Get-PnPAccessToken -Scopes "$environmentUrl/Odata.FullAccess" -ErrorAction Stop
    $headers = @{Authorization="Bearer $token"; Accept='application/json'}
    Write-Host 'Retrieving Dynamics 365 F&O companies...'
    Write-InstallLogAction -Message 'Retrieving Dynamics 365 F&O companies...'
    $companies = @(Get-DynamicsFORecords -Url "$environmentUrl/data/LegalEntities?cross-company=true&`$select=LegalEntityId,Name" -EnvironmentUrl $environmentUrl -Headers $headers | Sort-Object LegalEntityId)
    Write-Host "Retrieved $($companies.Count) companies."
    $company = Select-DynamicsFORecord -Records $companies -CodeField LegalEntityId -NameField Name -Prompt 'Select the company number' -SavedCode $Config.Settings.DynamicsFOLegalEntityId -UseConfig:$UseConfig
    $companyId = [string]$company.LegalEntityId
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOLegalEntityId -NotePropertyValue $companyId -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Selected F&O company '$companyId': $($company.Name)"

    Write-Host "Retrieving the default accounting currency for $companyId..."
    $ledgers = @(Get-DynamicsFORecords -Url "$environmentUrl/data/Ledgers?cross-company=true" -EnvironmentUrl $environmentUrl -Headers $headers |
        Where-Object { $_.LegalEntityId -eq $companyId })
    if ($ledgers.Count -ne 1 -or [string]::IsNullOrWhiteSpace($ledgers[0].AccountingCurrency)) {
        throw "Could not resolve one ledger with an accounting currency for company '$companyId'. Customer creation cannot continue."
    }
    $salesCurrencyCode = [string]$ledgers[0].AccountingCurrency
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOSalesCurrencyCode -NotePropertyValue $salesCurrencyCode -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-Host "Default currency for ${companyId}: $salesCurrencyCode"
    Write-InstallLogAction -Message "Using F&O company '$companyId' accounting currency '$salesCurrencyCode' for customers."

    Write-Host "Retrieving customer groups for $companyId..."
    $groups = @(Get-DynamicsFORecords -Url "$environmentUrl/data/CustomerGroups?cross-company=true" -EnvironmentUrl $environmentUrl -Headers $headers | Where-Object { $_.dataAreaId -eq $companyId } | Sort-Object CustomerGroupId)
    $group = Select-DynamicsFORecord -Records $groups -CodeField CustomerGroupId -NameField Description -Prompt 'Select the customer group number' -SavedCode $Config.Settings.DynamicsFOCustomerGroupId -UseConfig:$UseConfig
    $groupId = [string]$group.CustomerGroupId
    if ([string]::IsNullOrWhiteSpace($groupId)) { throw 'Customer group response has no CustomerGroupId.' }
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOCustomerGroupId -NotePropertyValue $groupId -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    Write-InstallLogAction -Message "Selected F&O customer group '$groupId' in '$companyId'."

    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $failed = 0
    Write-Host "Starting customer creation in F&O company '$companyId' (existing customer codes will be skipped)..."
    Write-InstallLogAction -Message "Starting F&O customer creation in '$companyId'."
    foreach ($account in $content.Accounts) {
        try {
            if ([string]::IsNullOrWhiteSpace($account.AccountNumber) -or [string]::IsNullOrWhiteSpace($account.Name)) { throw 'Account requires AccountNumber and Name.' }
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$($companyId.Replace("'","''"))' and CustomerAccount eq '$($account.AccountNumber.Replace("'","''"))'")
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/Customers?cross-company=true&`$filter=$filter&`$select=CustomerAccount" -EnvironmentUrl $environmentUrl -Headers $headers)
            if ($existing.Count) {
                Write-InstallLogAction -Message "F&O customer '$($account.AccountNumber)' already exists in '$companyId', skipping."
                continue
            }
            $contact = @($content.Contacts | Where-Object { $_.Id -eq $account.PrimaryContactId -and $_.AccountId -eq $account.Id })
            $body = @{
                dataAreaId=$companyId; CustomerAccount=$account.AccountNumber; PartyType='Organization'
                Name=$account.Name; CustomerGroupId=$groupId; SalesCurrencyCode=$salesCurrencyCode
                LanguageId= if ([string]::IsNullOrWhiteSpace($Config.Settings.DynamicsFOLanguageId)) { 'en-us' } else { $Config.Settings.DynamicsFOLanguageId }
                DeliveryTerms='FOB'; DeliveryMode='10'; SalesTaxGroup='IL'; PaymentTerms='Cash'
                TaxRegistrationId=''; DestinationCode=''; AddressCountryRegionId='USA'
                AddressCity=$account.City; AddressState=$account.State
                AddressZipCode=''; AddressStreet=''; AddressCounty=''; AddressBooks=''
                PrimaryContactPhone=$account.Phone; PrimaryContactFax=''; PrimaryContactPhoneExtension=''
                PrimaryContactEmail= if ($contact.Count -eq 1) { $contact[0].Email } else { '' }
            }
            # Allow environment-specific reference codes without changing the demo accounts.
            foreach ($field in @('DeliveryTerms','DeliveryMode','SalesTaxGroup','PaymentTerms')) {
                $settingName = 'DynamicsFO' + $field
                if (-not [string]::IsNullOrWhiteSpace($Config.Settings.$settingName)) { $body[$field] = $Config.Settings.$settingName }
            }
            if ($account.Country -and $account.Country -ne 'United States') { throw "No F&O country mapping configured for '$($account.Country)'." }
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/data/Customers" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created F&O customer '$($account.AccountNumber)' ($($account.Name)) in '$companyId'." -Level Success
        }
        catch {
            $failed++
            Write-InstallLogAction -Message "Failed to create F&O customer '$($account.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Failed to create $failed F&O customer(s). Review the installation log." }
    Write-Host 'Starting F&O product creation (existing product numbers will be skipped)...'
    $failedProducts = 0
    foreach ($product in $content.Products) {
        try {
            if ([string]::IsNullOrWhiteSpace($product.ProductNumber) -or [string]::IsNullOrWhiteSpace($product.Name)) { throw 'Product requires ProductNumber and Name.' }
            # ProductsV2 contains shared products, so do not filter by legal entity.
            $filter = [Uri]::EscapeDataString("ProductNumber eq '$($product.ProductNumber.Replace("'","''"))'")
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/ProductsV2?cross-company=true&`$filter=$filter&`$select=ProductNumber" -EnvironmentUrl $environmentUrl -Headers $headers)
            if ($existing.Count) {
                Write-InstallLogAction -Message "F&O product '$($product.ProductNumber)' already exists, skipping."
                continue
            }
            $body = @{
                ProductNumber=$product.ProductNumber; ProductType='Item'; ProductSubType='Product'
                ProductName=$product.Name; ProductDescription=$product.Description
                ProductSearchName=$product.ProductNumber.Substring(0, [Math]::Min(20, $product.ProductNumber.Length))
            }
            $json = $body | ConvertTo-Json -Depth 5
            Invoke-RestMethod -Uri "$environmentUrl/data/ProductsV2" -Headers $headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Created shared F&O product '$($product.ProductNumber)' ($($product.Name))." -Level Success
        }
        catch {
            $failedProducts++
            Write-InstallLogAction -Message "Failed to create F&O product '$($product.Name)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failedProducts) { throw "Failed to create $failedProducts F&O product(s). Review the installation log." }
    Add-DynamicsFOReleasedProducts -Config $Config -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId -ConfigPath $ConfigPath -UseConfig:$UseConfig
    Add-DynamicsFOSalesOrders -Config $Config -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId -CurrencyCode $salesCurrencyCode -ConfigPath $ConfigPath -UseConfig:$UseConfig
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
    if ([string]::IsNullOrWhiteSpace($companyId)) { throw 'Settings.DynamicsFOLegalEntityId is required for F&O cleanup.' }
    $content = Get-Content -LiteralPath $ContentPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    # Validate every code before making any delete request.
    $customers = @($content.Accounts | Where-Object { $_ } | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.AccountNumber)) { throw 'Demo account has no AccountNumber.' }
        [string]$_.AccountNumber
    } | Select-Object -Unique)
    $products = @($content.Products | Where-Object { $_ } | ForEach-Object {
        if ([string]::IsNullOrWhiteSpace($_.ProductNumber)) { throw 'Demo product has no ProductNumber.' }
        [string]$_.ProductNumber
    } | Select-Object -Unique)
    $environmentUrl = $environmentUri.GetLeftPart([UriPartial]::Authority)
    $token = Get-PnPAccessToken -Scopes "$environmentUrl/Odata.FullAccess" -ErrorAction Stop
    $headers = @{Authorization="Bearer $token";Accept='application/json'}
    $encodedCompany = [Uri]::EscapeDataString($companyId.Replace("'","''"))
    Remove-DynamicsFOSalesOrders -Content $content -EnvironmentUrl $environmentUrl -Headers $headers -CompanyId $companyId
    $records = @(
        foreach ($code in $customers) {
            $encodedCode = [Uri]::EscapeDataString($code.Replace("'","''"))
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$($companyId.Replace("'","''"))' and CustomerAccount eq '$($code.Replace("'","''"))'")
            @{Label="customer '$code' in '$companyId'";Path="Customers(dataAreaId='$encodedCompany',CustomerAccount='$encodedCode')";Query="Customers?cross-company=true&`$filter=$filter";IsCustomer=$true}
        }
        foreach ($code in $products) {
            $encodedCode = [Uri]::EscapeDataString($code.Replace("'","''"))
            $filter = [Uri]::EscapeDataString("ProductNumber eq '$($code.Replace("'","''"))'")
            @{Label="shared product '$code'";Path="ProductsV2(ProductNumber='$encodedCode')";Query="ProductsV2?cross-company=true&`$filter=$filter";IsCustomer=$false}
        }
    )
    $failed = 0
    foreach ($record in $records) {
        try {
            $existing = @(Get-DynamicsFORecords -Url "$environmentUrl/data/$($record.Query)" -EnvironmentUrl $environmentUrl -Headers $headers)
            if (-not $existing.Count) {
                Write-InstallLogAction -Message "F&O $($record.Label) does not exist, skipping."
                continue
            }
            if ($existing.Count -ne 1) { throw 'Expected exactly one record for the cleanup key.' }
            # Preserve the company's canonical casing from F&O and include cross-company
            # on DELETE as well as GET, so default-company scoping cannot hide the row.
            if ($record.IsCustomer) {
                if ($existing[0].dataAreaId -ne $companyId) { throw 'Customer belongs to a different company.' }
                $returnedCompany = [Uri]::EscapeDataString(([string]$existing[0].dataAreaId).Replace("'","''"))
                $returnedCode = [Uri]::EscapeDataString(([string]$existing[0].CustomerAccount).Replace("'","''"))
                $record.Path = "Customers(dataAreaId='$returnedCompany',CustomerAccount='$returnedCode')"
            }
            Invoke-RestMethod -Uri "$environmentUrl/data/$($record.Path)?cross-company=true" -Headers $headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted F&O $($record.Label)." -Level Success
        }
        catch {
            if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) {
                Write-InstallLogAction -Message "F&O $($record.Label) does not exist, skipping."
                continue
            }
            $failed++
            Write-InstallLogAction -Message "Failed to delete F&O $($record.Label): $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Could not delete $failed F&O demo record(s). Review the cleanup log." }
}

function Add-DynamicsFOSalesOrders {
    param($Config, $Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId, [string]$CurrencyCode,
        [string]$ConfigPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../Configuration/config.json')), [switch]$UseConfig)
    Write-Host "Starting F&O sales order creation in '$CompanyId'..."
    $companyLiteral = $CompanyId.Replace("'","''")
    if (-not @($Content.Orders).Count) { return }
    Write-Host "Retrieving shipping warehouses for F&O company '$CompanyId'..."
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
            if ($accounts.Count -ne 1) { throw 'Invalid order AccountId.' }
            $orderLiteral = $order.OrderNumber.Replace("'","''")
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and (CustomerRequisitionNumber eq '$orderLiteral' or SalesOrderNumber eq '$orderLiteral')")
            $existing = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            # Resolve released items before creating a header; shared products alone are not sellable.
            $items = @{}
            foreach ($line in $order.Lines) {
                $products = @($Content.Products | Where-Object Id -eq $line.ProductId)
                if ($products.Count -ne 1) { throw 'Invalid order product reference.' }
                $product = $products[0]
                $itemFilter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and ProductNumber eq '$($product.ProductNumber.Replace("'","''"))'")
                $released = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/ReleasedProductsV2?cross-company=true&`$filter=$itemFilter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
                if ($released.Count -ne 1) { throw "Product '$($product.ProductNumber)' must first be released and configured for sales in company '$CompanyId'." }
                $items[$line.ProductId] = $released[0]
            }
            if (-not $existing.Count) {
                $customerFilter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and CustomerAccount eq '$($accounts[0].AccountNumber.Replace("'","''"))'")
                $customers = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/Customers?cross-company=true&`$filter=$customerFilter&`$select=CustomerAccount,LanguageId" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
                if ($customers.Count -ne 1) { throw 'Expected one F&O customer for the sales order.' }
                $languageId = [string]$customers[0].LanguageId
                if ([string]::IsNullOrWhiteSpace($languageId)) { $languageId = [string]$Config.Settings.DynamicsFOLanguageId }
                if ([string]::IsNullOrWhiteSpace($languageId)) { $languageId = 'en-us' }
                $body = @{dataAreaId=$CompanyId;CustomerRequisitionNumber=$order.OrderNumber;OrderingCustomerAccountNumber=$accounts[0].AccountNumber;InvoiceCustomerAccountNumber=$accounts[0].AccountNumber;CurrencyCode=$CurrencyCode;SalesOrderName=$order.Name;LanguageId=$languageId}
                if ($null -ne $order.RequestedDeliveryOffset) { $body.RequestedShippingDate=(Get-Date).ToUniversalTime().AddDays([int]$order.RequestedDeliveryOffset).ToString('yyyy-MM-ddTHH:mm:ssZ') }
                $json=$body | ConvertTo-Json
                Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderHeadersV2" -Headers $Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            }
            $resolved = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            if ($resolved.Count -ne 1 -or -not $resolved[0].SalesOrderNumber) { throw 'Expected one generated F&O order for the demo reference.' }
            if ($resolved[0].OrderingCustomerAccountNumber -ne $accounts[0].AccountNumber) { throw 'Order reference belongs to a different customer.' }
            $foOrderNumber = [string]$resolved[0].SalesOrderNumber
            Write-InstallLogAction -Message "Demo order '$($order.OrderNumber)' maps to F&O order '$foOrderNumber' in '$CompanyId'."
            $filter = [Uri]::EscapeDataString("dataAreaId eq '$companyLiteral' and SalesOrderNumber eq '$($foOrderNumber.Replace("'","''"))'")
            $existingLines = @(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderLines?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
            $lineNumber=0
            foreach ($line in $order.Lines) {
                $lineNumber++
                $matches=@($existingLines | Where-Object { [decimal]$_.LineNumber -eq $lineNumber })
                $item=$items[$line.ProductId]
                if ($matches.Count) {
                    if ($matches.Count -ne 1 -or $matches[0].ItemNumber -ne $item.ItemNumber -or [decimal]$matches[0].OrderedSalesQuantity -ne [decimal]$line.Quantity -or [decimal]$matches[0].SalesPrice -ne [decimal]$line.UnitPrice) { throw "Existing order line $lineNumber conflicts with the demo data." }
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
            Write-InstallLogAction -Message "Provisioned F&O sales order '$($order.OrderNumber)' and its lines in '$CompanyId'. Source Dynamics status: $($order.Status); F&O posting is not performed." -Level Success
        }
        catch {
            $failed++
            Write-InstallLogAction -Message "Failed to create F&O order '$($order.OrderNumber)': $($_.Exception.Message) $($_.ErrorDetails.Message)" -Level Error
        }
    }
    if ($failed) { throw "Failed to provision $failed F&O sales order(s)." }
}

function Remove-DynamicsFOSalesOrders {
    param($Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId)
    # Validate all source codes before deleting lines or headers.
    $codes=@($Content.Orders | ForEach-Object { if ([string]::IsNullOrWhiteSpace($_.OrderNumber)) {throw 'OrderNumber is required for cleanup.'}; [string]$_.OrderNumber } | Select-Object -Unique)
    foreach ($code in $codes) {
        $referenceFilter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))' and (CustomerRequisitionNumber eq '$($code.Replace("'","''"))' or SalesOrderNumber eq '$($code.Replace("'","''"))')")
        $resolved=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$referenceFilter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        if (-not $resolved.Count) { continue }
        if ($resolved.Count -ne 1 -or -not $resolved[0].SalesOrderNumber) { throw "Multiple or invalid F&O orders for demo reference '$code'." }
        $sourceOrder=@($Content.Orders | Where-Object OrderNumber -eq $code)[0]
        $sourceAccount=@($Content.Accounts | Where-Object Id -eq $sourceOrder.AccountId)[0]
        if ($resolved[0].OrderingCustomerAccountNumber -ne $sourceAccount.AccountNumber) { throw 'Cleanup order reference belongs to a different customer.' }
        $code=[string]$resolved[0].SalesOrderNumber
        $filter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))' and SalesOrderNumber eq '$($code.Replace("'","''"))'")
        $lines=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderLines?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line.InventoryLotId) -or $line.dataAreaId -ne $CompanyId -or $line.SalesOrderNumber -ne $code) {throw 'Unexpected sales order line cleanup key.'}
            $companyKey=[Uri]::EscapeDataString(([string]$line.dataAreaId).Replace("'","''"))
            $lotKey=[Uri]::EscapeDataString(([string]$line.InventoryLotId).Replace("'","''"))
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderLines(dataAreaId='$companyKey',InventoryLotId='$lotKey')?cross-company=true" -Headers $Headers -Method Delete -ErrorAction Stop | Out-Null
        }
        $orders=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/SalesOrderHeadersV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
        foreach ($order in $orders) {
            if ($order.dataAreaId -ne $CompanyId -or $order.SalesOrderNumber -ne $code) {throw 'Unexpected sales order cleanup key.'}
            $companyKey=[Uri]::EscapeDataString(([string]$order.dataAreaId).Replace("'","''"))
            $orderKey=[Uri]::EscapeDataString(([string]$order.SalesOrderNumber).Replace("'","''"))
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/SalesOrderHeadersV2(dataAreaId='$companyKey',SalesOrderNumber='$orderKey')?cross-company=true" -Headers $Headers -Method Delete -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Deleted F&O order '$code' and its lines in '$CompanyId'." -Level Success
        }
    }
}

function Add-DynamicsFOReleasedProducts {
    param($Config, $Content, [string]$EnvironmentUrl, [hashtable]$Headers, [string]$CompanyId, [string]$ConfigPath, [switch]$UseConfig)
    Write-Host "Checking released products in '$CompanyId'..."
    $filter=[Uri]::EscapeDataString("dataAreaId eq '$($CompanyId.Replace("'","''"))'")
    $released=@(Get-DynamicsFORecords -Url "$EnvironmentUrl/data/ReleasedProductsV2?cross-company=true&`$filter=$filter" -EnvironmentUrl $EnvironmentUrl -Headers $Headers)
    $missing=@($Content.Products | Where-Object { $number=$_.ProductNumber; -not @($released | Where-Object ProductNumber -eq $number).Count })
    if (-not $missing.Count) { return }
    # Take valid company-specific setup from an explicitly selected existing item.
    $templates=@($released | Where-Object { $_.InventoryUnitSymbol -and $_.SalesUnitSymbol -and $_.PurchaseUnitSymbol -and $_.ItemModelGroupId -and $_.ProductGroupId } | Sort-Object ItemNumber)
    # Some F&O versions expose the purchase unit as PurchUnitSymbol.
    if (-not $templates.Count) {
        $templates=@($released | Where-Object { $_.InventoryUnitSymbol -and $_.SalesUnitSymbol -and $_.PurchUnitSymbol -and $_.ItemModelGroupId -and $_.ProductGroupId } | Sort-Object ItemNumber)
    }
    if (-not $templates.Count) { throw "Retrieved $($released.Count) released items in '$CompanyId', but none has InventoryUnitSymbol, SalesUnitSymbol, PurchaseUnitSymbol/PurchUnitSymbol, ProductGroupId, and ItemModelGroupId populated. These fields are required for a setup template." }
    Write-Host 'Select an existing item whose units, inventory groups, and default site/warehouse will be used for the demo products.'
    $saved=if ($Config.Settings.DynamicsFOProductTemplateCompany -eq $CompanyId) { $Config.Settings.DynamicsFOProductTemplateItemNumber } else { '' }
    $template=Select-DynamicsFORecord -Records $templates -CodeField ItemNumber -NameField SearchName -Prompt 'Select the product setup template number' -SavedCode $saved -UseConfig:$UseConfig
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOProductTemplateCompany -NotePropertyValue $CompanyId -Force
    $Config.Settings | Add-Member -NotePropertyName DynamicsFOProductTemplateItemNumber -NotePropertyValue $template.ItemNumber -Force
    $Config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
    foreach ($product in $missing) {
        $collision=@($released | Where-Object ItemNumber -eq $product.ProductNumber)
        if ($collision.Count) { throw "Item number '$($product.ProductNumber)' already belongs to another shared product in '$CompanyId'." }
        # Subtype is inherited from the shared product and is not insertable here.
        $body=@{dataAreaId=$CompanyId;ItemNumber=$product.ProductNumber;ProductNumber=$product.ProductNumber;SalesPrice=[decimal]$product.UnitPrice;SalesPriceQuantity=1}
        foreach ($field in @('InventoryUnitSymbol','SalesUnitSymbol','PurchaseUnitSymbol','PurchUnitSymbol','ProductGroupId','ItemModelGroupId','StorageDimensionGroupName','TrackingDimensionGroupName','DefaultOrderSettingsInventorySiteId','DefaultOrderSettingsInventoryWarehouseId','SalesSalesTaxItemGroupCode')) {
            if (-not [string]::IsNullOrWhiteSpace($template.$field)) { $body[$field]=$template.$field }
        }
        $json=$body | ConvertTo-Json
        try {
            Invoke-RestMethod -Uri "$EnvironmentUrl/data/ReleasedProductsV2" -Headers $Headers -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($json)) -ErrorAction Stop | Out-Null
            Write-InstallLogAction -Message "Released product '$($product.ProductNumber)' in '$CompanyId' using setup from '$($template.ItemNumber)'." -Level Success
        }
        catch { throw "Failed to release product '$($product.ProductNumber)' in '$CompanyId': $($_.Exception.Message) $($_.ErrorDetails.Message)" }
    }
}

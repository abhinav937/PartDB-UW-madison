<#
.SYNOPSIS
    Import combined_components_inventory CSV into Part-DB with DigiKey product links.

.DESCRIPTION
    Reads the GaN Module combined inventory CSV, creates one Part per unique MPN
    (idempotent), sets stock from on_hand, and attaches DigiKey orderdetails with
    real product URLs via the DigiKey Product Information API.

    Dry-run by default. Pass -Apply to write.

.PARAMETER CsvPath
    Path to the inventory CSV.

.PARAMETER Token
    Part-DB API token (Edit scope). Defaults to PARTDB_TOKEN env var.

.PARAMETER BaseUrl
    Part-DB base URL. Default http://localhost:8080

.PARAMETER DigiKeyClientId / DigiKeyClientSecret
    DigiKey OAuth app credentials (defaults from secrets.env if present).

.PARAMETER Apply
    Actually write data. Without this, only previews.

.EXAMPLE
    $env:PARTDB_TOKEN = "tcp_..."
    .\import_csv_inventory.ps1
    .\import_csv_inventory.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$CsvPath = "C:\Users\abhin\Box\Abhinav\inventory-management-files\combined_components_inventory_6_01.csv",
    [string]$Token = $env:PARTDB_TOKEN,
    [string]$BaseUrl = "http://localhost:8080",
    [string]$DigiKeyClientId = $env:PROVIDER_DIGIKEY_CLIENT_ID,
    [string]$DigiKeyClientSecret = $env:PROVIDER_DIGIKEY_SECRET,
    [string]$StorageLocationName = "SSMG Box",
    [switch]$Apply,
    [switch]$SkipDigiKey
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd("/")

if (-not $Token) {
    throw "No API token. Set `$env:PARTDB_TOKEN or pass -Token."
}
if (-not (Test-Path $CsvPath)) {
    throw "CSV not found: $CsvPath"
}

# Load DigiKey creds from secrets.env next to docker-compose if not set
$secretsPath = Join-Path (Split-Path $PSScriptRoot -Parent) "secrets.env"
if ((-not $DigiKeyClientId -or -not $DigiKeyClientSecret) -and (Test-Path $secretsPath)) {
    Get-Content $secretsPath | ForEach-Object {
        if ($_ -match '^\s*PROVIDER_DIGIKEY_CLIENT_ID=(.+)$') { $DigiKeyClientId = $Matches[1].Trim() }
        if ($_ -match '^\s*PROVIDER_DIGIKEY_SECRET=(.+)$') { $DigiKeyClientSecret = $Matches[1].Trim() }
    }
}

$Headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }

function Invoke-Api {
    param([string]$Method, [string]$Path, [object]$Body)
    $uri = "$BaseUrl$Path"
    try {
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 10 -Compress
            # API Platform requires merge-patch+json for PATCH
            $ct = if ($Method -eq "PATCH") { "application/merge-patch+json" } else { "application/json" }
            $reqHeaders = @{
                Authorization = $Headers.Authorization
                Accept        = "application/json"
            }
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $reqHeaders `
                -ContentType $ct -Body ([System.Text.Encoding]::UTF8.GetBytes($json))
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers
    } catch {
        $detail = ""
        if ($_.Exception.Response) {
            try {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $detail = $reader.ReadToEnd()
            } catch {}
        }
        throw "API $Method $Path failed: $($_.Exception.Message)`n$detail"
    }
}

function Get-Collection {
    param([string]$Path)
    $r = Invoke-Api -Method GET -Path $Path
    if ($null -eq $r) { return @() }
    if ($r.PSObject.Properties.Name -contains "hydra:member") { return @($r."hydra:member") }
    return @($r)
}

function Get-CategoryMap {
    $map = @{}
    foreach ($c in (Get-Collection "/api/categories?itemsPerPage=100")) {
        $map[$c.name] = "/api/categories/$($c.id)"
    }
    return $map
}

function Ensure-Category {
    param([string]$Name, [hashtable]$Map)
    if ($Map.ContainsKey($Name)) { return $Map[$Name] }
    if ($Apply) {
        $cat = Invoke-Api -Method POST -Path "/api/categories" -Body @{ name = $Name }
        $iri = "/api/categories/$($cat.id)"
        $Map[$Name] = $iri
        Write-Host "  Created category '$Name' -> $iri" -ForegroundColor Green
        return $iri
    }
    Write-Host "  [dry-run] would create category '$Name'" -ForegroundColor Yellow
    return $null
}

function Resolve-CategoryName {
    param([string]$CsvCategory, [string]$Description)
    if ($null -eq $Description) { $Description = "" }
    if ($null -eq $CsvCategory) { $CsvCategory = "" }
    $d = $Description.ToLowerInvariant()
    $c = $CsvCategory.ToLowerInvariant()

    if ($c -match "test point" -or $d -match "test point|keystone") { return "TestPoints" }
    if ($c -match "connector" -or $d -match "conn |header|terminal|mmcx|usb|jack,|socket") {
        if ($d -notmatch "test point") { return "Connectors" }
    }
    if ($d -match "cap cer|capacitor|cap\b|x7r|x5r|c0g|mlcc" -or $c -match "decoupling") { return "Capacitors" }
    if ($d -match "resistor|ohms|ohm\b|thick film|thin film" -or $c -match "gate loop" -and $d -match "r\d|res") { return "Resistors" }
    if ($d -match "zener|diode|schottky") { return "Diode" }
    if ($d -match "\bled\b|led ") { return "LEDs" }
    if ($d -match "inductor|ferrite bead|common mode") { return "Inductor" }
    if ($d -match "fuse") { return "Fuse" }
    if ($d -match "gate driver|magnetic coupling") { return "Gate Drivers" }
    if ($d -match "mosfet|ganfet|n-channel|p-channel|gan ") { return "MOSFET" }
    if ($d -match "ldo|voltage regulator|linear regulator|positive fixed") { return "LDO" }
    if ($d -match "dc dc|dc-dc|isolated module|converter|switching regulator") { return "Power Supplies" }
    if ($d -match "op.?amp|amplifier|line driver|rs-?485|transceiver") { return "OpAmp" }
    if ($c -match "active") { return "IC" }
    if ($c -match "passive|gate loop") {
        if ($d -match "cap|pf|uf|µf|nf") { return "Capacitors" }
        return "Resistors"
    }
    if ($c -match "connector") { return "Connectors" }
    return "IC"
}

function Get-ManufacturerIri {
    param([string]$Name, [hashtable]$Cache)
    if (-not $Name) { return $null }
    if ($Cache.ContainsKey($Name)) { return $Cache[$Name] }
    $existing = Get-Collection "/api/manufacturers?itemsPerPage=100" | Where-Object { $_.name -eq $Name } | Select-Object -First 1
    if ($existing) {
        $iri = "/api/manufacturers/$($existing.id)"
        $Cache[$Name] = $iri
        return $iri
    }
    if ($Apply) {
        $m = Invoke-Api -Method POST -Path "/api/manufacturers" -Body @{ name = $Name }
        $iri = "/api/manufacturers/$($m.id)"
        $Cache[$Name] = $iri
        Write-Host "  Created manufacturer '$Name'" -ForegroundColor Green
        return $iri
    }
    $Cache[$Name] = $null
    return $null
}

# ----- DigiKey OAuth + search -----
$script:DkAccessToken = $null
$script:DkTokenExpiry = [datetime]::MinValue

function Read-DigiKeyRefreshToken {
    $php = @'
<?php
$db = new PDO('sqlite:/var/www/html/var/db/app.db');
echo $db->query("SELECT refresh_token FROM oauth_tokens WHERE name='ip_digikey_oauth'")->fetchColumn();
'@
    $php | docker exec -i -u www-data partdb tee /tmp/read_dk_refresh.php | Out-Null
    $out = docker exec -u www-data partdb php /tmp/read_dk_refresh.php 2>$null
    if ($out) { return "$out".Trim() }
    return $null
}

function Save-DigiKeyTokens {
    param([string]$Access, [string]$Refresh, [string]$ExpiresAt)
    $php = @"
<?php
`$db = new PDO('sqlite:/var/www/html/var/db/app.db');
`$st = `$db->prepare("UPDATE oauth_tokens SET token = ?, refresh_token = ?, expires_at = ?, last_modified = datetime('now') WHERE name = 'ip_digikey_oauth'");
`$st->execute([\$argv[1], \$argv[2], \$argv[3]]);
echo 'ok';
"@
    # Avoid argv escaping issues: write values into a small PHP file
    $safeAccess = $Access.Replace("'", "\\'")
    $safeRefresh = $Refresh.Replace("'", "\\'")
    $safeExp = $ExpiresAt.Replace("'", "\\'")
    $php2 = @"
<?php
`$db = new PDO('sqlite:/var/www/html/var/db/app.db');
`$st = `$db->prepare("UPDATE oauth_tokens SET token = ?, refresh_token = ?, expires_at = ?, last_modified = datetime('now') WHERE name = 'ip_digikey_oauth'");
`$st->execute(['$safeAccess', '$safeRefresh', '$safeExp']);
echo 'ok';
"@
    $php2 | docker exec -i -u www-data partdb tee /tmp/save_dk_tokens.php | Out-Null
    docker exec -u www-data partdb php /tmp/save_dk_tokens.php | Out-Null
}

function Ensure-DigiKeyToken {
    if ($SkipDigiKey) { return $false }
    if (-not $DigiKeyClientId -or -not $DigiKeyClientSecret) {
        Write-Warning "DigiKey credentials missing; will use search-link orderdetails only."
        return $false
    }
    if ($script:DkAccessToken -and (Get-Date) -lt $script:DkTokenExpiry) { return $true }

    $refresh = $null
    try {
        $refresh = Read-DigiKeyRefreshToken
    } catch {
        Write-Warning "Could not read DigiKey refresh token from container: $_"
    }
    if (-not $refresh) {
        Write-Warning "No DigiKey refresh token available."
        return $false
    }

    $body = @{
        client_id     = $DigiKeyClientId
        client_secret = $DigiKeyClientSecret
        refresh_token = $refresh
        grant_type    = "refresh_token"
    }
    try {
        $tok = Invoke-RestMethod -Method POST -Uri "https://api.digikey.com/v1/oauth2/token" `
            -Body $body -ContentType "application/x-www-form-urlencoded" -TimeoutSec 30
    } catch {
        Write-Warning "DigiKey token refresh failed: $($_.Exception.Message)"
        return $false
    }

    $script:DkAccessToken = $tok.access_token
    $script:DkTokenExpiry = (Get-Date).AddSeconds([int]$tok.expires_in - 60)
    $expiresAt = $script:DkTokenExpiry.ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")

    try {
        Save-DigiKeyTokens -Access $tok.access_token -Refresh $tok.refresh_token -ExpiresAt $expiresAt
    } catch {
        Write-Warning "Could not persist DigiKey token: $_"
    }
    return $true
}

function Search-DigiKey {
    param([string]$Keyword)
    if (-not (Ensure-DigiKeyToken)) { return $null }

    $dkHeaders = @{
        Authorization              = "Bearer $($script:DkAccessToken)"
        "X-DIGIKEY-Client-Id"      = $DigiKeyClientId
        "X-DIGIKEY-Locale-Site"    = "US"
        "X-DIGIKEY-Locale-Language"= "en"
        "X-DIGIKEY-Locale-Currency"= "USD"
        "X-DIGIKEY-Customer-Id"    = "0"
        "Content-Type"             = "application/json"
    }
    $req = @{
        Keywords = $Keyword
        Limit    = 10
        Offset   = 0
        FilterOptionsRequest = @{ MarketPlaceFilter = "ExcludeMarketPlace" }
    } | ConvertTo-Json -Depth 5

    try {
        $resp = Invoke-RestMethod -Method POST -Uri "https://api.digikey.com/products/v4/search/keyword" `
            -Headers $dkHeaders -Body $req -TimeoutSec 45
    } catch {
        Write-Warning "DigiKey search failed for '$Keyword': $($_.Exception.Message)"
        return $null
    }

    if (-not $resp.Products -or $resp.Products.Count -eq 0) { return $null }

    # Prefer exact MPN match (case-insensitive), else first product
    $exact = $resp.Products | Where-Object {
        $_.ManufacturerProductNumber -and
        ($_.ManufacturerProductNumber -eq $Keyword -or
         $_.ManufacturerProductNumber -like "$Keyword*" -or
         $Keyword -like "$($_.ManufacturerProductNumber)*")
    } | Select-Object -First 1
    $prod = if ($exact) { $exact } else { $resp.Products[0] }

    $var = $prod.ProductVariations | Select-Object -First 1
    $desc = $null
    if ($prod.Description) {
        $desc = $prod.Description.DetailedDescription
        if (-not $desc) { $desc = $prod.Description.ProductDescription }
    }

    return [pscustomobject]@{
        Mpn         = $prod.ManufacturerProductNumber
        DkPn        = if ($var) { $var.DigiKeyProductNumber } else { $null }
        Url         = $prod.ProductUrl
        Description = $desc
        Manufacturer= if ($prod.Manufacturer) { $prod.Manufacturer.Name } else { $null }
        PhotoUrl    = $prod.PhotoUrl
    }
}

# ----- Load & aggregate CSV -----
$raw = Import-Csv $CsvPath
$parts = $raw | Group-Object part_number | ForEach-Object {
    $rows = @($_.Group)
    $notes = @($rows | ForEach-Object { $_.notes } | Where-Object { $_ } | Select-Object -Unique)
    $boards = @($rows | ForEach-Object { $_.board } | Where-Object { $_ } | Select-Object -Unique)
    $cats = @($rows | ForEach-Object { $_.category } | Where-Object { $_ } | Select-Object -Unique)
    $onHand = ($rows | ForEach-Object { [int]($_.on_hand) } | Measure-Object -Maximum).Maximum
    $bom = ($rows | ForEach-Object {
        if ($_.board) { "$($_.board):$($_.qty_per_board)/board" } else { $null }
    } | Where-Object { $_ } | Select-Object -Unique) -join "; "

    [pscustomobject]@{
        PartNumber  = $_.Name.Trim()
        Description = ($rows | Select-Object -First 1).description
        CsvCategory = ($cats -join "; ")
        OnHand      = [int]$onHand
        Boards      = ($boards -join ", ")
        Notes       = ($notes -join " | ")
        BomUsage    = $bom
        Source      = ($rows | Select-Object -First 1).source
        InvDate     = ($rows | Select-Object -First 1).inventory_date
    }
} | Where-Object { $_.PartNumber } | Sort-Object PartNumber

Write-Host ""
Write-Host ("Mode: " + $(if ($Apply) { "APPLY -> $BaseUrl" } else { "DRY RUN (no writes)" })) -ForegroundColor Cyan
Write-Host ("CSV unique MPNs: {0}" -f $parts.Count)
Write-Host ""

$categoryMap = Get-CategoryMap
$mfrCache = @{}

# Index existing parts by name and MPN
$existingParts = Get-Collection "/api/parts?itemsPerPage=500"
$byName = @{}
foreach ($p in $existingParts) {
    $byName[$p.name] = $p
    if ($p.manufacturer_product_number) { $byName[$p.manufacturer_product_number] = $p }
}

$created = 0; $skipped = 0; $updatedStock = 0; $dkLinked = 0; $dkMiss = 0; $errors = 0

# Ensure DigiKey supplier
$supplierIri = "/api/suppliers/1"
$suppliers = Get-Collection "/api/suppliers?itemsPerPage=50"
$dkSup = $suppliers | Where-Object { $_.name -eq "DigiKey" } | Select-Object -First 1
if ($dkSup) { $supplierIri = "/api/suppliers/$($dkSup.id)" }

$dkReady = Ensure-DigiKeyToken
Write-Host ("DigiKey API: " + $(if ($dkReady) { "connected" } else { "fallback search links" })) -ForegroundColor $(if ($dkReady) { "Green" } else { "Yellow" })
Write-Host ""

foreach ($item in $parts) {
    $mpn = $item.PartNumber
    Write-Host "---- $mpn (on_hand=$($item.OnHand)) ----"

    try {
        $catName = Resolve-CategoryName -CsvCategory $item.CsvCategory -Description $item.Description
        $catIri = Ensure-Category -Name $catName -Map $categoryMap

        $commentParts = @()
        if ($item.Source) { $commentParts += "Source: $($item.Source) ($($item.InvDate))" }
        if ($item.Boards) { $commentParts += "Boards: $($item.Boards)" }
        if ($item.BomUsage) { $commentParts += "BOM: $($item.BomUsage)" }
        if ($item.Notes) { $commentParts += "Notes: $($item.Notes)" }
        if ($item.CsvCategory) { $commentParts += "CSV category: $($item.CsvCategory)" }
        $comment = $commentParts -join "`n"

        # DigiKey lookup first (enriches description/mfr)
        $dk = $null
        if (-not $SkipDigiKey) {
            $dk = Search-DigiKey -Keyword $mpn
            if (-not $dk -and $mpn -match '-ND$') {
                # try without DigiKey-style suffix noise
                $dk = Search-DigiKey -Keyword ($mpn -replace '^[0-9]+-','' -replace '-ND$','')
            }
            Start-Sleep -Milliseconds 200  # be polite to DigiKey
        }

        $description = if ($item.Description) { $item.Description } elseif ($dk) { $dk.Description } else { "" }
        if ($description.Length -gt 250) { $description = $description.Substring(0, 247) + "..." }

        # Tag for Luke's inventory (searchable in Part-DB)
        $lukeTag = "Luke's Components"
        $tagList = @($lukeTag, "gan-module-rev3", "csv-import-2026-06-01")
        $tagsStr = ($tagList -join ",")

        $partObj = $null
        if ($byName.ContainsKey($mpn)) {
            $partObj = $byName[$mpn]
            Write-Host "  Part exists id=$($partObj.id)"
            $skipped++
            # Ensure Luke's tag is present on existing parts too
            if ($Apply -and $partObj) {
                $existingTags = @()
                if ($partObj.tags) {
                    $existingTags = @($partObj.tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                }
                $merged = @($existingTags + $tagList | Select-Object -Unique)
                $mergedStr = $merged -join ","
                if ($mergedStr -ne $partObj.tags) {
                    Invoke-Api -Method PATCH -Path "/api/parts/$($partObj.id)" -Body @{ tags = $mergedStr } | Out-Null
                    Write-Host "  Updated tags -> $mergedStr" -ForegroundColor Green
                }
            }
        } else {
            $body = @{
                name                         = $mpn
                description                  = $description
                manufacturer_product_number  = $mpn
                comment                      = $comment
                tags                         = $tagsStr
            }
            if ($catIri) { $body.category = $catIri }
            if ($dk -and $dk.Manufacturer) {
                $mIri = Get-ManufacturerIri -Name $dk.Manufacturer -Cache $mfrCache
                if ($mIri) { $body.manufacturer = $mIri }
            }
            if ($dk -and $dk.Url) { $body.manufacturer_product_url = $dk.Url }

            if ($Apply) {
                $partObj = Invoke-Api -Method POST -Path "/api/parts" -Body $body
                $byName[$mpn] = $partObj
                Write-Host "  Created part id=$($partObj.id) category=$catName tags=$tagsStr" -ForegroundColor Green
                $created++
            } else {
                Write-Host "  [dry-run] create part category=$catName tags=$tagsStr desc=$description" -ForegroundColor Yellow
                if ($dk) { Write-Host "  [dry-run] DigiKey $($dk.DkPn) $($dk.Url)" -ForegroundColor Yellow }
            }
        }

        # Stock lot
        if ($item.OnHand -ge 0 -and ($partObj -or -not $Apply)) {
            if ($Apply -and $partObj) {
                $partIri = "/api/parts/$($partObj.id)"
                $lots = Get-Collection "/api/part_lots?itemsPerPage=50" | Where-Object { $_.part.id -eq $partObj.id -and $_.description -like "*GaN Module inventory*" }
                if ($lots -and $lots.Count -gt 0) {
                    $lot = $lots | Select-Object -First 1
                    if ([double]$lot.amount -ne [double]$item.OnHand) {
                        Invoke-Api -Method PATCH -Path "/api/part_lots/$($lot.id)" -Body @{ amount = $item.OnHand } | Out-Null
                        Write-Host "  Updated lot amount -> $($item.OnHand)" -ForegroundColor Green
                        $updatedStock++
                    } else {
                        Write-Host "  Lot already amount=$($item.OnHand)"
                    }
                } else {
                    $lotBody = @{
                        part        = $partIri
                        amount      = $item.OnHand
                        description = "GaN Module inventory $($item.InvDate)"
                        comment     = "Imported from combined_components_inventory_6_01.csv"
                    }
                    $lot = Invoke-Api -Method POST -Path "/api/part_lots" -Body $lotBody
                    Write-Host "  Created lot id=$($lot.id) amount=$($item.OnHand)" -ForegroundColor Green
                    $updatedStock++
                }
            } else {
                Write-Host "  [dry-run] stock lot amount=$($item.OnHand)" -ForegroundColor Yellow
            }
        }

        # DigiKey orderdetail
        $productUrl = if ($dk -and $dk.Url) { $dk.Url } else { "https://www.digikey.com/en/products/result?keywords=$([uri]::EscapeDataString($mpn))" }
        $supplierPn = if ($dk -and $dk.DkPn) { $dk.DkPn } else { $mpn }

        if ($Apply -and $partObj) {
            $partIri = "/api/parts/$($partObj.id)"
            $ods = Get-Collection "/api/orderdetails?itemsPerPage=50" | Where-Object { $_.part.id -eq $partObj.id -and $_.supplier.id -eq 1 }
            if ($ods -and $ods.Count -gt 0) {
                $od = $ods | Select-Object -First 1
                if (-not $od.supplier_product_url -or $od.supplier_product_url -like "*/result?*") {
                    if ($dk -and $dk.Url) {
                        Invoke-Api -Method PATCH -Path "/api/orderdetails/$($od.id)" -Body @{
                            supplierpartnr       = $supplierPn
                            supplier_product_url = $productUrl
                        } | Out-Null
                        Write-Host "  Updated DigiKey link -> $productUrl" -ForegroundColor Green
                        $dkLinked++
                    } else {
                        Write-Host "  Orderdetail exists (no better DigiKey match)"
                        $dkMiss++
                    }
                } else {
                    Write-Host "  DigiKey link already set"
                    $dkLinked++
                }
            } else {
                Invoke-Api -Method POST -Path "/api/orderdetails" -Body @{
                    part                 = $partIri
                    supplier             = $supplierIri
                    supplierpartnr       = $supplierPn
                    supplier_product_url = $productUrl
                } | Out-Null
                if ($dk) {
                    Write-Host "  Linked DigiKey $supplierPn -> $productUrl" -ForegroundColor Green
                    $dkLinked++
                } else {
                    Write-Host "  Linked DigiKey search URL (no exact product)" -ForegroundColor Yellow
                    $dkMiss++
                }
            }
        } else {
            if ($dk) {
                Write-Host "  [dry-run] DigiKey $supplierPn -> $productUrl" -ForegroundColor Yellow
            } else {
                Write-Host "  [dry-run] DigiKey search link only" -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        $errors++
    }
}

Write-Host ""
Write-Host "========== SUMMARY ==========" -ForegroundColor Cyan
Write-Host ("Created parts:     {0}" -f $created)
Write-Host ("Already existed:   {0}" -f $skipped)
Write-Host ("Stock lots set:    {0}" -f $updatedStock)
Write-Host ("DigiKey linked:    {0}" -f $dkLinked)
Write-Host ("DigiKey miss/link: {0}" -f $dkMiss)
Write-Host ("Errors:            {0}" -f $errors)
if (-not $Apply) {
    Write-Host "This was a DRY RUN. Re-run with -Apply to write." -ForegroundColor Cyan
}

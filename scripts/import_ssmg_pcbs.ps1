<#
.SYNOPSIS
    Bulk-register SSMG PCB barcodes into Part-DB via the REST API.

.DESCRIPTION
    Reads a list of IM-SSMG-... codes (see codes.txt), parses each one, and creates:
      - a "SSMG" category (once),
      - one "design" Part per (module x material x thickness), with module / material /
        thickness stored as Part parameters,
      - one Part lot per physical unit (amount 1) whose User barcode is the full code,
        so scanning the PCB's QR opens that board in Part-DB.

    The script is IDEMPOTENT: re-running it will not create duplicates (it looks up
    existing parts by name and existing lots by user_barcode first).

    By default it runs as a DRY RUN and only prints what it would do. Pass -Apply to write.

.PARAMETER Token
    Part-DB API token (scope: Edit). Falls back to the PARTDB_TOKEN environment variable.
    Create one in Part-DB: User settings -> API tokens -> New token (scope "Edit").

.PARAMETER BaseUrl
    Part-DB base URL. Default http://localhost:8080 (run this on the laptop hosting Part-DB).

.PARAMETER CodesFile
    Path to the file containing one code per line. Default: codes.txt next to this script.

.PARAMETER Apply
    Actually create data. Without this switch the script only previews (dry run).

.EXAMPLE
    # Preview only:
    $env:PARTDB_TOKEN = "tcp_xxx..."
    .\import_ssmg_pcbs.ps1

    # Actually create:
    .\import_ssmg_pcbs.ps1 -Apply
#>
[CmdletBinding()]
param(
    [string]$Token = $env:PARTDB_TOKEN,
    [string]$BaseUrl = "http://localhost:8080",
    [string]$CodesFile = (Join-Path $PSScriptRoot "codes.txt"),
    [switch]$Apply
)

$ErrorActionPreference = "Stop"
$BaseUrl = $BaseUrl.TrimEnd("/")

# ----- Friendly lookup tables (extend these as new modules/materials appear) -----
$ModuleNames = @{
    "MMS" = "Marx Modular Stage (power stage card)"
    "CTL" = "Central Transmission Line"
}
$MaterialNames = @{
    "FR4"   = "FR4 (e.g. S1000H)"
    "ROGRS" = "Rogers"
}
$CategoryName = "SSMG"

if (-not $Token) {
    throw "No API token. Set `$env:PARTDB_TOKEN or pass -Token. Create one in Part-DB: User settings -> API tokens (scope Edit)."
}

$Headers = @{ Authorization = "Bearer $Token"; Accept = "application/json" }

function Invoke-Api {
    param(
        [string]$Method,
        [string]$Path,
        [object]$Body
    )
    $uri = "$BaseUrl$Path"
    try {
        if ($Body) {
            $json = $Body | ConvertTo-Json -Depth 8
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers `
                -ContentType "application/json" -Body $json
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $Headers
    } catch {
        $resp = $_.Exception.Response
        $detail = ""
        if ($resp) {
            try {
                $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
                $detail = $reader.ReadToEnd()
            } catch {}
        }
        throw "API $Method $Path failed: $($_.Exception.Message)`n$detail"
    }
}

# Collections returned as plain JSON array (Accept: application/json). Be tolerant of
# either a bare array or a hydra envelope just in case.
function Get-Collection {
    param([string]$Path)
    $r = Invoke-Api -Method GET -Path $Path
    if ($null -eq $r) { return @() }
    if ($r.PSObject.Properties.Name -contains "hydra:member") { return @($r."hydra:member") }
    return @($r)
}

# ----- Parse codes -----
if (-not (Test-Path $CodesFile)) { throw "Codes file not found: $CodesFile" }

$codes = Get-Content $CodesFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }

if (-not $codes) { throw "No codes found in $CodesFile" }

$parsed = foreach ($code in $codes) {
    $t = $code.Split("-")
    if ($t.Count -ne 8 -or $t[0] -ne "IM" -or $t[1] -ne "SSMG") {
        Write-Warning "Skipping malformed code (expected 8 IM-SSMG-... segments): $code"
        continue
    }
    $module = $t[4]; $thickTok = $t[5]; $material = $t[6]; $unit = $t[7]
    [pscustomobject]@{
        Code        = $code
        Day         = $t[2]
        Month       = $t[3]
        Module      = $module
        ModuleFull  = if ($ModuleNames.ContainsKey($module)) { $ModuleNames[$module] } else { $module }
        ThickTok    = $thickTok
        ThickMm     = [double]($thickTok -replace "M", ".")
        Material    = $material
        MaterialFull= if ($MaterialNames.ContainsKey($material)) { $MaterialNames[$material] } else { $material }
        Unit        = $unit
        PartName    = "SSMG-$module-$material-$thickTok"
    }
}

if (-not $parsed) { throw "No valid codes to process." }

Write-Host ""
Write-Host ("Mode: " + $(if ($Apply) { "APPLY (writing to $BaseUrl)" } else { "DRY RUN (no changes)" })) -ForegroundColor Cyan
Write-Host ("Codes: {0}   Designs: {1}" -f $parsed.Count, ($parsed | Select-Object PartName -Unique).Count)
Write-Host ""

# ----- 1) Ensure category -----
$categoryIri = $null
$existingCat = Get-Collection "/api/categories?name=$CategoryName" | Where-Object { $_.name -eq $CategoryName } | Select-Object -First 1
if ($existingCat) {
    $categoryIri = "/api/categories/$($existingCat.id)"
    Write-Host "Category '$CategoryName' exists -> $categoryIri"
} elseif ($Apply) {
    $cat = Invoke-Api -Method POST -Path "/api/categories" -Body @{ name = $CategoryName }
    $categoryIri = "/api/categories/$($cat.id)"
    Write-Host "Created category '$CategoryName' -> $categoryIri" -ForegroundColor Green
} else {
    Write-Host "[dry-run] would create category '$CategoryName'" -ForegroundColor Yellow
}

# ----- 2) Ensure design parts (one per unique PartName) -----
$partIriByName = @{}
foreach ($design in ($parsed | Sort-Object PartName -Unique)) {
    $name = $design.PartName

    $existingPart = Get-Collection "/api/parts?name=$name" | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if ($existingPart) {
        $partIriByName[$name] = "/api/parts/$($existingPart.id)"
        Write-Host "Design part '$name' exists -> $($partIriByName[$name])"
        continue
    }

    $body = @{
        name        = $name
        description = "Impedance-matched Solid State Marx Generator - $($design.ModuleFull); $($design.MaterialFull) substrate, $($design.ThickMm) mm."
        parameters  = @(
            @{ _type = "Part"; name = "Module";              value_text = $design.ModuleFull;   group = "Board" }
            @{ _type = "Part"; name = "Substrate material";  value_text = $design.MaterialFull; group = "Board" }
            @{ _type = "Part"; name = "Substrate thickness"; value_typical = $design.ThickMm; unit = "mm"; group = "Board" }
        )
    }
    if ($categoryIri) { $body.category = $categoryIri }

    if ($Apply) {
        $part = Invoke-Api -Method POST -Path "/api/parts" -Body $body
        $partIriByName[$name] = "/api/parts/$($part.id)"
        Write-Host "Created design part '$name' -> $($partIriByName[$name])" -ForegroundColor Green
    } else {
        Write-Host "[dry-run] would create design part '$name' (module=$($design.Module), material=$($design.Material), $($design.ThickMm)mm)" -ForegroundColor Yellow
    }
}

# ----- 3) Create one lot per unit (User barcode = full code) -----
$created = 0; $skipped = 0
foreach ($p in $parsed) {
    $existingLot = Get-Collection "/api/part_lots?user_barcode=$($p.Code)" | Where-Object { $_.user_barcode -eq $p.Code } | Select-Object -First 1
    if ($existingLot) {
        Write-Host "Lot for $($p.Code) already exists (id $($existingLot.id)) -> skip"
        $skipped++
        continue
    }

    $partIri = $partIriByName[$p.PartName]
    $lotBody = @{
        description  = "Unit $($p.Unit) - released $($p.Day) $($p.Month)"
        amount       = 1
        user_barcode = $p.Code
    }
    if ($partIri) { $lotBody.part = $partIri }

    if ($Apply) {
        if (-not $partIri) { throw "No part IRI for $($p.PartName) (category/part creation must run with -Apply)." }
        $lot = Invoke-Api -Method POST -Path "/api/part_lots" -Body $lotBody
        Write-Host "Created lot for $($p.Code) (id $($lot.id)) on $($p.PartName)" -ForegroundColor Green
        $created++
    } else {
        Write-Host "[dry-run] would create lot for $($p.Code) on $($p.PartName)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host ("Done. Lots created: {0}, skipped (already existed): {1}" -f $created, $skipped) -ForegroundColor Cyan
if (-not $Apply) {
    Write-Host "This was a DRY RUN. Re-run with -Apply to write the data." -ForegroundColor Cyan
}

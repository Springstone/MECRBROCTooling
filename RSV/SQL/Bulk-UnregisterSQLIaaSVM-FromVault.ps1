<#
.SYNOPSIS
    Bulk CSV-driven wrapper for Unregister-SQLIaaSVM-FromVault.ps1.
    Authenticates once and processes multiple VMs from a CSV file.

.DESCRIPTION
    Reads a CSV file with VM details, authenticates once to Azure,
    then calls Unregister-SQLIaaSVM-FromVault.ps1 for each row, passing
    the pre-fetched token to avoid re-authentication per VM.

    The CSV must contain at minimum these columns:
      VaultSubscriptionId, VaultResourceGroup, VaultName, VMResourceGroup, VMName

    Optional columns:
      InstanceName, DatabaseName, Unregister, StopAll

    By default (if no mode columns are specified), -Unregister -SkipConfirmation
    is used for fully non-interactive bulk processing.

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER ResultsPath
    Path to export the results CSV. If omitted, results are saved next to the
    input CSV with a timestamp suffix.

.PARAMETER StopOnFirstFailure
    Stop processing remaining VMs if any VM fails.

.PARAMETER WhatIf
    Validate the CSV and show the execution plan without actually running anything.

.PARAMETER DefaultMode
    Default mode when CSV row doesn't specify Unregister or StopAll.
    Valid values: Unregister, StopAll, StopProtectionOnly
    Default: Unregister

.EXAMPLE
    # Unregister all VMs in the CSV (default: stop all + unregister, no prompts)
    .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath "C:\input\vms.csv"

.EXAMPLE
    # Stop protection only (no unregister) for all VMs
    .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath "C:\input\vms.csv" -DefaultMode StopAll

.EXAMPLE
    # Dry run - validate CSV and show plan
    .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath "C:\input\vms.csv" -WhatIf

.NOTES
    Author: Azure Backup Script Generator
    Date: March 15, 2026
    Requires: Unregister-SQLIaaSVM-FromVault.ps1 in the same directory.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to export the results CSV.")]
    [string]$ResultsPath,

    [Parameter(Mandatory = $false, HelpMessage = "Stop processing if any VM fails.")]
    [switch]$StopOnFirstFailure,

    [Parameter(Mandatory = $false, HelpMessage = "Default mode when CSV row doesn't specify. Valid: Unregister, StopAll, StopProtectionOnly")]
    [ValidateSet("Unregister", "StopAll", "StopProtectionOnly")]
    [string]$DefaultMode = "Unregister"
)

# ============================================================================
# VALIDATE PREREQUISITES
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk SQL IaaS VM Stop Protection & Unregister" -ForegroundColor Cyan
Write-Host "  (CSV-driven wrapper for Unregister-SQLIaaSVM-FromVault.ps1)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unregisterScript = Join-Path $scriptDir "Unregister-SQLIaaSVM-FromVault.ps1"

if (-not (Test-Path $unregisterScript)) {
    Write-Host "ERROR: Unregister-SQLIaaSVM-FromVault.ps1 not found in '$scriptDir'" -ForegroundColor Red
    Write-Host "  The bulk wrapper must be in the same directory as the Unregister script." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Unregister script: $unregisterScript" -ForegroundColor Gray
Write-Host "  Default mode:      $DefaultMode" -ForegroundColor Gray

# ============================================================================
# VALIDATE & PARSE CSV
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Validating CSV Input" -ForegroundColor Yellow
Write-Host "------------------------------" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

try {
    $csvData = Import-Csv -Path $CsvPath
} catch {
    Write-Host "ERROR: Failed to parse CSV: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($csvData.Count -eq 0) {
    Write-Host "ERROR: CSV file is empty." -ForegroundColor Red
    exit 1
}

$requiredColumns = @("VaultSubscriptionId", "VaultResourceGroup", "VaultName", "VMResourceGroup", "VMName")
$csvColumns = $csvData[0].PSObject.Properties.Name

$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
    Write-Host "ERROR: CSV is missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Required columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
    Write-Host "  Optional columns: InstanceName, DatabaseName, Unregister, StopAll" -ForegroundColor Yellow
    exit 1
}

# Validate each row
$validationErrors = @()
$rowNum = 0
foreach ($row in $csvData) {
    $rowNum++
    foreach ($col in $requiredColumns) {
        if ([string]::IsNullOrWhiteSpace($row.$col)) {
            $validationErrors += "  Row $rowNum : Column '$col' is empty (VMName: $($row.VMName))"
        }
    }
}

if ($validationErrors.Count -gt 0) {
    Write-Host "ERROR: CSV validation failed:" -ForegroundColor Red
    foreach ($err in $validationErrors) {
        Write-Host $err -ForegroundColor Red
    }
    exit 1
}

Write-Host "  CSV file:        $CsvPath" -ForegroundColor Gray
Write-Host "  Total VMs:       $($csvData.Count)" -ForegroundColor Gray
Write-Host ""

# Show execution plan
Write-Host "  Execution Plan:" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------" -ForegroundColor Gray
$planIdx = 1
foreach ($row in $csvData) {
    $mode = $DefaultMode
    if ($row.PSObject.Properties.Name -contains "Unregister" -and $row.Unregister -ieq "true") {
        $mode = "Unregister"
    } elseif ($row.PSObject.Properties.Name -contains "StopAll" -and $row.StopAll -ieq "true") {
        $mode = "StopAll"
    } elseif ($row.PSObject.Properties.Name -contains "DatabaseName" -and -not [string]::IsNullOrWhiteSpace($row.DatabaseName)) {
        $mode = "StopDB: $($row.DatabaseName)"
    }

    $modeColor = switch -Wildcard ($mode) {
        "Unregister" { "Magenta" }
        "StopAll" { "Yellow" }
        default { "White" }
    }

    Write-Host "  [$planIdx] $($row.VMName) -> $($row.VaultName) | Mode: $mode" -ForegroundColor $modeColor
    $planIdx++
}
Write-Host ""

# WhatIf
if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Dry run complete. No changes made." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# ============================================================================
# AUTHENTICATE ONCE
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Authenticating to Azure (single authentication)" -ForegroundColor Yellow
Write-Host "---------------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$token = $null

try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    } else {
        $token = $tokenResponse.Token
    }

    if (-not $token.StartsWith("eyJ")) {
        throw "Invalid token format"
    }

    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow

    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1

        if ($LASTEXITCODE -eq 0) {
            $tokenObject = $azTokenOutput | ConvertFrom-Json
            $token = $tokenObject.accessToken
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else {
            throw "Azure CLI authentication failed"
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to authenticate to Azure." -ForegroundColor Red
        Write-Host "  1. Azure PowerShell: Connect-AzAccount" -ForegroundColor White
        Write-Host "  2. Azure CLI: az login" -ForegroundColor White
        exit 1
    }
}

Write-Host ""

# ============================================================================
# PROCESS EACH VM
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Processing VMs" -ForegroundColor Yellow
Write-Host "------------------------" -ForegroundColor Yellow
Write-Host ""

$results = @()
$totalCount = $csvData.Count
$successCount = 0
$failCount = 0
$currentRow = 0

foreach ($row in $csvData) {
    $currentRow++
    $vmLabel = "$($row.VMName) -> $($row.VaultName)"

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  [$currentRow/$totalCount] Processing: $vmLabel" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    $startTime = Get-Date

    # Build parameter hashtable
    $params = @{
        VaultSubscriptionId = $row.VaultSubscriptionId
        VaultResourceGroup  = $row.VaultResourceGroup
        VaultName           = $row.VaultName
        VMResourceGroup     = $row.VMResourceGroup
        VMName              = $row.VMName
        Token               = $token
        SkipConfirmation    = $true
    }

    # Optional: InstanceName
    if ($row.PSObject.Properties.Name -contains "InstanceName" -and -not [string]::IsNullOrWhiteSpace($row.InstanceName)) {
        $params["InstanceName"] = $row.InstanceName
    }

    # Determine mode
    $operationMode = $DefaultMode

    if ($row.PSObject.Properties.Name -contains "Unregister" -and $row.Unregister -ieq "true") {
        $params["Unregister"] = $true
        $operationMode = "Unregister"
    } elseif ($row.PSObject.Properties.Name -contains "StopAll" -and $row.StopAll -ieq "true") {
        $params["StopAll"] = $true
        $operationMode = "StopAll"
    } elseif ($row.PSObject.Properties.Name -contains "DatabaseName" -and -not [string]::IsNullOrWhiteSpace($row.DatabaseName)) {
        $params["DatabaseName"] = $row.DatabaseName
        $operationMode = "StopDB: $($row.DatabaseName)"
    } else {
        # Apply default mode
        switch ($DefaultMode) {
            "Unregister" { $params["Unregister"] = $true }
            "StopAll"    { $params["StopAll"] = $true }
            "StopProtectionOnly" { } # no extra flags, but SkipConfirmation won't help with interactive selection
        }
    }

    # Execute
    $exitCode = 0
    $errorMsg = ""

    try {
        & $unregisterScript @params
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 0 }
    } catch {
        $exitCode = 1
        $errorMsg = $_.Exception.Message
    }

    $endTime = Get-Date
    $duration = ($endTime - $startTime).TotalSeconds

    $status = if ($exitCode -eq 0) { "Success" } else { "Failed" }

    if ($exitCode -eq 0) {
        $successCount++
        Write-Host ""
        Write-Host "  RESULT: SUCCESS ($([math]::Round($duration, 1))s)" -ForegroundColor Green
    } else {
        $failCount++
        Write-Host ""
        Write-Host "  RESULT: FAILED (exit code: $exitCode, $([math]::Round($duration, 1))s)" -ForegroundColor Red
        if ($errorMsg) { Write-Host "  Error: $errorMsg" -ForegroundColor Red }
    }

    $results += [PSCustomObject]@{
        Row             = $currentRow
        VMName          = $row.VMName
        VaultName       = $row.VaultName
        Mode            = $operationMode
        Status          = $status
        ExitCode        = $exitCode
        DurationSeconds = [math]::Round($duration, 1)
        Error           = $errorMsg
    }

    if ($StopOnFirstFailure -and $exitCode -ne 0) {
        Write-Host ""
        Write-Host "  -StopOnFirstFailure: Halting bulk processing." -ForegroundColor Yellow
        break
    }
}

# ============================================================================
# RESULTS SUMMARY
# ============================================================================

Write-Host ""
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  BULK UNREGISTER SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Total VMs:     $totalCount" -ForegroundColor White
Write-Host "  Succeeded:     $successCount" -ForegroundColor Green
if ($failCount -gt 0) {
    Write-Host "  Failed:        $failCount" -ForegroundColor Red
} else {
    Write-Host "  Failed:        0" -ForegroundColor White
}
Write-Host "  Processed:     $currentRow" -ForegroundColor White
if ($currentRow -lt $totalCount) {
    Write-Host "  Skipped:       $($totalCount - $currentRow) (stopped on failure)" -ForegroundColor Yellow
}
Write-Host ""

# Display results table
Write-Host "  Results:" -ForegroundColor Yellow
Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "  Row  VMName                Status     Duration  Mode" -ForegroundColor Gray
Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray

foreach ($r in $results) {
    $statusColor = if ($r.Status -eq "Success") { "Green" } else { "Red" }
    $line = "  {0,-4} {1,-20} {2,-10} {3,8}s  {4}" -f $r.Row, $r.VMName, $r.Status, $r.DurationSeconds, $r.Mode
    Write-Host $line -ForegroundColor $statusColor
}

Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
Write-Host ""

# Export results CSV
if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $csvDir = Split-Path -Parent $CsvPath
    $csvBaseName = [System.IO.Path]::GetFileNameWithoutExtension($CsvPath)
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = Join-Path $csvDir "${csvBaseName}_results_${timestamp}.csv"
}

try {
    $results | Export-Csv -Path $ResultsPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Results exported to: $ResultsPath" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not export results to '$ResultsPath': $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Recovery points are PRESERVED for all VMs (stop-with-retain)." -ForegroundColor Green
Write-Host ""
Write-Host "Bulk unregister completed." -ForegroundColor Cyan
Write-Host ""

if ($failCount -gt 0) { exit 1 } else { exit 0 }

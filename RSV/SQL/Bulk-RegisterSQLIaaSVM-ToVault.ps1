<#
.SYNOPSIS
    Bulk CSV-driven wrapper for Register-SQLIaaSVM-ToVault.ps1.
    Authenticates once and processes multiple VMs from a CSV file.

.DESCRIPTION
    Reads a CSV file with VM and protection details, authenticates once to Azure,
    then calls Register-SQLIaaSVM-ToVault.ps1 for each row, passing the pre-fetched
    token to avoid re-authentication per VM.

    The CSV must contain at minimum these columns:
      VaultSubscriptionId, VaultResourceGroup, VaultName, VMResourceGroup, VMName, PolicyName

    Optional columns:
      InstanceName, DatabaseName, EnableAutoProtection, AutoProtectAllInstances

    Rows without EnableAutoProtection or AutoProtectAllInstances and without DatabaseName
    will default to AutoProtectAllInstances=true.

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER ResultsPath
    Path to export the results CSV. If omitted, results are saved next to the
    input CSV with a timestamp suffix.

.PARAMETER StopOnFirstFailure
    Stop processing remaining VMs if any VM fails.

.PARAMETER WhatIf
    Validate the CSV and show the execution plan without actually running anything.

.EXAMPLE
    # Process all VMs in the CSV
    .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath "C:\input\vms.csv"

.EXAMPLE
    # Dry run - validate CSV and show plan
    .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath "C:\input\vms.csv" -WhatIf

.EXAMPLE
    # Process with custom results output and stop on failure
    .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath "C:\input\vms.csv" `
        -ResultsPath "C:\output\results.csv" -StopOnFirstFailure

.NOTES
    Author: Azure Backup Script Generator
    Date: March 15, 2026
    Requires: Register-SQLIaaSVM-ToVault.ps1 in the same directory.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to export the results CSV.")]
    [string]$ResultsPath,

    [Parameter(Mandatory = $false, HelpMessage = "Stop processing if any VM fails.")]
    [switch]$StopOnFirstFailure
)

# ============================================================================
# VALIDATE PREREQUISITES
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk SQL IaaS VM Backup Registration" -ForegroundColor Cyan
Write-Host "  (CSV-driven wrapper for Register-SQLIaaSVM-ToVault.ps1)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# Find the Register script in the same directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$registerScript = Join-Path $scriptDir "Register-SQLIaaSVM-ToVault.ps1"

if (-not (Test-Path $registerScript)) {
    Write-Host "ERROR: Register-SQLIaaSVM-ToVault.ps1 not found in '$scriptDir'" -ForegroundColor Red
    Write-Host "  The bulk wrapper must be in the same directory as the Register script." -ForegroundColor Yellow
    exit 1
}

Write-Host "  Register script: $registerScript" -ForegroundColor Gray

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

# Validate required columns
$requiredColumns = @("VaultSubscriptionId", "VaultResourceGroup", "VaultName", "VMResourceGroup", "VMName", "PolicyName")
$csvColumns = $csvData[0].PSObject.Properties.Name

$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
    Write-Host "ERROR: CSV is missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Required columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
    Write-Host "  Optional columns: InstanceName, DatabaseName, EnableAutoProtection, AutoProtectAllInstances" -ForegroundColor Yellow
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

# Determine unique vaults and subscriptions
$uniqueVaults = $csvData | Select-Object VaultSubscriptionId, VaultResourceGroup, VaultName -Unique
$uniqueSubscriptions = $csvData | Select-Object VaultSubscriptionId -Unique

Write-Host "  CSV file:        $CsvPath" -ForegroundColor Gray
Write-Host "  Total VMs:       $($csvData.Count)" -ForegroundColor Gray
Write-Host "  Unique vaults:   $($uniqueVaults.Count)" -ForegroundColor Gray
Write-Host "  Subscriptions:   $($uniqueSubscriptions.Count)" -ForegroundColor Gray
Write-Host ""

# Show execution plan
Write-Host "  Execution Plan:" -ForegroundColor Cyan
Write-Host "  ---------------------------------------------------------------" -ForegroundColor Gray
$planIdx = 1
foreach ($row in $csvData) {
    $mode = "Individual DB"
    if ($row.PSObject.Properties.Name -contains "AutoProtectAllInstances" -and $row.AutoProtectAllInstances -ieq "true") {
        $mode = "Auto-Protect ALL Instances"
    } elseif ($row.PSObject.Properties.Name -contains "EnableAutoProtection" -and $row.EnableAutoProtection -ieq "true") {
        $instLabel = if ($row.PSObject.Properties.Name -contains "InstanceName" -and -not [string]::IsNullOrWhiteSpace($row.InstanceName)) { $row.InstanceName } else { "(prompt/auto)" }
        $mode = "Auto-Protect Instance: $instLabel"
    } elseif ($row.PSObject.Properties.Name -contains "DatabaseName" -and -not [string]::IsNullOrWhiteSpace($row.DatabaseName)) {
        $mode = "Protect DB: $($row.DatabaseName)"
    } else {
        $mode = "Auto-Protect ALL Instances (default)"
    }

    Write-Host "  [$planIdx] $($row.VMName) -> $($row.VaultName) | $mode | Policy: $($row.PolicyName)" -ForegroundColor White
    $planIdx++
}
Write-Host ""

# WhatIf - show plan and exit
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

# Try Azure PowerShell first
try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    } else {
        $token = $tokenResponse.Token
    }

    if (-not $token.StartsWith("eyJ")) {
        Write-Host "  WARNING: Token does not appear to be a valid JWT. Trying Azure CLI..." -ForegroundColor Yellow
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
        PolicyName          = $row.PolicyName
        Token               = $token
    }

    # Optional: InstanceName
    if ($row.PSObject.Properties.Name -contains "InstanceName" -and -not [string]::IsNullOrWhiteSpace($row.InstanceName)) {
        $params["InstanceName"] = $row.InstanceName
    }

    # Determine protection mode
    $protectionMode = "AutoProtectAllInstances"

    if ($row.PSObject.Properties.Name -contains "AutoProtectAllInstances" -and $row.AutoProtectAllInstances -ieq "true") {
        $params["AutoProtectAllInstances"] = $true
        $protectionMode = "AutoProtectAllInstances"
    } elseif ($row.PSObject.Properties.Name -contains "EnableAutoProtection" -and $row.EnableAutoProtection -ieq "true") {
        $params["EnableAutoProtection"] = $true
        $protectionMode = "EnableAutoProtection"
    } elseif ($row.PSObject.Properties.Name -contains "DatabaseName" -and -not [string]::IsNullOrWhiteSpace($row.DatabaseName)) {
        $params["DatabaseName"] = $row.DatabaseName
        $protectionMode = "IndividualDB"
    } else {
        # Default: auto-protect all instances
        $params["AutoProtectAllInstances"] = $true
        $protectionMode = "AutoProtectAllInstances (default)"
    }

    # Execute the Register script
    $exitCode = 0
    $errorMsg = ""

    try {
        & $registerScript @params
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
        Row              = $currentRow
        VMName           = $row.VMName
        VaultName        = $row.VaultName
        ProtectionMode   = $protectionMode
        PolicyName       = $row.PolicyName
        Status           = $status
        ExitCode         = $exitCode
        DurationSeconds  = [math]::Round($duration, 1)
        Error            = $errorMsg
    }

    # Stop on first failure if requested
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
Write-Host "  BULK REGISTRATION SUMMARY" -ForegroundColor Cyan
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
    $line = "  {0,-4} {1,-20} {2,-10} {3,8}s  {4}" -f $r.Row, $r.VMName, $r.Status, $r.DurationSeconds, $r.ProtectionMode
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
Write-Host "Bulk registration completed." -ForegroundColor Cyan
Write-Host ""

# Exit with appropriate code
if ($failCount -gt 0) { exit 1 } else { exit 0 }

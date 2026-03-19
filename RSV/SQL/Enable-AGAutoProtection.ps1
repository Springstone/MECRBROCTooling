<#
.SYNOPSIS
    Discovers all AG availability groups in a Recovery Services Vault and enables
    auto-protection on them.

.DESCRIPTION
    This script:
      1. Discovers all SQL AG availability groups (protectable items) in the vault.
      2. Enables auto-protection on each AG with the specified backup policy.

    This ensures all current and future databases in AG groups are
    automatically protected without needing to specify individual VMs.

    The CSV must contain at minimum these columns:
      VaultSubscriptionId, VaultResourceGroup, VaultName, PolicyName

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER ResultsPath
    Path to export the results CSV. If omitted, auto-generated with
    machine name and timestamp.

.PARAMETER SkipConfirmation
    Skip all confirmation prompts.

.PARAMETER Token
    Pre-fetched bearer token. Skips authentication when provided.

.PARAMETER WhatIf
    Discover only, no changes.

.EXAMPLE
    # Auto-protect all AG groups in vault
    .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv"

.EXAMPLE
    # Fully non-interactive
    .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv" -SkipConfirmation

.EXAMPLE
    # Dry run
    .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv" -WhatIf

.NOTES
    Author: Azure Backup Script Generator
    Date: March 19, 2026
    API Version: 2025-08-01
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to export the results CSV.")]
    [string]$ResultsPath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip all confirmation prompts.")]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false, HelpMessage = "Pre-fetched bearer token.")]
    [string]$Token
)

$apiVersion = "2025-08-01"

# ============================================================================
# HELPER: Parse error response
# ============================================================================

function Write-ApiError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = "API call"
    )

    $statusCode = $ErrorRecord.Exception.Response.StatusCode.value__
    Write-Host "      Status Code: $statusCode" -ForegroundColor Red
    Write-Host "      Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json
        if ($errorJson.error) {
            Write-Host "      Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "      Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch { }
}

# ============================================================================
# BANNER
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Enable Auto-Protection on AG SQL Instances" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 1: VALIDATE CSV
# ============================================================================

Write-Host "STEP 1: Validating CSV Input" -ForegroundColor Yellow
Write-Host "------------------------------" -ForegroundColor Yellow
Write-Host ""

if (-not (Test-Path $CsvPath)) {
    Write-Host "  ERROR: CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

try {
    $csvData = Import-Csv -Path $CsvPath
} catch {
    Write-Host "  ERROR: Failed to parse CSV: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($csvData.Count -eq 0) {
    Write-Host "  ERROR: CSV file is empty." -ForegroundColor Red
    exit 1
}

$requiredColumns = @("VaultSubscriptionId", "VaultResourceGroup", "VaultName", "PolicyName")
$csvColumns = $csvData[0].PSObject.Properties.Name

$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
    Write-Host "  ERROR: CSV is missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    exit 1
}

$validationErrors = @()
$rowNum = 0
foreach ($row in $csvData) {
    $rowNum++
    foreach ($col in $requiredColumns) {
        if ([string]::IsNullOrWhiteSpace($row.$col)) {
            $validationErrors += "  Row $rowNum : Column '$col' is empty"
        }
    }
}

if ($validationErrors.Count -gt 0) {
    Write-Host "  ERROR: CSV validation failed:" -ForegroundColor Red
    foreach ($err in $validationErrors) { Write-Host $err -ForegroundColor Red }
    exit 1
}

Write-Host "  CSV file:     $CsvPath" -ForegroundColor Gray
Write-Host "  Total rows:   $($csvData.Count)" -ForegroundColor Gray
Write-Host ""

$vaultGroups = $csvData | Group-Object { "$($_.VaultSubscriptionId)|$($_.VaultResourceGroup)|$($_.VaultName)" }

Write-Host "  Vault(s) to process: $($vaultGroups.Count)" -ForegroundColor Gray
foreach ($vg in $vaultGroups) {
    $sr = $vg.Group[0]
    Write-Host "    - $($sr.VaultName) (Policy: $($sr.PolicyName))" -ForegroundColor White
}
Write-Host ""

if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Mode: Discovery only. No changes will be made." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# STEP 2: AUTHENTICATE
# ============================================================================

Write-Host "STEP 2: Authenticating to Azure" -ForegroundColor Yellow
Write-Host "---------------------------------" -ForegroundColor Yellow
Write-Host ""

$token = $null

if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $token = $Token
    Write-Host "  Using pre-fetched token" -ForegroundColor Green
} else {
    try {
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
        if ($tokenResponse.Token -is [System.Security.SecureString]) {
            $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
        } else {
            $token = $tokenResponse.Token
        }
        if (-not $token.StartsWith("eyJ")) { throw "Invalid token" }
        Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
    } catch {
        try {
            $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
            if ($LASTEXITCODE -eq 0) {
                $tokenObject = $azTokenOutput | ConvertFrom-Json
                $token = $tokenObject.accessToken
                Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
            } else { throw "CLI auth failed" }
        } catch {
            Write-Host "  ERROR: Failed to authenticate. Run 'Connect-AzAccount' or 'az login'." -ForegroundColor Red
            exit 1
        }
    }
}

$headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
Write-Host ""

# ============================================================================
# PROCESS EACH VAULT
# ============================================================================

$allResults = @()
$overallSuccess = $true

foreach ($vaultGroup in $vaultGroups) {

    $vaultSubscriptionId = $vaultGroup.Group[0].VaultSubscriptionId
    $vaultResourceGroup  = $vaultGroup.Group[0].VaultResourceGroup
    $vaultName           = $vaultGroup.Group[0].VaultName
    $policyName          = $vaultGroup.Group[0].PolicyName

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Vault: $vaultName" -ForegroundColor Cyan
    Write-Host "  Policy: $policyName" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    # ========================================================================
    # STEP 3: RESOLVE POLICY
    # ========================================================================

    Write-Host "  STEP 3: Resolving Backup Policy" -ForegroundColor Yellow
    Write-Host "  ---------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"
    $policyId = $null

    try {
        $policiesResp = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
        $matchedPolicy = $policiesResp.value | Where-Object { $_.name -ieq $policyName } | Select-Object -First 1

        if ($matchedPolicy) {
            $policyId = $matchedPolicy.id
            Write-Host "    Policy found: $($matchedPolicy.name)" -ForegroundColor Green
            Write-Host "    Policy ID: $policyId" -ForegroundColor Gray
        } else {
            Write-Host "    ERROR: Policy '$policyName' not found in vault." -ForegroundColor Red
            Write-Host "    Available policies:" -ForegroundColor Yellow
            foreach ($p in $policiesResp.value) {
                Write-Host "      - $($p.name) (Type: $($p.properties.workLoadType))" -ForegroundColor White
            }
            $overallSuccess = $false
            $allResults += [PSCustomObject]@{ Vault = $vaultName; Phase = "Resolve Policy"; Status = "Failed"; Details = "Policy '$policyName' not found" }
            continue
        }
    } catch {
        Write-Host "    ERROR: Failed to list policies." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "List Policies"
        $overallSuccess = $false
        $allResults += [PSCustomObject]@{ Vault = $vaultName; Phase = "Resolve Policy"; Status = "Failed"; Details = "API error" }
        continue
    }

    Write-Host ""

    # ========================================================================
    # STEP 4: DISCOVER AG AVAILABILITY GROUPS
    # ========================================================================

    Write-Host "  STEP 4: Discovering AG Availability Groups" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $protectableUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectableItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

    $allProtectable = @()
    try {
        $curUri = $protectableUri
        while ($curUri) {
            $pResp = Invoke-RestMethod -Uri $curUri -Method GET -Headers $headers
            if ($pResp.value) { $allProtectable += $pResp.value }
            $curUri = $pResp.nextLink
        }
        Write-Host "    Total protectable items: $($allProtectable.Count)" -ForegroundColor Gray
    } catch {
        Write-Host "    ERROR: Failed to list protectable items." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "List Protectable Items"
        $overallSuccess = $false
        $allResults += [PSCustomObject]@{ Vault = $vaultName; Phase = "Discovery"; Status = "Failed"; Details = "API error" }
        continue
    }

    # Find SQLAvailabilityGroupContainer items (AG auto-protection targets)
    $sqlInstances = @($allProtectable | Where-Object {
        $_.properties.protectableItemType -ieq "SQLAvailabilityGroupContainer" -and
        $_.properties.isAutoProtectable -eq $true
    })

    Write-Host "    Auto-protectable AG availability groups: $($sqlInstances.Count)" -ForegroundColor $(if ($sqlInstances.Count -gt 0) { "Magenta" } else { "Yellow" })

    if ($sqlInstances.Count -eq 0) {
        Write-Host ""
        Write-Host "    No auto-protectable AG availability groups found." -ForegroundColor Yellow
        Write-Host "    This may mean:" -ForegroundColor Gray
        Write-Host "      - No AGs exist on the registered VMs" -ForegroundColor Gray
        Write-Host "      - Inquiry hasn't been run yet" -ForegroundColor Gray
        Write-Host "      - AGs are already auto-protected" -ForegroundColor Gray
        $allResults += [PSCustomObject]@{ Vault = $vaultName; Phase = "Discovery"; Status = "Success"; Details = "No AG groups found" }
        continue
    }

    Write-Host ""

    # ========================================================================
    # STEP 6: DISPLAY PLAN & CONFIRM
    # ========================================================================

    Write-Host "  STEP 6: Execution Plan" -ForegroundColor Yellow
    Write-Host "  ------------------------" -ForegroundColor Yellow
    Write-Host ""

    # Group instances by container
    $instancesByContainer = $sqlInstances | Group-Object {
        $itemId = $_.id
        $container = ""
        if ($itemId -match "/protectionContainers/([^/]+)/") { $container = $Matches[1] }
        $container
    }

    foreach ($grp in $instancesByContainer) {
        $containerName = $grp.Name
        Write-Host "    AG Container: $containerName" -ForegroundColor Magenta

        foreach ($inst in $grp.Group) {
            Write-Host "      - $($inst.properties.friendlyName) (Server: $($inst.properties.serverName)) → Policy: $policyName" -ForegroundColor White
        }
        Write-Host ""
    }

    Write-Host "    Total instances to auto-protect: $($sqlInstances.Count)" -ForegroundColor Cyan
    Write-Host "    Policy: $policyName" -ForegroundColor Cyan
    Write-Host ""

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] Dry run complete. No changes made." -ForegroundColor Yellow
        Write-Host ""
        $allResults += [PSCustomObject]@{ Vault = $vaultName; Phase = "WhatIf"; Status = "DryRun"; Details = "$($sqlInstances.Count) instances found" }
        continue
    }

    if (-not $SkipConfirmation) {
        Write-Host "    Enable auto-protection on $($sqlInstances.Count) instance(s)? [Y/N, default: Y]" -ForegroundColor Cyan
        $confirm = Read-Host "    "
        if ($confirm -ieq 'N') {
            Write-Host "    Aborted by user." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    # ========================================================================
    # STEP 7: ENABLE AUTO-PROTECTION
    # ========================================================================

    Write-Host "  STEP 7: Enabling Auto-Protection" -ForegroundColor Yellow
    Write-Host "  -----------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $apSuccess = 0
    $apFail = 0

    foreach ($inst in $sqlInstances) {
        $instName = $inst.properties.friendlyName
        $instServer = $inst.properties.serverName
        $instId = $inst.id

        Write-Host "    Auto-protecting '$instName' on '$instServer'..." -ForegroundColor Cyan

        $intentObjectName = [guid]::NewGuid().ToString()
        $autoProtectUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/backupProtectionIntent/$intentObjectName`?api-version=$apiVersion"

        $autoProtectBody = @{
            properties = @{
                protectionIntentItemType = "RecoveryServiceVaultItem"
                backupManagementType     = "AzureWorkload"
                policyId                 = $policyId
                itemId                   = $instId
            }
        } | ConvertTo-Json -Depth 10

        try {
            $apResp = Invoke-RestMethod -Uri $autoProtectUri -Method PUT -Headers $headers -Body $autoProtectBody
            Write-Host "    SUCCESS: '$instName' auto-protection enabled" -ForegroundColor Green
            if ($apResp.properties) {
                Write-Host "      State: $($apResp.properties.protectionState)" -ForegroundColor Gray
            }
            $apSuccess++
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            Write-Host "    FAILED: '$instName'" -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Auto-Protect $instName"

            if ($statusCode -eq 409) {
                Write-Host "      HINT: Auto-protection intent may already exist for this instance." -ForegroundColor Yellow
            }
            $apFail++
        }

        Write-Host ""
    }

    Write-Host "    Auto-Protection Summary: $apSuccess succeeded, $apFail failed" -ForegroundColor Cyan
    Write-Host ""

    $allResults += [PSCustomObject]@{
        Vault   = $vaultName
        Phase   = "Auto-Protect"
        Status  = if ($apFail -eq 0) { "Success" } else { "Partial" }
        Details = "Succeeded: $apSuccess, Failed: $apFail"
    }

    if ($apFail -gt 0) { $overallSuccess = $false }
}

# ============================================================================
# FINAL SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  AG AUTO-PROTECTION - FINAL SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($allResults.Count -gt 0) {
    Write-Host "  Results:" -ForegroundColor Yellow
    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
    $headerLine = "  {0,-25} {1,-20} {2,-10} {3}" -f "Vault", "Phase", "Status", "Details"
    Write-Host $headerLine -ForegroundColor Gray
    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($r in $allResults) {
        $statusColor = switch ($r.Status) { "Success" { "Green" }; "Partial" { "Yellow" }; "Failed" { "Red" }; "DryRun" { "Cyan" }; default { "White" } }
        $line = "  {0,-25} {1,-20} {2,-10} {3}" -f $r.Vault, $r.Phase, $r.Status, $r.Details
        Write-Host $line -ForegroundColor $statusColor
    }

    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
}

Write-Host ""

# Export results
if ([string]::IsNullOrWhiteSpace($ResultsPath)) {
    $csvDir = Split-Path -Parent $CsvPath
    if ([string]::IsNullOrWhiteSpace($csvDir)) { $csvDir = "." }
    $csvBaseName = [System.IO.Path]::GetFileNameWithoutExtension($CsvPath)
    $machineName = $env:COMPUTERNAME
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $ResultsPath = Join-Path $csvDir "${csvBaseName}_results_${machineName}_${timestamp}.csv"
}

try {
    $allResults | Export-Csv -Path $ResultsPath -NoTypeInformation -Encoding UTF8
    Write-Host "  Results exported to: $ResultsPath" -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Could not export results: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""

if ($overallSuccess) {
    Write-Host "  COMPLETED SUCCESSFULLY." -ForegroundColor Green
    Write-Host "  All AG SQL instances are now auto-protected." -ForegroundColor Green
} else {
    Write-Host "  COMPLETED WITH WARNINGS/ERRORS." -ForegroundColor Yellow
    Write-Host "  Review the results above." -ForegroundColor Yellow
}

Write-Host ""
if ($overallSuccess) { exit 0 } else { exit 1 }

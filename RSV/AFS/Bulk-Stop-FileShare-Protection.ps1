<#
.SYNOPSIS
    Bulk stops backup protection (retain data) for Azure File Shares using REST API.

.DESCRIPTION
    This script reads a CSV file and stops backup protection for each file share listed,
    while retaining existing backup data (recovery points).
    It uses the same REST API flow as Stop-FileShare-Protection.ps1, per item:
    
    Per-item steps:
    1. Verify the file share is currently protected in the vault
    2. Check if protection is already stopped (skip if so)
    3. Submit stop-protection PUT (policyId empty, protectionState = ProtectionStopped)
    4. Poll/verify protection state changes to ProtectionStopped
    
    CSV Format (Bulk-Stop-FileShare-Protection_Input.csv):
      Header row required. Columns:
        VaultSubscriptionId              - Subscription ID of the Recovery Services Vault
        VaultResourceGroup               - Resource group of the vault
        VaultName                        - Name of the vault
        StorageAccountSubscriptionId     - Subscription ID of the storage account
                                           (leave empty to use vault subscription)
        StorageAccountResourceGroup      - Resource group of the storage account
        StorageAccountName               - Name of the storage account
        FileShareName                    - Name of the file share to stop protection for
    
    After stop-protection-with-retain-data:
    - No new backups will be taken for these file shares.
    - All existing recovery points are preserved and available for restore.
    - Protection can be resumed later by re-associating a backup policy.
    
    Metrics tracked:
    - Total items processed
    - Success / Failed / Skipped / Pending counts
    - Per-item duration
    - Total elapsed time
    - Summary table at the end
    - Results exported to _Results.csv
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - File shares must be currently protected in the vault
    - Appropriate RBAC permissions on the Recovery Services Vault

.PARAMETER CsvPath
    Path to the input CSV file. If not provided, the script looks for
    Bulk-Stop-FileShare-Protection_Input.csv in the same directory,
    or prompts interactively.

.EXAMPLE
    .\Bulk-Stop-FileShare-Protection.ps1 -CsvPath "C:\inputs\stop-shares.csv"
    Runs bulk stop protection using the specified CSV file.

.EXAMPLE
    .\Bulk-Stop-FileShare-Protection.ps1
    Prompts for CSV path or uses the default Bulk-Stop-FileShare-Protection_Input.csv.

.NOTES
    Author: AFS Backup Expert
    Date: March 23, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/manage-azure-file-share-rest-api#stop-protection-but-retain-existing-data
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update?view=rest-backup-2025-08-01
    Reference: https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request (Bearer token auth header)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"  # Azure Backup REST API version

# Load System.Web for URL encoding (required in PowerShell 7)
Add-Type -AssemblyName System.Web

# ============================================================================
# RUNTIME INPUT
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Stop Azure File Share Backup Protection (Retain Data)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# CSV file path - use param, else prompt
$defaultCsvPath = Join-Path $PSScriptRoot "Bulk-Stop-FileShare-Protection_Input.csv"

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    Write-Host "CSV Input File Path (press Enter for default):" -ForegroundColor Cyan
    Write-Host "  Default: $defaultCsvPath" -ForegroundColor Gray
    $CsvPath = Read-Host "  Enter path"
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = $defaultCsvPath
    }
} else {
    Write-Host "CSV Input File: $CsvPath" -ForegroundColor Gray
}

if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

$csvData = Import-Csv -Path $CsvPath
$totalItems = $csvData.Count

if ($totalItems -eq 0) {
    Write-Host "ERROR: CSV file is empty." -ForegroundColor Red
    exit 1
}

Write-Host "  Loaded $totalItems item(s) from CSV" -ForegroundColor Green
Write-Host ""

# Preview
Write-Host "Items to stop protection for:" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20}" -f "#", "Storage Account", "File Share", "Vault") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20}" -f ("-" * 5), ("-" * 25), ("-" * 25), ("-" * 20)) -ForegroundColor Gray

$itemNum = 1
foreach ($row in $csvData) {
    Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20}" -f $itemNum, $row.StorageAccountName, $row.FileShareName, $row.VaultName) -ForegroundColor White
    $itemNum++
}

Write-Host ""
Write-Host "WARNING: This will STOP backup protection for all listed file shares." -ForegroundColor Yellow
Write-Host "  - No new backups will be taken." -ForegroundColor Gray
Write-Host "  - Existing recovery points will be RETAINED." -ForegroundColor Gray
Write-Host "  - Protection can be resumed later." -ForegroundColor Gray
Write-Host ""
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"
if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null

try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = $tokenResponse.Token | ConvertFrom-SecureString -AsPlainText
    } else {
        $token = $tokenResponse.Token
    }
    if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -lt 100) {
        throw "Token appears invalid (length: $($token.Length))"
    }
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow
    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
        if ($LASTEXITCODE -eq 0) {
            $token = ($azTokenOutput | ConvertFrom-Json).accessToken
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else { throw "CLI auth failed" }
    } catch {
        Write-Host "ERROR: Failed to authenticate. Run Connect-AzAccount or az login." -ForegroundColor Red
        exit 1
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# ============================================================================
# BULK PROCESSING
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  Starting Bulk Stop Protection" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$results = @()
$successCount = 0
$failedCount = 0
$skippedCount = 0
$pendingCount = 0
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$itemIndex = 0
foreach ($row in $csvData) {
    $itemIndex++
    $itemStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    $vaultSubscriptionId = $row.VaultSubscriptionId.Trim()
    $vaultResourceGroup = $row.VaultResourceGroup.Trim()
    $vaultName = $row.VaultName.Trim()
    $storageSubscriptionId = if ([string]::IsNullOrWhiteSpace($row.StorageAccountSubscriptionId)) { $vaultSubscriptionId } else { $row.StorageAccountSubscriptionId.Trim() }
    $storageResourceGroup = $row.StorageAccountResourceGroup.Trim()
    $storageAccountName = $row.StorageAccountName.Trim()
    $fileShareName = $row.FileShareName.Trim()
    
    Write-Host "--------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[$itemIndex/$totalItems] $storageAccountName / $fileShareName" -ForegroundColor Cyan
    Write-Host "  Vault: $vaultName" -ForegroundColor Gray
    Write-Host ""
    
    $itemResult = @{
        Item = "$storageAccountName/$fileShareName"
        Vault = $vaultName
        Status = "Unknown"
        ProtectionState = ""
        Detail = ""
        Duration = ""
    }
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId) -or [string]::IsNullOrWhiteSpace($vaultResourceGroup) -or
        [string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($storageResourceGroup) -or
        [string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($fileShareName)) {
        Write-Host "  SKIPPED: Missing required fields in CSV row" -ForegroundColor Yellow
        $skippedCount++
        $itemResult.Status = "SKIPPED"
        $itemResult.Detail = "Missing required CSV fields"
        $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
        $results += [PSCustomObject]$itemResult
        Write-Host ""
        continue
    }
    
    # Construct identifiers
    $storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
    $containerName = "StorageContainer;storage;$storageResourceGroup;$storageAccountName"
    $protectedItemName = "AzureFileShare;$fileShareName"
    $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
    $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
    
    # ---------------------------------------------------------------
    # STEP A: VERIFY FILE SHARE IS CURRENTLY PROTECTED
    # ---------------------------------------------------------------
    Write-Host "  Step A: Verifying file share protection status..." -ForegroundColor Cyan
    
    $listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"
    
    $matchingItem = $null
    $currentProtectionState = $null
    
    try {
        $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
        
        if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
            $matchingItem = $protectedItemsResponse.value | Where-Object {
                $_.properties.friendlyName -eq $fileShareName -and
                $_.properties.sourceResourceId -eq $storageAccountResourceId
            }
            
            if ($matchingItem) {
                # Extract actual container and item names from the ID
                if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                    $containerName = $matches[1]
                    $protectedItemName = $matches[2]
                    $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
                    $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
                }
                
                $currentProtectionState = $matchingItem.properties.protectionState
                $currentPolicyName = $matchingItem.properties.policyName
                if ([string]::IsNullOrWhiteSpace($currentPolicyName) -and $matchingItem.properties.policyId) {
                    $currentPolicyName = $matchingItem.properties.policyId.Split('/')[-1]
                }
                
                Write-Host "    Found: $fileShareName (State: $currentProtectionState, Policy: $currentPolicyName)" -ForegroundColor Green
            } else {
                Write-Host "    FAILED: File share '$fileShareName' not found in vault protection" -ForegroundColor Red
            }
        } else {
            Write-Host "    FAILED: No protected file shares found in vault" -ForegroundColor Red
        }
    } catch {
        Write-Host "    FAILED: Could not query protected items - $($_.Exception.Message)" -ForegroundColor Red
    }
    
    if (-not $matchingItem) {
        $failedCount++
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "File share not found in vault protection"
        $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
        $results += [PSCustomObject]$itemResult
        Write-Host ""
        continue
    }
    
    # ---------------------------------------------------------------
    # STEP B: CHECK IF ALREADY STOPPED
    # ---------------------------------------------------------------
    if ($currentProtectionState -eq "ProtectionStopped") {
        Write-Host "  Step B: Protection already stopped - skipping" -ForegroundColor Yellow
        $skippedCount++
        $itemResult.Status = "SKIPPED"
        $itemResult.ProtectionState = "ProtectionStopped"
        $itemResult.Detail = "Protection already stopped"
        $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
        $results += [PSCustomObject]$itemResult
        Write-Host ""
        continue
    }
    
    # ---------------------------------------------------------------
    # STEP C: SUBMIT STOP PROTECTION PUT
    # ---------------------------------------------------------------
    Write-Host "  Step C: Stopping protection (retain data)..." -ForegroundColor Cyan
    
    $protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded`?api-version=$apiVersion"
    
    $stopProtectionBody = @{
        properties = @{
            protectedItemType = "AzureFileShareProtectedItem"
            sourceResourceId  = $storageAccountResourceId
            policyId          = ""
            protectionState   = "ProtectionStopped"
        }
    } | ConvertTo-Json -Depth 10
    
    $stopSucceeded = $false
    
    try {
        $stopResponse = Invoke-RestMethod -Uri $protectedItemUri -Method PUT -Headers $headers -Body $stopProtectionBody
        
        Write-Host "    Stop-protection request submitted (200)" -ForegroundColor Green
        $stopSucceeded = $true
        
    } catch {
        $putStatusCode = $_.Exception.Response.StatusCode.value__
        
        if ($putStatusCode -eq 202) {
            Write-Host "    Stop-protection request accepted (202)" -ForegroundColor Green
            $stopSucceeded = $true
        } else {
            $errorMsg = $_.Exception.Message
            
            try {
                $errorStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorStream)
                $errorBody = $reader.ReadToEnd()
                $errorJson = $errorBody | ConvertFrom-Json
                $errorMsg = "$($errorJson.error.code): $($errorJson.error.message)"
            } catch { }
            
            Write-Host "    FAILED: HTTP $putStatusCode - $errorMsg" -ForegroundColor Red
            $failedCount++
            $itemResult.Status = "FAILED"
            $itemResult.Detail = "HTTP $putStatusCode - $errorMsg"
            $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
            $results += [PSCustomObject]$itemResult
            Write-Host ""
            continue
        }
    }
    
    # ---------------------------------------------------------------
    # STEP D: VERIFY PROTECTION STATE (POLL)
    # ---------------------------------------------------------------
    if ($stopSucceeded) {
        Write-Host "  Step D: Verifying protection state..." -ForegroundColor Cyan
        
        $maxRetries = 10
        $retryCount = 0
        $verified = $false
        $finalState = "Unknown"
        
        while (-not $verified -and $retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 10
            
            try {
                $statusCheck = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers
                $finalState = $statusCheck.properties.protectionState
                
                if ($finalState -eq "ProtectionStopped") {
                    $verified = $true
                    Write-Host "    Protection State: $finalState" -ForegroundColor Green
                } else {
                    $retryCount++
                    Write-Host "    Waiting... ($retryCount/$maxRetries) [State: $finalState]" -ForegroundColor Yellow
                }
            } catch {
                $retryCount++
                Write-Host "    Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            }
        }
        
        if ($verified) {
            $successCount++
            $itemResult.Status = "SUCCESS"
            $itemResult.ProtectionState = $finalState
            $itemResult.Detail = "Protection stopped, backup data retained"
        } else {
            Write-Host "    Verification timed out (last state: $finalState). Verify on Azure Portal." -ForegroundColor Yellow
            $pendingCount++
            $itemResult.Status = "PENDING"
            $itemResult.ProtectionState = $finalState
            $itemResult.Detail = "PUT accepted, verification timed out. Verify on portal."
        }
    }
    
    $itemStopwatch.Stop()
    $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
    $results += [PSCustomObject]$itemResult
    Write-Host "  Duration: $($itemResult.Duration)" -ForegroundColor Gray
    Write-Host ""
}

$totalStopwatch.Stop()

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Stop Protection - Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Metrics:" -ForegroundColor Yellow
Write-Host "  Total Items:    $totalItems" -ForegroundColor White
Write-Host "  Succeeded:      $successCount" -ForegroundColor Green
Write-Host "  Failed:         $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
Write-Host "  Pending:        $pendingCount" -ForegroundColor $(if ($pendingCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Skipped:        $skippedCount" -ForegroundColor $(if ($skippedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Total Duration: $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s ($([math]::Round($totalStopwatch.Elapsed.TotalMinutes, 1)) min)" -ForegroundColor White
Write-Host ""

# Results table
Write-Host "Results:" -ForegroundColor Yellow
Write-Host ""
Write-Host ("{0,-5} {1,-35} {2,-10} {3,-20} {4,-10} {5}" -f "#", "File Share", "Status", "Protection State", "Duration", "Detail") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-35} {2,-10} {3,-20} {4,-10} {5}" -f ("-" * 5), ("-" * 35), ("-" * 10), ("-" * 20), ("-" * 10), ("-" * 40)) -ForegroundColor Gray

$rowNum = 1
foreach ($r in $results) {
    $statusColor = switch ($r.Status) { "SUCCESS" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Write-Host ("{0,-5} {1,-35} {2,-10} {3,-20} {4,-10} {5}" -f $rowNum, $r.Item, $r.Status, $r.ProtectionState, $r.Duration, $r.Detail) -ForegroundColor $statusColor
    $rowNum++
}

Write-Host ""

# Export results to CSV
$outputCsvPath = $CsvPath -replace '\.csv$', '_Results.csv'
$results | Export-Csv -Path $outputCsvPath -NoTypeInformation -Force
Write-Host "Results exported to: $outputCsvPath" -ForegroundColor Gray
Write-Host ""

if ($failedCount -gt 0) {
    Write-Host "WARNING: $failedCount item(s) failed. Check the results above for details." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  1. File share not found in vault protection" -ForegroundColor White
    Write-Host "  2. Insufficient RBAC permissions on the vault" -ForegroundColor White
    Write-Host "  3. Vault soft-delete is preventing changes" -ForegroundColor White
    Write-Host ""
}

if ($successCount -gt 0) {
    Write-Host "Next Steps:" -ForegroundColor Yellow
    Write-Host "  1. To resume protection: re-assign a backup policy using Configure-FileShare-Protection.ps1" -ForegroundColor White
    Write-Host "  2. To delete backup data: use Azure Portal -> Vault -> Backup Items -> Delete data" -ForegroundColor White
    Write-Host "  3. To restore from retained data: use Restore-AzureFileShare-RestAPI.ps1" -ForegroundColor White
    Write-Host ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Stop Protection Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

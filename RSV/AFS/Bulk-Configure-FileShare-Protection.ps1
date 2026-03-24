<#
.SYNOPSIS
    Bulk configures backup protection for Azure File Shares using REST API.

.DESCRIPTION
    This script reads a CSV file and enables backup protection for each file share listed.
    It uses the same REST API flow as Configure-FileShare-Protection.ps1, per item:
    
    Per-item steps:
    1. Verify storage account is registered to the vault
    2. Trigger inquire to discover file shares in the storage account
    3. List protectable items and verify the target file share exists
    4. Find the backup policy by name
    5. Enable protection (PUT)
    6. Poll/verify protection state
    
    CSV Format (Bulk-Configure-FileShare-Protection_Input.csv):
      Header row required. Columns:
        VaultSubscriptionId              - Subscription ID of the Recovery Services Vault
        VaultResourceGroup               - Resource group of the vault
        VaultName                        - Name of the vault
        StorageAccountSubscriptionId     - Subscription ID of the storage account (leave empty to use vault subscription)
        StorageAccountResourceGroup      - Resource group of the storage account
        StorageAccountName               - Name of the storage account
        FileShareName                    - Name of the file share to protect
        PolicyName                       - Name of the backup policy to assign
    
    Metrics tracked:
    - Total items processed
    - Success / Failed / Skipped counts
    - Per-item duration
    - Total elapsed time
    - Summary table at the end
    - Results exported to _Results.csv
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Storage accounts must be registered to the vault
    - Appropriate RBAC permissions

.PARAMETER CsvPath
    Path to the input CSV file. If not provided, the script looks for
    Bulk-Configure-FileShare-Protection_Input.csv in the same directory,
    or prompts interactively.

.EXAMPLE
    .\Bulk-Configure-FileShare-Protection.ps1 -CsvPath "C:\inputs\fileshares.csv"
    Runs bulk protection using the specified CSV file.

.EXAMPLE
    .\Bulk-Configure-FileShare-Protection.ps1
    Prompts for CSV path or uses the default Bulk-Configure-FileShare-Protection_Input.csv.

.NOTES
    Author: AFS Backup Expert
    Date: March 22, 2026
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
Write-Host "  Bulk Configure Azure File Share Backup Protection" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# CSV file path — use param, else prompt
$defaultCsvPath = Join-Path $PSScriptRoot "Bulk-Configure-FileShare-Protection_Input.csv"

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
Write-Host "Items to configure:" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20} {4,-20}" -f "#", "Storage Account", "File Share", "Vault", "Policy") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20} {4,-20}" -f ("-" * 5), ("-" * 25), ("-" * 25), ("-" * 20), ("-" * 20)) -ForegroundColor Gray

$itemNum = 1
foreach ($row in $csvData) {
    Write-Host ("{0,-5} {1,-25} {2,-25} {3,-20} {4,-20}" -f $itemNum, $row.StorageAccountName, $row.FileShareName, $row.VaultName, $row.PolicyName) -ForegroundColor White
    $itemNum++
}

Write-Host ""

# Caution: Policy tier behavior
Write-Host "CAUTION:" -ForegroundColor DarkYellow
Write-Host "  - 'Snapshot' policy       : Backups are stored as snapshots in the Storage Account only, in the Storage Account region." -ForegroundColor DarkYellow
Write-Host "  - 'Vault-Standard' policy : Backups are stored as snapshots in the Storage Account (Storage Account region) and transferred to the Recovery Services Vault (Vault region)." -ForegroundColor DarkYellow
Write-Host "  Please verify your policy tier in the Azure Portal (Recovery Services Vault -> Backup Policies -> Select Policy and look for 'Backup tier') before proceeding." -ForegroundColor DarkYellow
Write-Host ""

Write-Host "Continue with bulk protection? (yes/no):" -ForegroundColor Cyan
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
Write-Host "  Starting Bulk Protection Configuration" -ForegroundColor Yellow
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
    $policyName = $row.PolicyName.Trim()
    
    Write-Host "--------------------------------------------------------------" -ForegroundColor Gray
    Write-Host "[$itemIndex/$totalItems] $storageAccountName / $fileShareName" -ForegroundColor Cyan
    Write-Host "  Vault: $vaultName | Policy: $policyName" -ForegroundColor Gray
    Write-Host ""
    
    $itemResult = @{
        Item = "$storageAccountName/$fileShareName"
        Vault = $vaultName
        Policy = $policyName
        Status = "Unknown"
        ProtectionState = ""
        Detail = ""
        Duration = ""
    }
    
    # Validate required fields
    if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId) -or [string]::IsNullOrWhiteSpace($vaultResourceGroup) -or
        [string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($storageResourceGroup) -or
        [string]::IsNullOrWhiteSpace($storageAccountName) -or [string]::IsNullOrWhiteSpace($fileShareName) -or
        [string]::IsNullOrWhiteSpace($policyName)) {
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
    
    # ---------------------------------------------------------------
    # STEP A: VERIFY STORAGE ACCOUNT IS REGISTERED
    # ---------------------------------------------------------------
    Write-Host "  Step A: Verifying storage account registration..." -ForegroundColor Cyan
    
    $verifyContainerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"
    
    $registrationOk = $false
    try {
        $containerResponse = Invoke-RestMethod -Uri $verifyContainerUri -Method GET -Headers $headers
        
        if ($containerResponse.properties.registrationStatus -eq "Registered") {
            $registrationOk = $true
            Write-Host "    Registered (Health: $($containerResponse.properties.healthStatus))" -ForegroundColor Green
        } else {
            Write-Host "    FAILED: Registration status is '$($containerResponse.properties.registrationStatus)'" -ForegroundColor Red
        }
    } catch {
        Write-Host "    FAILED: Storage account not registered - $($_.Exception.Message)" -ForegroundColor Red
    }
    
    if (-not $registrationOk) {
        $failedCount++
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "Storage account not registered to vault"
        $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
        $results += [PSCustomObject]$itemResult
        Write-Host ""
        continue
    }
    
    # ---------------------------------------------------------------
    # STEP B: INQUIRE FILE SHARES IN STORAGE ACCOUNT
    # ---------------------------------------------------------------
    Write-Host "  Step B: Discovering file shares..." -ForegroundColor Cyan
    
    $inquireUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/inquire?api-version=$apiVersion"
    
    try {
        $inquireResponse = Invoke-RestMethod -Uri $inquireUri -Method POST -Headers $headers
        Write-Host "    Inquire completed" -ForegroundColor Green
        Start-Sleep -Seconds 5
    } catch {
        $inquireStatusCode = $_.Exception.Response.StatusCode.value__
        if ($inquireStatusCode -eq 202 -or $inquireStatusCode -eq 200) {
            Write-Host "    Inquire initiated" -ForegroundColor Green
            Start-Sleep -Seconds 5
        } else {
            Write-Host "    WARNING: Inquire returned: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "    Continuing..." -ForegroundColor Yellow
        }
    }
    
    # ---------------------------------------------------------------
    # STEP C: LIST PROTECTABLE ITEMS AND VERIFY FILE SHARE EXISTS
    # ---------------------------------------------------------------
    Write-Host "  Step C: Verifying file share exists in protectable items..." -ForegroundColor Cyan
    
    $protectableItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectableItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"
    
    $protectedItemName = $null
    $fileShareFound = $false
    
    try {
        $protectableResponse = Invoke-RestMethod -Uri $protectableItemsUri -Method GET -Headers $headers
        
        if ($protectableResponse.value -and $protectableResponse.value.Count -gt 0) {
            # List file shares in this storage account
            $fileSharesInAccount = $protectableResponse.value | Where-Object {
                $_.properties.parentContainerFriendlyName -eq $storageAccountName
            }
            
            if ($fileSharesInAccount -and $fileSharesInAccount.Count -gt 0) {
                Write-Host "    File shares in '$storageAccountName':" -ForegroundColor Gray
                foreach ($share in $fileSharesInAccount) {
                    $state = $share.properties.protectionState
                    $stateColor = if ($state -eq "NotProtected") { "White" } else { "Yellow" }
                    Write-Host "      - $($share.properties.friendlyName) ($state)" -ForegroundColor $stateColor
                }
            }
            
            # Find the target file share
            $targetFileShare = $protectableResponse.value | Where-Object {
                $_.properties.friendlyName -eq $fileShareName -and
                $_.properties.parentContainerFriendlyName -eq $storageAccountName
            }
            
            if ($targetFileShare) {
                $fileShareFound = $true
                $protectedItemName = $targetFileShare.name
                Write-Host "    Target file share found: $fileShareName (State: $($targetFileShare.properties.protectionState))" -ForegroundColor Green
                
                if ($targetFileShare.properties.protectionState -ne "NotProtected") {
                    Write-Host "    NOTE: File share is already protected - will update policy" -ForegroundColor Yellow
                }
            } else {
                Write-Host "    File share '$fileShareName' not found in protectable items" -ForegroundColor Red
            }
        } else {
            Write-Host "    No protectable file shares found" -ForegroundColor Red
        }
    } catch {
        Write-Host "    WARNING: Could not list protectable items: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Fallback to manual name construction if not found via API
    if (-not $fileShareFound) {
        $protectedItemName = "AzureFileShare;$fileShareName"
        Write-Host "    Using manual name: $protectedItemName" -ForegroundColor Yellow
    }
    
    # ---------------------------------------------------------------
    # STEP D: FIND POLICY BY NAME
    # ---------------------------------------------------------------
    Write-Host "  Step D: Finding policy '$policyName'..." -ForegroundColor Cyan
    
    $policyId = $null
    
    try {
        $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"
        $policiesResponse = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
        
        $matchedPolicy = $policiesResponse.value | Where-Object { $_.name -eq $policyName }
        if ($matchedPolicy) {
            $policyId = $matchedPolicy.id
            Write-Host "    Policy found" -ForegroundColor Green
        } else {
            Write-Host "    FAILED: Policy '$policyName' not found in vault" -ForegroundColor Red
            $failedCount++
            $itemResult.Status = "FAILED"
            $itemResult.Detail = "Policy '$policyName' not found"
            $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
            $results += [PSCustomObject]$itemResult
            Write-Host ""
            continue
        }
    } catch {
        Write-Host "    FAILED: Could not query policies - $($_.Exception.Message)" -ForegroundColor Red
        $failedCount++
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "Policy query error: $($_.Exception.Message)"
        $itemResult.Duration = "$([math]::Round($itemStopwatch.Elapsed.TotalSeconds, 1))s"
        $results += [PSCustomObject]$itemResult
        Write-Host ""
        continue
    }
    
    # ---------------------------------------------------------------
    # STEP E: ENABLE PROTECTION (PUT)
    # ---------------------------------------------------------------
    Write-Host "  Step E: Enabling protection..." -ForegroundColor Cyan
    
    $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
    $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
    
    $enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded`?api-version=$apiVersion"
    
    $protectionBody = @{
        properties = @{
            protectedItemType = "AzureFileShareProtectedItem"
            sourceResourceId  = $storageAccountResourceId
            policyId          = $policyId
        }
    } | ConvertTo-Json -Depth 10
    
    $protectionSucceeded = $false
    
    try {
        $protectionResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody
        
        Write-Host "    Protection request submitted (200)" -ForegroundColor Green
        $protectionSucceeded = $true
        
    } catch {
        $putStatusCode = $_.Exception.Response.StatusCode.value__
        
        if ($putStatusCode -eq 202) {
            Write-Host "    Protection request accepted (202)" -ForegroundColor Green
            $protectionSucceeded = $true
        } else {
            $errorMsg = $_.Exception.Message
            
            # Try to get detailed error
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
    # STEP F: VERIFY PROTECTION STATE (POLL)
    # ---------------------------------------------------------------
    if ($protectionSucceeded) {
        Write-Host "  Step F: Verifying protection state..." -ForegroundColor Cyan
        
        $maxRetries = 10
        $retryCount = 0
        $verified = $false
        $finalState = "Unknown"
        
        while (-not $verified -and $retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 10
            
            try {
                $statusCheck = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers
                $finalState = $statusCheck.properties.protectionState
                
                if ($finalState -ne "Invalid") {
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
        
        if (-not $verified) {
            Write-Host "    Verification timed out (last state: $finalState). Verify on Azure Portal." -ForegroundColor Yellow
            $pendingCount++
            $itemResult.Status = "PENDING"
            $itemResult.ProtectionState = $finalState
            $itemResult.Detail = "PUT accepted, verification timed out. Verify on portal."
        } else {
            $successCount++
            $itemResult.Status = "SUCCESS"
            $itemResult.ProtectionState = $finalState
            $itemResult.Detail = "Protected with policy '$policyName'"
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
Write-Host "  Bulk Protection Configuration - Summary" -ForegroundColor Cyan
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
Write-Host ("{0,-5} {1,-35} {2,-10} {3,-18} {4,-10} {5}" -f "#", "File Share", "Status", "Protection State", "Duration", "Detail") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-35} {2,-10} {3,-18} {4,-10} {5}" -f ("-" * 5), ("-" * 35), ("-" * 10), ("-" * 18), ("-" * 10), ("-" * 35)) -ForegroundColor Gray

$rowNum = 1
foreach ($r in $results) {
    $statusColor = switch ($r.Status) { "SUCCESS" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Write-Host ("{0,-5} {1,-35} {2,-10} {3,-18} {4,-10} {5}" -f $rowNum, $r.Item, $r.Status, $r.ProtectionState, $r.Duration, $r.Detail) -ForegroundColor $statusColor
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
    Write-Host "  1. Storage account not registered to vault" -ForegroundColor White
    Write-Host "  2. File share doesn't exist in storage account" -ForegroundColor White
    Write-Host "  3. Insufficient permissions" -ForegroundColor White
    Write-Host "  4. Policy incompatible with file share type" -ForegroundColor White
    Write-Host ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Protection Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

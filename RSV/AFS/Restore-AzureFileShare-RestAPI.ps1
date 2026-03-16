<#
.SYNOPSIS
    Restores a backed-up Azure File Share to Alternate Location (ALR) using REST API.

.DESCRIPTION
    This script performs restore operations for Azure File Share backups using Azure Backup REST API.
    Supports both Full Share Restore and Item Level Restore to alternate or original locations.
    
    Restore Types:
    - FullShareRestore: Restores entire file share
    - ItemLevelRestore: Restores specific files/folders
    
    Recovery Types:
    - OriginalLocation: Restore to the same storage account and file share
    - AlternateLocation: Restore to different storage account/file share
    
    Copy Options:
    - Overwrite: Overwrites existing files at destination
    - Skip: Skips files that already exist at destination
    - FailOnConflict: Fails the restore if conflicts detected

.NOTES
    Author: AFS Backup Expert
    Date: December 30, 2025
    Reference: https://learn.microsoft.com/en-us/azure/backup/restore-azure-file-share-rest-api
#>

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"  # Azure Backup REST API version

# Load System.Web for URL encoding (required in PowerShell 7)
Add-Type -AssemblyName System.Web

# ============================================================================
# RUNTIME INPUT COLLECTION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Azure File Share Restore Script (REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# SECTION 1: RECOVERY SERVICES VAULT INFORMATION
# ============================================================================

Write-Host "SECTION 1: Recovery Services Vault Information" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Vault Subscription ID:" -ForegroundColor Cyan
$vaultSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId)) {
    Write-Host "ERROR: Vault Subscription ID cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Vault Resource Group Name:" -ForegroundColor Cyan
$vaultResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($vaultResourceGroup)) {
    Write-Host "ERROR: Vault Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Recovery Services Vault Name:" -ForegroundColor Cyan
$vaultName = Read-Host "  Enter Vault Name"
if ([string]::IsNullOrWhiteSpace($vaultName)) {
    Write-Host "ERROR: Vault Name cannot be empty." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 2: SOURCE (BACKED UP) FILE SHARE INFORMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: Source (Backed Up) File Share Information" -ForegroundColor Yellow
Write-Host "----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Source Storage Account Name:" -ForegroundColor Cyan
$sourceStorageAccount = Read-Host "  Enter Storage Account Name"
if ([string]::IsNullOrWhiteSpace($sourceStorageAccount)) {
    Write-Host "ERROR: Source Storage Account cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Source Resource Group Name:" -ForegroundColor Cyan
$sourceResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($sourceResourceGroup)) {
    Write-Host "ERROR: Source Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Source Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$sourceSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($sourceSubscriptionId)) {
    $sourceSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $sourceSubscriptionId" -ForegroundColor Gray
}

Write-Host ""
Write-Host "Source File Share Name:" -ForegroundColor Cyan
$sourceFileShare = Read-Host "  Enter File Share Name"
if ([string]::IsNullOrWhiteSpace($sourceFileShare)) {
    Write-Host "ERROR: Source File Share Name cannot be empty." -ForegroundColor Red
    exit 1
}

# Construct Source Resource ID
$sourceResourceId = "/subscriptions/$sourceSubscriptionId/resourceGroups/$sourceResourceGroup/providers/Microsoft.Storage/storageAccounts/$sourceStorageAccount"

# Construct Container and Protected Item Names
$containerName = "StorageContainer;storage;$sourceResourceGroup;$sourceStorageAccount"
$protectedItemName = "AzureFileShare;$sourceFileShare"

# URL-encode the names for API calls
$containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
$protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)

Write-Host ""
Write-Host "Constructed identifiers:" -ForegroundColor Gray
Write-Host "  Source Resource ID: $sourceResourceId" -ForegroundColor Gray
Write-Host "  Container Name: $containerName" -ForegroundColor Gray
Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray

# ============================================================================
# VERIFY PROTECTED ITEM EXISTS
# ============================================================================

Write-Host ""
Write-Host "Verifying protected item in vault..." -ForegroundColor Cyan

# Get Azure Access Token (early authentication)
$token = $null
$authMethod = $null

# Try Azure PowerShell first
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
    $authMethod = "Azure PowerShell"
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    # If Azure PowerShell fails, try Azure CLI
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow
    
    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $tokenObject = $azTokenOutput | ConvertFrom-Json
            $token = $tokenObject.accessToken
            $authMethod = "Azure CLI"
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else {
            throw "Azure CLI authentication failed"
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to authenticate to Azure." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please authenticate using one of these methods:" -ForegroundColor Yellow
        Write-Host "  1. Azure PowerShell: Connect-AzAccount" -ForegroundColor White
        Write-Host "  2. Azure CLI: az login" -ForegroundColor White
        Write-Host ""
        Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# List all protected items to verify
$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

try {
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    Write-Host "  Searching for protected file shares in vault..." -ForegroundColor Cyan
    $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
    
    if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
        Write-Host "  Found $($protectedItemsResponse.value.Count) protected file share(s)" -ForegroundColor Green
        Write-Host ""
        
        # Find matching item
        $matchingItem = $protectedItemsResponse.value | Where-Object {
            $_.properties.friendlyName -eq $sourceFileShare -and
            $_.properties.sourceResourceId -eq $sourceResourceId
        }
        
        if ($matchingItem) {
            # Extract actual container and protected item names from the ID
            if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                $containerName = $matches[1]
                $protectedItemName = $matches[2]
                
                Write-Host "Protected item verified!" -ForegroundColor Green
                Write-Host "  Actual Container Name: $containerName" -ForegroundColor Gray
                Write-Host "  Actual Protected Item Name: $protectedItemName" -ForegroundColor Gray
                
                # Update encoded names
                $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
                $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
            } else {
                Write-Host "WARNING: Could not parse container and item names from ID" -ForegroundColor Yellow
                Write-Host "  ID: $($matchingItem.id)" -ForegroundColor Gray
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: File share '$sourceFileShare' not found in vault protection." -ForegroundColor Red
            Write-Host ""
            Write-Host "Available protected file shares:" -ForegroundColor Yellow
            foreach ($item in $protectedItemsResponse.value) {
                Write-Host "  - $($item.properties.friendlyName) (Storage: $($item.properties.sourceResourceId.Split('/')[-1]))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. File share name is correct" -ForegroundColor White
            Write-Host "  2. File share is backed up to this vault" -ForegroundColor White
            Write-Host "  3. Storage account matches" -ForegroundColor White
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protected file shares found in vault '$vaultName'" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please verify:" -ForegroundColor Yellow
        Write-Host "  1. Vault name is correct" -ForegroundColor White
        Write-Host "  2. File shares are backed up to this vault" -ForegroundColor White
        Write-Host "  3. Vault subscription and resource group are correct" -ForegroundColor White
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "WARNING: Could not verify protected item (continuing anyway)" -ForegroundColor Yellow
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# SECTION 3: RESTORE TYPE SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 3: Restore Type Selection" -ForegroundColor Yellow
Write-Host "----------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Select Restore Type:" -ForegroundColor Cyan
Write-Host "  1 = Full Share Restore (entire file share)" -ForegroundColor White
Write-Host "  2 = Item Level Restore (specific files/folders)" -ForegroundColor White
Write-Host ""
Write-Host "Important Support Notes:" -ForegroundColor Yellow
Write-Host "  1. For AFS Vaulted Policy, Only ALR restore is released in production. ILR and OLR are not released yet." -ForegroundColor Yellow
Write-Host "  2. For AFS Vaulted Policy, The Target folder name during Restore has to be empty." -ForegroundColor Yellow
Write-Host "  3. For AFS Vaulted Policy, The Copy Options have to be Overwrite only." -ForegroundColor Yellow
Write-Host ""
$restoreTypeChoice = Read-Host "  Enter choice (1 or 2)"

if ($restoreTypeChoice -eq "1") {
    $restoreRequestType = "FullShareRestore"
    Write-Host "  Selected: Full Share Restore" -ForegroundColor Green
} elseif ($restoreTypeChoice -eq "2") {
    $restoreRequestType = "ItemLevelRestore"
    Write-Host "  Selected: Item Level Restore" -ForegroundColor Green
} else {
    Write-Host "ERROR: Invalid choice. Must be 1 or 2." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 4: RECOVERY TYPE SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 4: Recovery Type Selection" -ForegroundColor Yellow
Write-Host "-----------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Select Recovery Type:" -ForegroundColor Cyan
Write-Host "  1 = Original Location (restore to source file share)" -ForegroundColor White
Write-Host "  2 = Alternate Location (restore to different file share)" -ForegroundColor White
Write-Host ""
$recoveryTypeChoice = Read-Host "  Enter choice (1 or 2)"

if ($recoveryTypeChoice -eq "1") {
    $recoveryType = "OriginalLocation"
    Write-Host "  Selected: Original Location Restore" -ForegroundColor Green
} elseif ($recoveryTypeChoice -eq "2") {
    $recoveryType = "AlternateLocation"
    Write-Host "  Selected: Alternate Location Restore" -ForegroundColor Green
} else {
    Write-Host "ERROR: Invalid choice. Must be 1 or 2." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 5: TARGET LOCATION (FOR ALTERNATE LOCATION RESTORE)
# ============================================================================

$targetDetails = $null
$targetFolderPath = $null

if ($recoveryType -eq "AlternateLocation") {
    Write-Host ""
    Write-Host "SECTION 5: Target (Destination) Location Information" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Target Subscription ID (press Enter if same as source):" -ForegroundColor Cyan
    $targetSubscriptionId = Read-Host "  Enter Subscription ID"
    if ([string]::IsNullOrWhiteSpace($targetSubscriptionId)) {
        $targetSubscriptionId = $sourceSubscriptionId
        Write-Host "  Using source subscription: $targetSubscriptionId" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "Target Resource Group Name:" -ForegroundColor Cyan
    $targetResourceGroup = Read-Host "  Enter Resource Group Name"
    if ([string]::IsNullOrWhiteSpace($targetResourceGroup)) {
        Write-Host "ERROR: Target Resource Group cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Target Storage Account Name:" -ForegroundColor Cyan
    $targetStorageAccount = Read-Host "  Enter Storage Account Name"
    if ([string]::IsNullOrWhiteSpace($targetStorageAccount)) {
        Write-Host "ERROR: Target Storage Account cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Target File Share Name:" -ForegroundColor Cyan
    $targetFileShare = Read-Host "  Enter File Share Name"
    if ([string]::IsNullOrWhiteSpace($targetFileShare)) {
        Write-Host "ERROR: Target File Share Name cannot be empty." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Target Folder Path (optional, e.g., 'restored-data' or leave empty for root):" -ForegroundColor Cyan
    $targetFolderPath = Read-Host "  Enter Folder Path"
    if ([string]::IsNullOrWhiteSpace($targetFolderPath)) {
        Write-Host "  Using root folder" -ForegroundColor Gray
        $targetFolderPath = $null
    } else {
        Write-Host "  Files will be restored to: /$targetFolderPath" -ForegroundColor Gray
    }
    
    # Construct Target Resource ID
    $targetResourceId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetResourceGroup/providers/Microsoft.Storage/storageAccounts/$targetStorageAccount"
    
    $targetDetails = @{
        name = $targetFileShare
        targetResourceId = $targetResourceId
    }
    
    Write-Host ""
    Write-Host "Target Resource ID:" -ForegroundColor Gray
    Write-Host "  $targetResourceId" -ForegroundColor Gray
}

# ============================================================================
# SECTION 6: ITEM LEVEL RESTORE SPECIFICATION (IF APPLICABLE)
# ============================================================================

$restoreFileSpecs = @()

if ($restoreRequestType -eq "ItemLevelRestore") {
    Write-Host ""
    Write-Host "SECTION 6: Item Level Restore Specification" -ForegroundColor Yellow
    Write-Host "--------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    Write-Host "Specify files/folders to restore (you can add multiple):" -ForegroundColor Cyan
    Write-Host ""
    
    $continueAdding = $true
    $itemCount = 1
    
    while ($continueAdding) {
        Write-Host "Item #$itemCount Configuration:" -ForegroundColor White
        Write-Host ""
        
        Write-Host "  File Spec Type:" -ForegroundColor Cyan
        Write-Host "    1 = File (restore a specific file)" -ForegroundColor White
        Write-Host "    2 = Folder (restore an entire folder)" -ForegroundColor White
        $fileSpecChoice = Read-Host "    Enter choice (1 or 2)"
        
        if ($fileSpecChoice -eq "1") {
            $fileSpecType = "File"
        } elseif ($fileSpecChoice -eq "2") {
            $fileSpecType = "Folder"
        } else {
            Write-Host "  ERROR: Invalid choice. Skipping this item." -ForegroundColor Red
            continue
        }
        
        Write-Host ""
        Write-Host "  Path (e.g., 'data/file.txt' or 'logs/'):" -ForegroundColor Cyan
        $itemPath = Read-Host "    Enter Path"
        
        if ([string]::IsNullOrWhiteSpace($itemPath)) {
            Write-Host "  ERROR: Path cannot be empty. Skipping this item." -ForegroundColor Red
        } else {
            $fileSpec = @{
                fileSpecType = $fileSpecType
                path = $itemPath
            }
            
            # Add targetFolderPath only for ALR and if specified
            if ($recoveryType -eq "AlternateLocation" -and -not [string]::IsNullOrWhiteSpace($targetFolderPath)) {
                $fileSpec.targetFolderPath = $targetFolderPath
            }
            
            $restoreFileSpecs += $fileSpec
            Write-Host "  Added: $fileSpecType at '$itemPath'" -ForegroundColor Green
        }
        
        Write-Host ""
        Write-Host "Add another item? (y/n):" -ForegroundColor Cyan
        $addMore = Read-Host "  Enter choice"
        
        if ($addMore -ne "y" -and $addMore -ne "Y") {
            $continueAdding = $false
        } else {
            $itemCount++
            Write-Host ""
        }
    }
    
    if ($restoreFileSpecs.Count -eq 0) {
        Write-Host "ERROR: No items specified for Item Level Restore." -ForegroundColor Red
        exit 1
    }
    
    Write-Host ""
    Write-Host "Total items to restore: $($restoreFileSpecs.Count)" -ForegroundColor Green
}

# ============================================================================
# SECTION 7: CONFLICT RESOLUTION POLICY
# ============================================================================

Write-Host ""
Write-Host "SECTION 7: Conflict Resolution Policy" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Select Copy Options (for file conflicts):" -ForegroundColor Cyan
Write-Host "  1 = Overwrite (replace existing files)" -ForegroundColor White
Write-Host "  2 = Skip (keep existing files, skip restore)" -ForegroundColor White
Write-Host "  3 = FailOnConflict (fail restore if conflicts exist)" -ForegroundColor White
Write-Host ""
$copyChoice = Read-Host "  Enter choice (1, 2, or 3)"

if ($copyChoice -eq "1") {
    $copyOptions = "Overwrite"
    Write-Host "  Selected: Overwrite existing files" -ForegroundColor Green
} elseif ($copyChoice -eq "2") {
    $copyOptions = "Skip"
    Write-Host "  Selected: Skip existing files" -ForegroundColor Green
} elseif ($copyChoice -eq "3") {
    $copyOptions = "FailOnConflict"
    Write-Host "  Selected: Fail on conflicts" -ForegroundColor Green
} else {
    Write-Host "ERROR: Invalid choice. Must be 1, 2, or 3." -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 8: RECOVERY POINT SELECTION
# ============================================================================

Write-Host ""
Write-Host "SECTION 8: Recovery Point Selection" -ForegroundColor Yellow
Write-Host "------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Fetching available recovery points..." -ForegroundColor Cyan
Write-Host ""

# Construct Recovery Points List URI
$recoveryPointsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded/recoveryPoints?api-version=$apiVersion"

Write-Host ""
Write-Host "Fetching recovery points from vault..." -ForegroundColor Cyan

# Fetch Recovery Points
try {
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    $response = Invoke-RestMethod -Uri $recoveryPointsUri -Method GET -Headers $headers
    
    if ($response.value -and $response.value.Count -gt 0) {
        Write-Host "  Found $($response.value.Count) recovery point(s)" -ForegroundColor Green
        Write-Host ""
        
        # Display recovery points
        Write-Host "Available Recovery Points:" -ForegroundColor Cyan
        Write-Host ""
        
        $index = 1
        foreach ($rp in $response.value) {
            $rpName = $rp.name
            $rpTime = $rp.properties.recoveryPointTime
            $rpType = $rp.properties.recoveryPointType
            $rpSize = $rp.properties.recoveryPointSizeInGb
            
            Write-Host "  [$index] Recovery Point ID: $rpName" -ForegroundColor White
            Write-Host "      Time: $rpTime" -ForegroundColor Gray
            Write-Host "      Type: $rpType" -ForegroundColor Gray
            Write-Host "      Size: $rpSize GB" -ForegroundColor Gray
            Write-Host ""
            $index++
        }
        
        Write-Host "Select Recovery Point (enter number 1-$($response.value.Count)):" -ForegroundColor Cyan
        $rpChoice = Read-Host "  Enter choice"
        
        $rpIndex = [int]$rpChoice - 1
        
        if ($rpIndex -lt 0 -or $rpIndex -ge $response.value.Count) {
            Write-Host "ERROR: Invalid selection." -ForegroundColor Red
            exit 1
        }
        
        $selectedRecoveryPoint = $response.value[$rpIndex]
        $recoveryPointId = $selectedRecoveryPoint.name
        
        Write-Host "  Selected Recovery Point: $recoveryPointId" -ForegroundColor Green
        Write-Host "  Recovery Time: $($selectedRecoveryPoint.properties.recoveryPointTime)" -ForegroundColor Green
        
    } else {
        Write-Host "ERROR: No recovery points found for this file share." -ForegroundColor Red
        Write-Host "       Ensure the file share is backed up and has available recovery points." -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host "ERROR: Failed to fetch recovery points." -ForegroundColor Red
    Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# SECTION 9: CONSTRUCT RESTORE REQUEST BODY
# ============================================================================

Write-Host ""
Write-Host "SECTION 9: Preparing Restore Request" -ForegroundColor Yellow
Write-Host "-------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Build request body properties
$requestProperties = @{
    objectType = "AzureFileShareRestoreRequest"
    recoveryType = $recoveryType
    sourceResourceId = $sourceResourceId
    copyOptions = $copyOptions
    restoreRequestType = $restoreRequestType
}

# Add restoreFileSpecs for Item Level Restore or ALR with target folder
if ($restoreRequestType -eq "ItemLevelRestore") {
    $requestProperties.restoreFileSpecs = $restoreFileSpecs
} elseif ($recoveryType -eq "AlternateLocation" -and -not [string]::IsNullOrWhiteSpace($targetFolderPath)) {
    # For Full Share Restore to ALR with target folder
    $requestProperties.restoreFileSpecs = @(
        @{
            targetFolderPath = $targetFolderPath
        }
    )
}

# Add target details for Alternate Location
if ($recoveryType -eq "AlternateLocation") {
    $requestProperties.targetDetails = $targetDetails
}

$requestBody = @{
    properties = $requestProperties
} | ConvertTo-Json -Depth 10

Write-Host "Restore Request Summary:" -ForegroundColor Cyan
Write-Host "  Restore Type: $restoreRequestType" -ForegroundColor Gray
Write-Host "  Recovery Type: $recoveryType" -ForegroundColor Gray
Write-Host "  Copy Options: $copyOptions" -ForegroundColor Gray
Write-Host "  Source: $sourceStorageAccount/$sourceFileShare" -ForegroundColor Gray

if ($recoveryType -eq "AlternateLocation") {
    Write-Host "  Target: $targetStorageAccount/$targetFileShare" -ForegroundColor Gray
    if ($targetFolderPath) {
        Write-Host "  Target Folder: /$targetFolderPath" -ForegroundColor Gray
    }
}

if ($restoreRequestType -eq "ItemLevelRestore") {
    Write-Host "  Items to Restore: $($restoreFileSpecs.Count)" -ForegroundColor Gray
}

# ============================================================================
# SECTION 10: TRIGGER RESTORE OPERATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 10: Trigger Restore Operation" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Construct Restore URI (URL-encoded container and item names)
$restoreUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded/recoveryPoints/$recoveryPointId/restore?api-version=$apiVersion"

Write-Host "Ready to trigger restore operation." -ForegroundColor Yellow
Write-Host ""
Write-Host "WARNING: This will initiate a restore operation that cannot be undone." -ForegroundColor Yellow
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -ne "yes" -and $confirm -ne "YES") {
    Write-Host "Restore operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "Triggering restore operation..." -ForegroundColor Cyan

try {
    $headers = @{
        "Authorization" = "Bearer $token"
        "Content-Type" = "application/json"
    }
    
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $requestBody -UseBasicParsing
    
    if ($restoreResponse.StatusCode -eq 202) {
        Write-Host "  Restore operation accepted (HTTP 202)" -ForegroundColor Green
        Write-Host ""
        
        # Extract operation tracking URIs
        # PS7 returns headers as String[] — take first element
        $locationHeader = $restoreResponse.Headers["Location"] | Select-Object -First 1
        $azureAsyncHeader = $restoreResponse.Headers["Azure-AsyncOperation"] | Select-Object -First 1
        
        if ($azureAsyncHeader) {
            Write-Host "Tracking operation status..." -ForegroundColor Cyan
            Write-Host ""
            
            $operationComplete = $false
            $maxRetries = 30
            $retryCount = 0
            
            while (-not $operationComplete -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 10
                
                try {
                    $statusResponse = Invoke-RestMethod -Uri $azureAsyncHeader -Method GET -Headers $headers
                    
                    $status = $statusResponse.status
                    Write-Host "  Status: $status" -ForegroundColor Yellow
                    
                    if ($status -eq "Succeeded") {
                        $operationComplete = $true
                        Write-Host ""
                        Write-Host "Operation completed successfully!" -ForegroundColor Green
                        Write-Host ""
                        
                        if ($statusResponse.properties.jobId) {
                            $jobId = $statusResponse.properties.jobId
                            Write-Host "Restore Job ID: $jobId" -ForegroundColor Cyan
                            Write-Host ""
                            Write-Host "You can track the job status in Azure Portal or using:" -ForegroundColor White
                            Write-Host "  Vault: $vaultName" -ForegroundColor Gray
                            Write-Host "  Job ID: $jobId" -ForegroundColor Gray
                        }
                        
                    } elseif ($status -eq "Failed") {
                        $operationComplete = $true
                        Write-Host ""
                        Write-Host "ERROR: Operation failed" -ForegroundColor Red
                        
                        if ($statusResponse.error) {
                            Write-Host "Error Details:" -ForegroundColor Red
                            Write-Host "  $($statusResponse.error | ConvertTo-Json -Depth 5)" -ForegroundColor Red
                        }
                        exit 1
                        
                    } elseif ($status -eq "InProgress") {
                        # Continue polling
                    } else {
                        Write-Host "  Unknown status: $status" -ForegroundColor Yellow
                    }
                    
                } catch {
                    Write-Host "  Warning: Failed to get operation status. $_" -ForegroundColor Yellow
                }
                
                $retryCount++
            }
            
            if (-not $operationComplete) {
                Write-Host ""
                Write-Host "Operation is still in progress. Please check Azure Portal for final status." -ForegroundColor Yellow
                Write-Host "Vault: $vaultName" -ForegroundColor Gray
            }
            
        } else {
            Write-Host "Restore operation initiated successfully." -ForegroundColor Green
            Write-Host "Please check Azure Portal for restore job status." -ForegroundColor White
            Write-Host "  Vault: $vaultName" -ForegroundColor Gray
        }
        
    } else {
        Write-Host "WARNING: Unexpected response code: $($restoreResponse.StatusCode)" -ForegroundColor Yellow
        Write-Host "Response: $($restoreResponse.Content)" -ForegroundColor Gray
    }
    
} catch {
    Write-Host "ERROR: Failed to trigger restore operation." -ForegroundColor Red
    Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
    
    if ($_.Exception.Response) {
        $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $reader.BaseStream.Position = 0
        $responseBody = $reader.ReadToEnd()
        Write-Host ""
        Write-Host "Error Response:" -ForegroundColor Red
        Write-Host "$responseBody" -ForegroundColor Red
    }
    
    exit 1
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Restore Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

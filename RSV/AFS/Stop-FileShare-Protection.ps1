<#
.SYNOPSIS
    Stops backup protection for an Azure File Share while retaining existing backup data.

.DESCRIPTION
    This script stops backup protection for an Azure File Share in a Recovery Services Vault
    using Azure Backup REST API. Existing recovery points are retained.
    
    After stop-protection-with-retain-data:
    - No new backups will be taken for this file share.
    - All existing recovery points are preserved and can be used for restore.
    - The file share remains listed in the vault as a stopped-protection item.
    - Protection can be resumed later by re-associating a backup policy.
    
    The script flow:
    1. Authenticate (Bearer Token - Azure PowerShell or CLI)
    2. Verify the file share is currently protected in the vault
    3. Display current protection details (policy, last backup, health)
    4. Confirm the stop-protection operation with the user
    5. Submit the stop-protection request (PUT with no policyId)
    6. Verify the updated protection state
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - File share must be currently protected in the vault
    - Appropriate RBAC permissions on the Recovery Services Vault

.NOTES
    Author: AFS Backup Expert
    Date: March 13, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/manage-azure-file-share-rest-api#stop-protection-but-retain-existing-data
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
    Reference: https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request (Bearer token auth header)
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
Write-Host "  Stop Azure File Share Backup Protection (Retain Data)" -ForegroundColor Cyan
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
# SECTION 2: FILE SHARE INFORMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: File Share Information" -ForegroundColor Yellow
Write-Host "----------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Storage Account Name:" -ForegroundColor Cyan
$storageAccountName = Read-Host "  Enter Storage Account Name"
if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
    Write-Host "ERROR: Storage Account Name cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Storage Account Resource Group Name:" -ForegroundColor Cyan
$storageResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($storageResourceGroup)) {
    Write-Host "ERROR: Storage Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Storage Account Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$storageSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($storageSubscriptionId)) {
    $storageSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $storageSubscriptionId" -ForegroundColor Gray
}

Write-Host ""
Write-Host "File Share Name:" -ForegroundColor Cyan
$fileShareName = Read-Host "  Enter File Share Name"
if ([string]::IsNullOrWhiteSpace($fileShareName)) {
    Write-Host "ERROR: File Share Name cannot be empty." -ForegroundColor Red
    exit 1
}

# Construct Storage Account Resource ID
$storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

# Construct container and protected item names
$containerName = "StorageContainer;storage;$storageResourceGroup;$storageAccountName"
$protectedItemName = "AzureFileShare;$fileShareName"

# URL-encode the names for API calls (semicolons must be encoded)
$containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
$protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)

Write-Host ""
Write-Host "Constructed identifiers:" -ForegroundColor Gray
Write-Host "  Storage Account Resource ID: $storageAccountResourceId" -ForegroundColor Gray
Write-Host "  Container Name: $containerName" -ForegroundColor Gray
Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

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

# Create common headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# ============================================================================
# STEP 1: VERIFY FILE SHARE IS CURRENTLY PROTECTED
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Verifying File Share Protection Status" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Searching for protected file shares in vault..." -ForegroundColor Cyan

$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

$matchingItem = $null

try {
    $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
    
    if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
        Write-Host "  Found $($protectedItemsResponse.value.Count) protected file share(s)" -ForegroundColor Green
        Write-Host ""
        
        # Find matching item by friendly name and source resource ID
        $matchingItem = $protectedItemsResponse.value | Where-Object {
            $_.properties.friendlyName -eq $fileShareName -and
            $_.properties.sourceResourceId -eq $storageAccountResourceId
        }
        
        if ($matchingItem) {
            # Extract actual container and protected item names from the ID
            if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                $containerName = $matches[1]
                $protectedItemName = $matches[2]
                
                # Update encoded names
                $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
                $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
            }
            
            Write-Host "Protected file share found:" -ForegroundColor Green
            Write-Host "  File Share:          $($matchingItem.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection State:    $($matchingItem.properties.protectionState)" -ForegroundColor White
            Write-Host "  Protection Status:   $($matchingItem.properties.protectionStatus)" -ForegroundColor White
            Write-Host "  Health Status:       $($matchingItem.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($matchingItem.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($matchingItem.properties.lastBackupTime)" -ForegroundColor White
            Write-Host "  Container Name:      $containerName" -ForegroundColor Gray
            Write-Host "  Protected Item Name: $protectedItemName" -ForegroundColor Gray
            Write-Host ""
            
            # Check if already stopped
            if ($matchingItem.properties.protectionState -eq "ProtectionStopped") {
                Write-Host "WARNING: Protection is already stopped for this file share." -ForegroundColor Yellow
                Write-Host "  No action needed." -ForegroundColor Yellow
                Write-Host ""
                exit 0
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: File share '$fileShareName' in storage account '$storageAccountName' not found in vault protection." -ForegroundColor Red
            Write-Host ""
            Write-Host "Available protected file shares:" -ForegroundColor Yellow
            foreach ($item in $protectedItemsResponse.value) {
                Write-Host "  - $($item.properties.friendlyName) (Storage: $($item.properties.sourceResourceId.Split('/')[-1]), State: $($item.properties.protectionState))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. File share name is correct" -ForegroundColor White
            Write-Host "  2. Storage account name is correct" -ForegroundColor White
            Write-Host "  3. File share is backed up to this vault" -ForegroundColor White
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protected file shares found in vault '$vaultName'" -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to query protected items." -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================================
# STEP 2: CONFIRM STOP PROTECTION
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Confirm Stop Protection" -ForegroundColor Yellow
Write-Host "---------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "You are about to STOP BACKUP PROTECTION for:" -ForegroundColor Yellow
Write-Host "  File Share:       $fileShareName" -ForegroundColor White
Write-Host "  Storage Account:  $storageAccountName" -ForegroundColor White
Write-Host "  Vault:            $vaultName" -ForegroundColor White
Write-Host ""
Write-Host "  Action: Stop protection and RETAIN existing backup data." -ForegroundColor Yellow
Write-Host "  - No new backups will be taken." -ForegroundColor Gray
Write-Host "  - Existing recovery points will be preserved." -ForegroundColor Gray
Write-Host "  - Protection can be resumed later." -ForegroundColor Gray
Write-Host ""
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# STEP 3: STOP PROTECTION (RETAIN DATA)
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Stopping Backup Protection" -ForegroundColor Yellow
Write-Host "------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Construct the protected item URI (URL-encoded container and item names)
$protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded`?api-version=$apiVersion"

# Request body per doc: policyId empty string + protectionState = ProtectionStopped
$stopProtectionBody = @{
    properties = @{
        protectedItemType = "AzureFileShareProtectedItem"
        sourceResourceId  = $storageAccountResourceId
        policyId          = ""
        protectionState   = "ProtectionStopped"
    }
} | ConvertTo-Json -Depth 10

Write-Host "Submitting stop-protection request..." -ForegroundColor Cyan

try {
    $stopResponse = Invoke-RestMethod -Uri $protectedItemUri -Method PUT -Headers $headers -Body $stopProtectionBody
    
    Write-Host "  Stop-protection request submitted successfully!" -ForegroundColor Green
    Write-Host ""
    
    # Poll until protection state changes to ProtectionStopped
    Write-Host "Waiting for protection state to update..." -ForegroundColor Cyan
    
    $maxRetries = 10
    $retryCount = 0
    $stateStopped = $false
    
    while (-not $stateStopped -and $retryCount -lt $maxRetries) {
        Start-Sleep -Seconds 10
        
        try {
            $verifyResponse = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers
            $currentState = $verifyResponse.properties.protectionState
            
            if ($currentState -eq "ProtectionStopped") {
                $stateStopped = $true
            } else {
                $retryCount++
                Write-Host "  State: $currentState - waiting... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            }
        } catch {
            $retryCount++
            Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
        }
    }
    
    if ($stateStopped) {
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Updated Protected Item Details:" -ForegroundColor Cyan
        Write-Host "  File Share:          $($verifyResponse.properties.friendlyName)" -ForegroundColor White
        Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
        Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
        Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
        Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
        Write-Host ""
        Write-Host "Backup data has been RETAINED." -ForegroundColor Yellow
        Write-Host "  - Existing recovery points are still available for restore." -ForegroundColor Gray
        Write-Host "  - No new backups will be taken." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Yellow
        Write-Host "  1. To resume protection: re-assign a backup policy using Configure-FileShare-Protection.ps1" -ForegroundColor White
        Write-Host "  2. To delete backup data: use Azure Portal -> Vault -> Backup Items -> Delete data" -ForegroundColor White
        Write-Host "  3. To restore from retained data: use Restore-AzureFileShare-RestAPI.ps1" -ForegroundColor White
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "  Stop-protection submitted but state has not changed yet." -ForegroundColor Yellow
        Write-Host "  Last observed state: $currentState" -ForegroundColor Yellow
        Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
        Write-Host ""
    }
    
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Stop-protection request accepted (202)" -ForegroundColor Green
        Write-Host "  Operation is being processed..." -ForegroundColor Yellow
        Write-Host ""
        
        # Poll for completion
        Write-Host "Waiting for operation to complete..." -ForegroundColor Cyan
        
        $maxRetries = 20
        $retryCount = 0
        $completed = $false
        
        while (-not $completed -and $retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 6
            
            try {
                $statusCheck = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers
                
                if ($statusCheck.properties.protectionState -eq "ProtectionStopped") {
                    $completed = $true
                    
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host "  PROTECTION STOPPED SUCCESSFULLY!" -ForegroundColor Green
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "  File Share:          $($statusCheck.properties.friendlyName)" -ForegroundColor White
                    Write-Host "  Protection State:    $($statusCheck.properties.protectionState)" -ForegroundColor White
                    Write-Host ""
                    Write-Host "Backup data has been RETAINED." -ForegroundColor Yellow
                    Write-Host ""
                } else {
                    $retryCount++
                    Write-Host "  Waiting... ($retryCount/$maxRetries) [State: $($statusCheck.properties.protectionState)]" -ForegroundColor Yellow
                }
            } catch {
                $retryCount++
                Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            }
        }
        
        if (-not $completed) {
            Write-Host ""
            Write-Host "  Operation is taking longer than expected." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to stop protection." -ForegroundColor Red
        Write-Host "  Status Code: $statusCode" -ForegroundColor Red
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        
        # Try to parse error response
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorBody = $reader.ReadToEnd()
            $errorJson = $errorBody | ConvertFrom-Json
            
            Write-Host "Error Details:" -ForegroundColor Red
            Write-Host "  Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
            Write-Host ""
        } catch {
            # Could not parse error response
        }
        
        Write-Host "Possible causes:" -ForegroundColor Yellow
        Write-Host "  1. File share is not currently protected" -ForegroundColor White
        Write-Host "  2. Insufficient RBAC permissions on the vault" -ForegroundColor White
        Write-Host "  3. Container or protected item names are incorrect" -ForegroundColor White
        Write-Host "  4. Vault is in a locked state or soft-delete is preventing changes" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Stop Protection Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

<#
.SYNOPSIS
    Unregisters an Azure Storage Account from a Recovery Services Vault using REST API.

.DESCRIPTION
    This script unregisters (removes) a storage account container from a Recovery Services Vault
    using Azure Backup REST API.
    
    Before unregistering:
    - All file shares in the storage account should have their protection stopped with retain data.
    - With api-version 2025-08-01, the vault allows unregistering even when file shares
      are in stop-protection-with-retain-data state.
    
    After unregistering:
    - The storage account is no longer associated with the vault.
    - No backup operations can be performed for file shares in this storage account.
    - To re-enable backup, the storage account must be registered again using
      Register-StorageAccount-ToVault.ps1.
    
    The script flow:
    1. Authenticate (Bearer Token - Azure PowerShell or CLI)
    2. Verify the storage account is currently registered to the vault
    3. Check for any remaining protected items in the container
    4. Display registration details and confirm the unregister operation
    5. Submit the DELETE request to unregister the container
    6. Poll for operation completion
    7. Verify the container is removed
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - All file shares in the storage account must have protection removed first
    - Appropriate RBAC permissions on the Recovery Services Vault

.NOTES
    Author: AFS Backup Expert
    Date: March 13, 2026
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister
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
Write-Host "  Unregister Storage Account from Recovery Services Vault" -ForegroundColor Cyan
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
# SECTION 2: STORAGE ACCOUNT INFORMATION
# ============================================================================

Write-Host ""
Write-Host "SECTION 2: Storage Account Information" -ForegroundColor Yellow
Write-Host "---------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Storage Account Resource Group Name:" -ForegroundColor Cyan
$storageResourceGroup = Read-Host "  Enter Resource Group Name"
if ([string]::IsNullOrWhiteSpace($storageResourceGroup)) {
    Write-Host "ERROR: Storage Resource Group cannot be empty." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Storage Account Name:" -ForegroundColor Cyan
$storageAccountName = Read-Host "  Enter Storage Account Name"
if ([string]::IsNullOrWhiteSpace($storageAccountName)) {
    Write-Host "ERROR: Storage Account Name cannot be empty." -ForegroundColor Red
    exit 1
}

# Construct container name
$containerName = "StorageContainer;storage;$storageResourceGroup;$storageAccountName"

Write-Host ""
Write-Host "Constructed identifiers:" -ForegroundColor Gray
Write-Host "  Container Name: $containerName" -ForegroundColor Gray

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
# STEP 1: VERIFY STORAGE ACCOUNT IS REGISTERED
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Verifying Storage Account Registration" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Checking if storage account is registered to vault..." -ForegroundColor Cyan

$containerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

$containerRegistered = $false

try {
    $containerResponse = Invoke-RestMethod -Uri $containerUri -Method GET -Headers $headers
    
    if ($containerResponse.properties.registrationStatus -eq "Registered") {
        $containerRegistered = $true
        
        # Update container name from actual response if available
        if ($containerResponse.name) {
            $containerName = $containerResponse.name
        }
        
        Write-Host "  Storage account is registered!" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Container Details:" -ForegroundColor Cyan
        Write-Host "    Friendly Name:       $($containerResponse.properties.friendlyName)" -ForegroundColor White
        Write-Host "    Registration Status: $($containerResponse.properties.registrationStatus)" -ForegroundColor White
        Write-Host "    Health Status:       $($containerResponse.properties.healthStatus)" -ForegroundColor White
        Write-Host "    Container Type:      $($containerResponse.properties.containerType)" -ForegroundColor White
        Write-Host "    Source Resource ID:  $($containerResponse.properties.sourceResourceId)" -ForegroundColor White
        Write-Host "    Container Name:      $containerName" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host "  Storage account registration status: $($containerResponse.properties.registrationStatus)" -ForegroundColor Yellow
        Write-Host "  The storage account may not be fully registered." -ForegroundColor Yellow
        Write-Host ""
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 404) {
        Write-Host ""
        Write-Host "ERROR: Storage account '$storageAccountName' is not registered to vault '$vaultName'." -ForegroundColor Red
        Write-Host "  Nothing to unregister." -ForegroundColor Yellow
        Write-Host ""
        exit 0
    } else {
        Write-Host ""
        Write-Host "WARNING: Could not verify registration status." -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing with unregister attempt..." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# STEP 2: CHECK FOR REMAINING PROTECTED ITEMS
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Checking for Remaining Protected Items" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Checking for protected file shares in this storage account..." -ForegroundColor Cyan

$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

$hasProtectedItems = $false

try {
    $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers
    
    if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
        # Filter for items in this storage account's container
        $itemsInContainer = $protectedItemsResponse.value | Where-Object {
            $_.id -match [regex]::Escape($storageAccountName)
        }
        
        if ($itemsInContainer -and $itemsInContainer.Count -gt 0) {
            $hasProtectedItems = $true
            
            Write-Host ""
            Write-Host "WARNING: The following protected file shares still exist in this storage account:" -ForegroundColor Yellow
            Write-Host ""
            foreach ($item in $itemsInContainer) {
                $state = $item.properties.protectionState
                $stateColor = if ($state -eq "ProtectionStopped") { "Yellow" } else { "Red" }
                Write-Host "  - $($item.properties.friendlyName) (State: $state)" -ForegroundColor $stateColor
            }
            Write-Host ""
            
            # Check if any are still actively protected
            $activeItems = $itemsInContainer | Where-Object {
                $_.properties.protectionState -ne "ProtectionStopped"
            }
            
            if ($activeItems -and $activeItems.Count -gt 0) {
                Write-Host "ERROR: There are still actively protected file shares in this storage account." -ForegroundColor Red
                Write-Host "  You must stop protection and retain data for the file shares" -ForegroundColor Red
                Write-Host "  before unregistering the storage account." -ForegroundColor Red
                Write-Host ""
                Write-Host "  Steps:" -ForegroundColor Yellow
                Write-Host "    1. Stop protection with retain data: use Stop-FileShare-Protection.ps1" -ForegroundColor White
                Write-Host "    2. Then re-run this script to unregister" -ForegroundColor White
                Write-Host ""
                exit 1
            } else {
                Write-Host "  No active protected items. Unregister can proceed." -ForegroundColor Green
                Write-Host ""
            }
        } else {
            Write-Host "  No protected file shares found for this storage account." -ForegroundColor Green
            Write-Host ""
        }
    } else {
        Write-Host "  No protected file shares found in the vault." -ForegroundColor Green
        Write-Host ""
    }
} catch {
    Write-Host "  WARNING: Could not check for protected items: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Continuing with unregister attempt..." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# STEP 3: CONFIRM UNREGISTER OPERATION
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Confirm Unregister Operation" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "You are about to UNREGISTER the storage account from the vault:" -ForegroundColor Yellow
Write-Host "  Storage Account:  $storageAccountName" -ForegroundColor White
Write-Host "  Resource Group:   $storageResourceGroup" -ForegroundColor White
Write-Host "  Vault:            $vaultName" -ForegroundColor White
Write-Host ""
Write-Host "  After unregistering:" -ForegroundColor Yellow
Write-Host "  - The storage account will no longer be associated with this vault." -ForegroundColor Gray
Write-Host "  - No backup operations can be performed for file shares in this account." -ForegroundColor Gray
Write-Host "  - To re-enable backup, register the storage account again." -ForegroundColor Gray
Write-Host ""
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"

if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# STEP 4: UNREGISTER STORAGE ACCOUNT (DELETE CONTAINER)
# ============================================================================

Write-Host ""
Write-Host "STEP 4: Unregistering Storage Account" -ForegroundColor Yellow
Write-Host "---------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Construct DELETE URI
$deleteContainerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

Write-Host "Submitting unregister request..." -ForegroundColor Cyan

try {
    $deleteResponse = Invoke-WebRequest -Uri $deleteContainerUri -Method DELETE -Headers $headers -UseBasicParsing
    $statusCode = $deleteResponse.StatusCode
    
    if ($statusCode -eq 200) {
        Write-Host "  Unregister completed immediately (200 OK)" -ForegroundColor Green
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  STORAGE ACCOUNT UNREGISTERED!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Storage account '$storageAccountName' has been removed from vault '$vaultName'." -ForegroundColor White
        Write-Host ""
    } elseif ($statusCode -eq 202) {
        Write-Host "  Unregister request accepted (202)" -ForegroundColor Green
        Write-Host "  Operation is being processed..." -ForegroundColor Yellow
        Write-Host ""
        
        # Track operation via Location or Azure-AsyncOperation header
        # PS7 returns headers as String[] — take first element
        $locationUrl = $deleteResponse.Headers["Location"] | Select-Object -First 1
        $asyncUrl = $deleteResponse.Headers["Azure-AsyncOperation"] | Select-Object -First 1
        $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
        
        if ($trackingUrl) {
            Write-Host "Tracking operation status..." -ForegroundColor Cyan
            
            $maxRetries = 20
            $retryCount = 0
            $completed = $false
            
            while (-not $completed -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 6
                
                try {
                    $opResponse = Invoke-WebRequest -Uri $trackingUrl -Method GET -Headers $headers -UseBasicParsing
                    
                    if ($opResponse.StatusCode -eq 200) {
                        # Check if the response body has a status field
                        try {
                            $opBody = $opResponse.Content | ConvertFrom-Json
                            if ($opBody.status -eq "Succeeded") {
                                $completed = $true
                            } elseif ($opBody.status -eq "Failed") {
                                $completed = $true
                                Write-Host ""
                                Write-Host "ERROR: Unregister operation failed." -ForegroundColor Red
                                if ($opBody.error) {
                                    Write-Host "  Code: $($opBody.error.code)" -ForegroundColor Red
                                    Write-Host "  Message: $($opBody.error.message)" -ForegroundColor Red
                                }
                                exit 1
                            } else {
                                $retryCount++
                                Write-Host "  Waiting... ($retryCount/$maxRetries) [Status: $($opBody.status)]" -ForegroundColor Yellow
                            }
                        } catch {
                            # 200 with no parseable status body — likely completed
                            $completed = $true
                        }
                    } elseif ($opResponse.StatusCode -eq 204) {
                        $completed = $true
                    } else {
                        $retryCount++
                        Write-Host "  Waiting... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                } catch {
                    $innerCode = $_.Exception.Response.StatusCode.value__
                    if ($innerCode -eq 204 -or $innerCode -eq 200) {
                        $completed = $true
                    } else {
                        $retryCount++
                        Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                }
            }
            
            if ($completed) {
                Write-Host ""
                Write-Host "========================================" -ForegroundColor Green
                Write-Host "  STORAGE ACCOUNT UNREGISTERED!" -ForegroundColor Green
                Write-Host "========================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "  Storage account '$storageAccountName' has been removed from vault '$vaultName'." -ForegroundColor White
                Write-Host ""
            } else {
                Write-Host ""
                Write-Host "  Operation is taking longer than expected." -ForegroundColor Yellow
                Write-Host "  Please check the Azure Portal to verify the storage account has been removed." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host "  Unregister operation in progress. No tracking URL returned." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to verify completion." -ForegroundColor Yellow
            Write-Host ""
        }
    } elseif ($statusCode -eq 204) {
        Write-Host "  Storage account was already unregistered (204 No Content)" -ForegroundColor Green
        Write-Host ""
    }
    
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Unregister request accepted (202)" -ForegroundColor Green
        Write-Host ""
        
        # Try to track via headers
        try {
            $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
            $locUrl = $_.Exception.Response.Headers["Location"]
            $trackUrl = if ($asyncUrl) { $asyncUrl } else { $locUrl }
            
            if ($trackUrl) {
                Write-Host "  Tracking operation..." -ForegroundColor Cyan
                
                $maxRetries = 20
                $retryCount = 0
                $opDone = $false
                
                while (-not $opDone -and $retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 6
                    
                    try {
                        $opCheck = Invoke-WebRequest -Uri $trackUrl -Method GET -Headers $headers -UseBasicParsing
                        if ($opCheck.StatusCode -eq 200 -or $opCheck.StatusCode -eq 204) {
                            $opDone = $true
                        }
                    } catch {
                        $innerCode = $_.Exception.Response.StatusCode.value__
                        if ($innerCode -eq 204 -or $innerCode -eq 200) {
                            $opDone = $true
                        } else {
                            $retryCount++
                            Write-Host "  Waiting... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        }
                    }
                }
                
                if ($opDone) {
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host "  STORAGE ACCOUNT UNREGISTERED!" -ForegroundColor Green
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "  Storage account '$storageAccountName' has been removed from vault '$vaultName'." -ForegroundColor White
                    Write-Host ""
                } else {
                    Write-Host ""
                    Write-Host "  Unregister is still in progress. Check Azure Portal." -ForegroundColor Yellow
                    Write-Host ""
                }
            } else {
                Write-Host "  Unregister submitted. Check Azure Portal for status." -ForegroundColor Yellow
                Write-Host ""
            }
        } catch {
            Write-Host "  Unregister submitted. Check Azure Portal for status." -ForegroundColor Yellow
            Write-Host ""
        }
    } elseif ($statusCode -eq 204) {
        Write-Host "  Storage account was already unregistered (204)" -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to unregister storage account." -ForegroundColor Red
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
        Write-Host "  1. File shares still have active protection" -ForegroundColor White
        Write-Host "  2. Insufficient RBAC permissions on the vault" -ForegroundColor White
        Write-Host "  3. Container name is incorrect" -ForegroundColor White
        Write-Host "  4. Vault soft-delete is retaining items" -ForegroundColor White
        Write-Host ""
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# VERIFICATION
# ============================================================================

Write-Host ""
Write-Host "Verifying unregistration..." -ForegroundColor Cyan

Start-Sleep -Seconds 5

try {
    $verifyResponse = Invoke-RestMethod -Uri $containerUri -Method GET -Headers $headers
    
    # If we get a response, the container may still exist
    Write-Host "  Container still visible (status: $($verifyResponse.properties.registrationStatus))" -ForegroundColor Yellow
    Write-Host "  The unregister operation may take a few more moments to fully propagate." -ForegroundColor Yellow
    Write-Host "  Check the Azure Portal to confirm." -ForegroundColor Yellow
    Write-Host ""
} catch {
    $verifyCode = $_.Exception.Response.StatusCode.value__
    if ($verifyCode -eq 404) {
        Write-Host "  Confirmed: Storage account is no longer registered to the vault." -ForegroundColor Green
        Write-Host ""
    } else {
        Write-Host "  Could not verify - check Azure Portal." -ForegroundColor Yellow
        Write-Host ""
    }
}

# ============================================================================
# COMPLETION
# ============================================================================

Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. To re-register the storage account: use Register-StorageAccount-ToVault.ps1" -ForegroundColor White
Write-Host "  2. To verify in Azure Portal: Vault -> Backup Infrastructure -> Storage Accounts" -ForegroundColor White
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Unregister Storage Account Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

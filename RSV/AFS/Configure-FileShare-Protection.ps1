<#
.SYNOPSIS
    Configures backup protection for an Azure File Share using REST API.

.DESCRIPTION
    This script enables backup protection for an Azure File Share by configuring it with a backup policy
    in a Recovery Services Vault using Azure Backup REST API.
    
    The script supports:
    - Cross-subscription scenarios (File Share and Vault in different subscriptions)
    - Discovery of unprotected file shares in a registered storage account
    - Selection of backup policy
    - Enabling backup protection with the selected policy
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Storage account must be registered to the vault (use Register-StorageAccount-ToVault.ps1 first)
    - Appropriate RBAC permissions on both Storage Account and Recovery Services Vault

.NOTES
    Author: AFS Backup Expert
    Date: January 6, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api
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
Write-Host "  Configure Azure File Share Backup Protection" -ForegroundColor Cyan
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

Write-Host "Storage Account Subscription ID (press Enter if same as vault):" -ForegroundColor Cyan
$storageSubscriptionId = Read-Host "  Enter Subscription ID"
if ([string]::IsNullOrWhiteSpace($storageSubscriptionId)) {
    $storageSubscriptionId = $vaultSubscriptionId
    Write-Host "  Using vault subscription: $storageSubscriptionId" -ForegroundColor Gray
}

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

Write-Host ""
Write-Host "File Share Name:" -ForegroundColor Cyan
$fileShareName = Read-Host "  Enter File Share Name"
if ([string]::IsNullOrWhiteSpace($fileShareName)) {
    Write-Host "ERROR: File Share Name cannot be empty." -ForegroundColor Red
    exit 1
}

# Construct Storage Account Resource ID
$storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

# Construct container name
$containerName = "StorageContainer;storage;$storageResourceGroup;$storageAccountName"

Write-Host ""
Write-Host "Resource Identifiers:" -ForegroundColor Gray
Write-Host "  Storage Account Resource ID: $storageAccountResourceId" -ForegroundColor Gray
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

$verifyContainerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

try {
    $containerResponse = Invoke-RestMethod -Uri $verifyContainerUri -Method GET -Headers $headers
    
    if ($containerResponse.properties.registrationStatus -eq "Registered") {
        Write-Host "  Storage account is registered!" -ForegroundColor Green
        Write-Host "    Friendly Name: $($containerResponse.properties.friendlyName)" -ForegroundColor Gray
        Write-Host "    Health Status: $($containerResponse.properties.healthStatus)" -ForegroundColor Gray
        Write-Host ""
    } else {
        Write-Host ""
        Write-Host "ERROR: Storage account is not registered to this vault." -ForegroundColor Red
        Write-Host "  Registration Status: $($containerResponse.properties.registrationStatus)" -ForegroundColor Red
        Write-Host ""
        Write-Host "Please register the storage account first using:" -ForegroundColor Yellow
        Write-Host "  Register-StorageAccount-ToVault.ps1" -ForegroundColor White
        Write-Host ""
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Storage account is not registered to this vault." -ForegroundColor Red
    Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Please register the storage account first using:" -ForegroundColor Yellow
    Write-Host "  Register-StorageAccount-ToVault.ps1" -ForegroundColor White
    Write-Host ""
    exit 1
}

# ============================================================================
# STEP 2: INQUIRE FILE SHARES IN STORAGE ACCOUNT
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Discovering File Shares in Storage Account" -ForegroundColor Yellow
Write-Host "----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Triggering inquire operation to discover file shares..." -ForegroundColor Cyan

$inquireUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/inquire?api-version=$apiVersion"

try {
    $inquireResponse = Invoke-RestMethod -Uri $inquireUri -Method POST -Headers $headers
    Write-Host "  Inquire operation completed successfully" -ForegroundColor Green
    
    # Wait for discovery to complete
    Start-Sleep -Seconds 5
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202 -or $statusCode -eq 200) {
        Write-Host "  Inquire operation initiated" -ForegroundColor Green
        Start-Sleep -Seconds 5
    } else {
        Write-Host "  WARNING: Inquire operation returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing with protection configuration..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 3: LIST PROTECTABLE FILE SHARES
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Listing Available File Shares" -ForegroundColor Yellow
Write-Host "--------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Querying for protectable file shares..." -ForegroundColor Cyan

$protectableItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectableItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

$protectableItemId = $null
$protectedItemName = $null

try {
    $protectableResponse = Invoke-RestMethod -Uri $protectableItemsUri -Method GET -Headers $headers
    
    if ($protectableResponse.value -and $protectableResponse.value.Count -gt 0) {
        Write-Host "  Found $($protectableResponse.value.Count) file share(s)" -ForegroundColor Green
        Write-Host ""
        
        # Filter for file shares in this storage account
        $fileSharesInAccount = $protectableResponse.value | Where-Object {
            $_.properties.parentContainerFriendlyName -eq $storageAccountName
        }
        
        if ($fileSharesInAccount -and $fileSharesInAccount.Count -gt 0) {
            Write-Host "File shares in storage account '$storageAccountName':" -ForegroundColor Cyan
            foreach ($share in $fileSharesInAccount) {
                $status = $share.properties.protectionState
                $statusColor = if ($status -eq "NotProtected") { "White" } else { "Yellow" }
                Write-Host "  - $($share.properties.friendlyName) (Status: $status)" -ForegroundColor $statusColor
            }
            Write-Host ""
        }
        
        # Find the target file share
        $targetFileShare = $protectableResponse.value | Where-Object {
            $_.properties.friendlyName -eq $fileShareName -and
            $_.properties.parentContainerFriendlyName -eq $storageAccountName
        }
        
        if ($targetFileShare) {
            Write-Host "Target file share found:" -ForegroundColor Green
            Write-Host "  Name: $($targetFileShare.properties.friendlyName)" -ForegroundColor Gray
            Write-Host "  Protection State: $($targetFileShare.properties.protectionState)" -ForegroundColor Gray
            Write-Host "  Type: $($targetFileShare.properties.azureFileShareType)" -ForegroundColor Gray
            Write-Host ""
            
            # Check if already protected
            if ($targetFileShare.properties.protectionState -ne "NotProtected") {
                Write-Host "WARNING: File share '$fileShareName' is already protected!" -ForegroundColor Yellow
                Write-Host "  Current State: $($targetFileShare.properties.protectionState)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "Do you want to continue and update protection? (y/n):" -ForegroundColor Cyan
                $continue = Read-Host "  Enter choice"
                
                if ($continue -ne "y" -and $continue -ne "Y") {
                    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
                    exit 0
                }
            }
            
            # Extract protectable item name from the response
            $protectableItemId = $targetFileShare.id
            $protectedItemName = $targetFileShare.name
            
            Write-Host "  Protectable Item Name: $protectedItemName" -ForegroundColor Gray
        } else {
            Write-Host ""
            Write-Host "ERROR: File share '$fileShareName' not found in storage account." -ForegroundColor Red
            Write-Host ""
            
            if ($fileSharesInAccount -and $fileSharesInAccount.Count -gt 0) {
                Write-Host "Available file shares:" -ForegroundColor Yellow
                foreach ($share in $fileSharesInAccount) {
                    Write-Host "  - $($share.properties.friendlyName)" -ForegroundColor White
                }
            } else {
                Write-Host "No file shares found in storage account '$storageAccountName'" -ForegroundColor Yellow
            }
            Write-Host ""
            Write-Host "Please verify:" -ForegroundColor Yellow
            Write-Host "  1. File share name is correct" -ForegroundColor White
            Write-Host "  2. File share exists in the storage account" -ForegroundColor White
            Write-Host "  3. Storage account name is correct" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "WARNING: No protectable file shares found." -ForegroundColor Yellow
        Write-Host "Using manual name construction..." -ForegroundColor Yellow
        
        # Construct protectable item name manually
        $protectedItemName = "azurefileshare;$fileShareName"
        Write-Host "  Using protected item name: $protectedItemName" -ForegroundColor Gray
    }
} catch {
    Write-Host ""
    Write-Host "WARNING: Failed to list protectable items: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Using manual name construction..." -ForegroundColor Yellow
    
    # Construct protectable item name manually
    $protectedItemName = "azurefileshare;$fileShareName"
    Write-Host "  Using protected item name: $protectedItemName" -ForegroundColor Gray
}

# ============================================================================
# STEP 4: LIST AND SELECT BACKUP POLICY
# ============================================================================

Write-Host ""
Write-Host "STEP 4: Selecting Backup Policy" -ForegroundColor Yellow
Write-Host "--------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Retrieving available backup policies..." -ForegroundColor Cyan

$policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

try {
    $policiesResponse = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
    
    if ($policiesResponse.value -and $policiesResponse.value.Count -gt 0) {
        # Filter for Azure File Share policies
        $fileSharePolicies = $policiesResponse.value | Where-Object {
            $_.properties.backupManagementType -eq "AzureStorage"
        }
        
        if ($fileSharePolicies -and $fileSharePolicies.Count -gt 0) {
            Write-Host "  Found $($fileSharePolicies.Count) backup policy/policies for Azure File Shares" -ForegroundColor Green
            Write-Host ""
            
            Write-Host "Available Backup Policies:" -ForegroundColor Cyan
            
            $policyIndex = 1
            $policyMap = @{}
            
            foreach ($policy in $fileSharePolicies) {
                $policyName = $policy.name
                $schedulePolicy = $policy.properties.schedulePolicy
                $retentionPolicy = $policy.properties.retentionPolicy
                
                Write-Host "  [$policyIndex] $policyName" -ForegroundColor White
                
                # Display schedule details if available
                if ($schedulePolicy) {
                    Write-Host "      Schedule: $($schedulePolicy.scheduleRunFrequency)" -ForegroundColor Gray
                    if ($schedulePolicy.scheduleRunTimes) {
                        $time = $schedulePolicy.scheduleRunTimes[0]
                        Write-Host "      Time: $time" -ForegroundColor Gray
                    }
                }
                
                # Display retention details if available
                if ($retentionPolicy -and $retentionPolicy.dailySchedule) {
                    $days = $retentionPolicy.dailySchedule.retentionDuration.count
                    Write-Host "      Retention: $days days" -ForegroundColor Gray
                }
                
                Write-Host ""
                
                $policyMap[$policyIndex] = $policy
                $policyIndex++
            }
            
            # User selects policy
            Write-Host "Select a backup policy (enter number):" -ForegroundColor Cyan
            $selectedPolicyIndex = Read-Host "  Enter policy number"
            
            try {
                $selectedPolicyIndexInt = [int]$selectedPolicyIndex
                
                if ($policyMap.ContainsKey($selectedPolicyIndexInt)) {
                    $selectedPolicy = $policyMap[$selectedPolicyIndexInt]
                    $policyId = $selectedPolicy.id
                    $policyName = $selectedPolicy.name
                    
                    Write-Host "  Selected: $policyName" -ForegroundColor Green
                    Write-Host "  Policy ID: $policyId" -ForegroundColor Gray
                    Write-Host ""
                } else {
                    Write-Host "ERROR: Invalid policy selection." -ForegroundColor Red
                    exit 1
                }
            } catch {
                Write-Host "ERROR: Invalid input. Please enter a number." -ForegroundColor Red
                exit 1
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: No backup policies found for Azure File Shares." -ForegroundColor Red
            Write-Host ""
            Write-Host "Please create a backup policy in the vault first." -ForegroundColor Yellow
            Write-Host "You can create policies via Azure Portal or using Azure PowerShell/CLI." -ForegroundColor Yellow
            Write-Host ""
            exit 1
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No backup policies found in vault." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please create a backup policy in the vault first." -ForegroundColor Yellow
        Write-Host ""
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to retrieve backup policies: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ============================================================================
# STEP 5: ENABLE BACKUP PROTECTION
# ============================================================================

Write-Host ""
Write-Host "STEP 5: Enabling Backup Protection" -ForegroundColor Yellow
Write-Host "-----------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Preparing protection configuration..." -ForegroundColor Cyan
Write-Host "  File Share: $fileShareName" -ForegroundColor Gray
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Gray
Write-Host "  Policy: $policyName" -ForegroundColor Gray
Write-Host ""

# URL-encode the protected item name
$protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
$containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)

# Enable protection URI
$enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded`?api-version=$apiVersion"

# Request body for enabling protection
$protectionBody = @{
    properties = @{
        protectedItemType = "AzureFileShareProtectedItem"
        sourceResourceId = $storageAccountResourceId
        policyId = $policyId
    }
} | ConvertTo-Json -Depth 10

Write-Host "Submitting protection configuration request..." -ForegroundColor Cyan

try {
    $protectionResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody
    
    Write-Host "  Protection configuration submitted successfully!" -ForegroundColor Green
    Write-Host ""
    
    # Wait for protection to complete
    Write-Host "Configuring backup protection..." -ForegroundColor Cyan
    Start-Sleep -Seconds 50
    
    # Verify protection status
    Write-Host "Verifying protection status..." -ForegroundColor Cyan
    
    try {
        $verifyProtectionResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers
        
        Write-Host ""
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "  PROTECTION CONFIGURED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host ""
        Write-Host "Protected Item Details:" -ForegroundColor Cyan
        Write-Host "  File Share: $($verifyProtectionResponse.properties.friendlyName)" -ForegroundColor White
        Write-Host "  Protection State: $($verifyProtectionResponse.properties.protectionState)" -ForegroundColor White
        Write-Host "  Health Status: $($verifyProtectionResponse.properties.healthStatus)" -ForegroundColor White
        Write-Host "  Policy Name: $policyName" -ForegroundColor White
        Write-Host "  Last Backup Time: $($verifyProtectionResponse.properties.lastBackupTime)" -ForegroundColor White
        Write-Host ""
        Write-Host "Next Steps:" -ForegroundColor Yellow
        Write-Host "  1. Backup will run automatically according to the policy schedule" -ForegroundColor White
        Write-Host "  2. You can trigger an on-demand backup from Azure Portal -> Vault -> Backup Items" -ForegroundColor White
        Write-Host "  3. Monitor backup jobs in Azure Portal > Recovery Services Vault > Backup Jobs" -ForegroundColor White
        Write-Host ""
    } catch {
        Write-Host "  WARNING: Protection configured but verification failed" -ForegroundColor Yellow
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
        Write-Host ""
    }
    
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        # 202 Accepted means the operation is being processed
        Write-Host "  Protection request accepted (202)" -ForegroundColor Green
        Write-Host "  Protection configuration is in progress..." -ForegroundColor Yellow
        Write-Host ""
        
        # Poll for completion
        Write-Host "Waiting for protection to be configured..." -ForegroundColor Cyan
        
        $maxRetries = 20
        $retryCount = 0
        $completed = $false
        
        while (-not $completed -and $retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 6
            
            try {
                $statusCheck = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers
                
                if ($statusCheck.properties.protectionState -ne "Invalid" -and 
                    $statusCheck.properties.protectionState -ne "IRPending") {
                    $completed = $true
                    
                    Write-Host ""
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host "  PROTECTION CONFIGURED SUCCESSFULLY!" -ForegroundColor Green
                    Write-Host "========================================" -ForegroundColor Green
                    Write-Host ""
                    Write-Host "Protected Item Details:" -ForegroundColor Cyan
                    Write-Host "  File Share: $fileShareName" -ForegroundColor White
                    Write-Host "  Protection State: $($statusCheck.properties.protectionState)" -ForegroundColor White
                    Write-Host "  Health Status: $($statusCheck.properties.healthStatus)" -ForegroundColor White
                    Write-Host "  Policy Name: $policyName" -ForegroundColor White
                    Write-Host ""
                } else {
                    $retryCount++
                    Write-Host "  Configuring... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                }
            } catch {
                $retryCount++
                Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
            }
        }
        
        if (-not $completed) {
            Write-Host ""
            Write-Host "  Protection configuration is taking longer than expected." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to verify protection status." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: Failed to enable backup protection" -ForegroundColor Red
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
        Write-Host "  1. Storage account not registered to vault" -ForegroundColor White
        Write-Host "  2. File share doesn't exist in storage account" -ForegroundColor White
        Write-Host "  3. Insufficient permissions" -ForegroundColor White
        Write-Host "  4. Policy incompatible with file share type" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

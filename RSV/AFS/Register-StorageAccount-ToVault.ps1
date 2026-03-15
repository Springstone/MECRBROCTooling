<#
.SYNOPSIS
    Registers an Azure Storage Account to a Recovery Services Vault using REST API.

.DESCRIPTION
    This script registers a storage account containing Azure File Shares to a Recovery Services Vault
    for backup protection using Azure Backup REST API.
    
    The script supports:
    - Cross-subscription scenarios (Storage Account and Vault in different subscriptions)
    - Discovery of unprotected file shares in the storage account
    - Registration of storage account to vault for backup operations
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
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

# ============================================================================
# RUNTIME INPUT COLLECTION
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Register Storage Account to Recovery Services Vault" -ForegroundColor Cyan
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

# Construct Storage Account Resource ID
$storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

Write-Host ""
Write-Host "Storage Account Resource ID:" -ForegroundColor Gray
Write-Host "  $storageAccountResourceId" -ForegroundColor Gray

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
    # Az module 12+ returns SecureString for .Token; older versions return plain string
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
# STEP 1: REFRESH CONTAINER DISCOVERY
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Discovering Storage Accounts with File Shares" -ForegroundColor Yellow
Write-Host "-------------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Triggering refresh operation to discover storage accounts..." -ForegroundColor Cyan

# Refresh operation to discover storage accounts
$refreshUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/refreshContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

try {
    $refreshResponse = Invoke-RestMethod -Uri $refreshUri -Method POST -Headers $headers
    Write-Host "  Refresh operation initiated successfully" -ForegroundColor Green
    
    # Check for Location header to track operation
    if ($refreshResponse.PSObject.Properties.Name -contains 'Headers' -and $refreshResponse.Headers.Location) {
        $locationUrl = $refreshResponse.Headers.Location
        Write-Host "  Tracking operation status..." -ForegroundColor Cyan
        
        # Poll the location URL
        $maxRetries = 10
        $retryCount = 0
        $completed = $false
        
        while (-not $completed -and $retryCount -lt $maxRetries) {
            Start-Sleep -Seconds 6
            
            try {
                $statusResponse = Invoke-RestMethod -Uri $locationUrl -Method GET -Headers $headers
                $completed = $true
                Write-Host "  Discovery operation completed" -ForegroundColor Green
            } catch {
                if ($_.Exception.Response.StatusCode.value__ -eq 204) {
                    # 204 No Content means success
                    $completed = $true
                    Write-Host "  Discovery operation completed (204 No Content)" -ForegroundColor Green
                } else {
                    $retryCount++
                    Write-Host "  Waiting for operation to complete... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                }
            }
        }
    } else {
        # Wait a bit for the operation to complete
        Start-Sleep -Seconds 10
        Write-Host "  Discovery operation triggered (no tracking URL available)" -ForegroundColor Yellow
    }
} catch {
    # Some errors are expected (like 202 Accepted), continue anyway
    if ($_.Exception.Response.StatusCode.value__ -eq 202) {
        Write-Host "  Refresh operation accepted (202)" -ForegroundColor Green
        Start-Sleep -Seconds 10
    } else {
        Write-Host "  WARNING: Refresh operation returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing with discovery..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 2: GET PROTECTABLE CONTAINERS (STORAGE ACCOUNTS)
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Listing Discoverable Storage Accounts" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# Get list of protectable containers
$protectableContainersUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectableContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"

try {
    Write-Host "Querying for protectable storage accounts..." -ForegroundColor Cyan
    $containersResponse = Invoke-RestMethod -Uri $protectableContainersUri -Method GET -Headers $headers
    
    if ($containersResponse.value -and $containersResponse.value.Count -gt 0) {
        Write-Host "  Found $($containersResponse.value.Count) storage account(s) available for backup" -ForegroundColor Green
        Write-Host ""
        
        # Find matching storage account
        $matchingContainer = $containersResponse.value | Where-Object {
            $_.properties.containerId -eq $storageAccountResourceId
        }
        
        if ($matchingContainer) {
            Write-Host "Target storage account found in discoverable list:" -ForegroundColor Green
            Write-Host "  Friendly Name: $($matchingContainer.properties.friendlyName)" -ForegroundColor Gray
            Write-Host "  Container ID: $($matchingContainer.properties.containerId)" -ForegroundColor Gray
            Write-Host "  Health Status: $($matchingContainer.properties.healthStatus)" -ForegroundColor Gray
            Write-Host ""
            
            # Extract container name from the response
            $containerName = $matchingContainer.name
            Write-Host "  Container Name: $containerName" -ForegroundColor Gray
        } else {
            Write-Host ""
            Write-Host "WARNING: Storage account '$storageAccountName' not found in discoverable list." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Available storage accounts:" -ForegroundColor Yellow
            foreach ($container in $containersResponse.value) {
                $saName = $container.properties.friendlyName
                Write-Host "  - $saName" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "This could mean:" -ForegroundColor Yellow
            Write-Host "  1. Storage account is in a different subscription than expected" -ForegroundColor White
            Write-Host "  2. Storage account name is incorrect" -ForegroundColor White
            Write-Host "  3. Vault doesn't have permissions to discover the storage account" -ForegroundColor White
            Write-Host ""
            Write-Host "Constructing container name manually for registration attempt..." -ForegroundColor Yellow
            
            # Construct container name manually
            $containerName = "StorageContainer;Storage;$storageResourceGroup;$storageAccountName"
            Write-Host "  Using container name: $containerName" -ForegroundColor Gray
        }
    } else {
        Write-Host ""
        Write-Host "WARNING: No protectable storage accounts discovered." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Constructing container name manually..." -ForegroundColor Yellow
        $containerName = "StorageContainer;Storage;$storageResourceGroup;$storageAccountName"
        Write-Host "  Using container name: $containerName" -ForegroundColor Gray
    }
} catch {
    Write-Host ""
    Write-Host "WARNING: Failed to list protectable containers: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "Constructing container name manually..." -ForegroundColor Yellow
    
    # Construct container name based on standard format
    $containerName = "StorageContainer;Storage;$storageResourceGroup;$storageAccountName"
    Write-Host "  Using container name: $containerName" -ForegroundColor Gray
}

# ============================================================================
# STEP 3: REGISTER STORAGE ACCOUNT TO VAULT
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Registering Storage Account to Vault" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Preparing registration request..." -ForegroundColor Cyan
Write-Host "  Vault: $vaultName" -ForegroundColor Gray
Write-Host "  Storage Account: $storageAccountName" -ForegroundColor Gray
Write-Host "  Container Name: $containerName" -ForegroundColor Gray
Write-Host ""

# Registration URI
$registrationUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

# Request body for registration
$registrationBody = @{
    properties = @{
        containerType = "StorageContainer"
        sourceResourceId = $storageAccountResourceId
        resourceGroup = $storageResourceGroup
        friendlyName = $storageAccountName
        backupManagementType = "AzureStorage"
    }
} | ConvertTo-Json -Depth 10

Write-Host "Submitting registration request..." -ForegroundColor Cyan

try {
    $registrationResponse = Invoke-RestMethod -Uri $registrationUri -Method PUT -Headers $headers -Body $registrationBody
    
    Write-Host "  Registration request submitted successfully!" -ForegroundColor Green
    Write-Host ""
    
    # Wait for registration to complete
    Write-Host "Waiting for registration to complete..." -ForegroundColor Cyan
    Start-Sleep -Seconds 10
    
    # Verify registration by checking the container status
    Write-Host "Verifying registration status..." -ForegroundColor Cyan
    
    $verifyUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"
    
    try {
        $verifyResponse = Invoke-RestMethod -Uri $verifyUri -Method GET -Headers $headers
        
        if ($verifyResponse.properties.registrationStatus -eq "Registered") {
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  REGISTRATION SUCCESSFUL!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Storage Account Details:" -ForegroundColor Cyan
            Write-Host "  Friendly Name: $($verifyResponse.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Registration Status: $($verifyResponse.properties.registrationStatus)" -ForegroundColor White
            Write-Host "  Health Status: $($verifyResponse.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Container Type: $($verifyResponse.properties.containerType)" -ForegroundColor White
            Write-Host "  Source Resource ID: $($verifyResponse.properties.sourceResourceId)" -ForegroundColor White
            Write-Host ""
            Write-Host "Next Steps:" -ForegroundColor Yellow
            Write-Host "  1. Discover file shares in this storage account" -ForegroundColor White
            Write-Host "  2. Configure backup protection for desired file shares" -ForegroundColor White
            Write-Host "  3. Use Configure-AzureFileShare-Protection.ps1 script" -ForegroundColor White
            Write-Host ""
        } else {
            Write-Host "  WARNING: Registration status is '$($verifyResponse.properties.registrationStatus)'" -ForegroundColor Yellow
            Write-Host "  This may take a few minutes to complete." -ForegroundColor Yellow
            Write-Host ""
        }
    } catch {
        Write-Host "  WARNING: Could not verify registration status immediately" -ForegroundColor Yellow
        Write-Host "  Registration may still be in progress. Please check the Azure Portal." -ForegroundColor Yellow
        Write-Host ""
    }
    
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        # 202 Accepted means the operation is being processed
        Write-Host "  Registration request accepted (202)" -ForegroundColor Green
        Write-Host ""
        
        # Try to get the operation URL from headers
        if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers["Location"]) {
            $operationUrl = $_.Exception.Response.Headers["Location"]
            Write-Host "  Tracking operation..." -ForegroundColor Cyan
            
            # Poll operation status
            $maxRetries = 20
            $retryCount = 0
            $operationCompleted = $false
            
            while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 6
                
                try {
                    $operationStatus = Invoke-RestMethod -Uri $operationUrl -Method GET -Headers $headers
                    
                    if ($operationStatus.properties.registrationStatus -eq "Registered") {
                        $operationCompleted = $true
                        Write-Host ""
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host "  REGISTRATION SUCCESSFUL!" -ForegroundColor Green
                        Write-Host "========================================" -ForegroundColor Green
                        Write-Host ""
                        Write-Host "Storage Account Details:" -ForegroundColor Cyan
                        Write-Host "  Friendly Name: $($operationStatus.properties.friendlyName)" -ForegroundColor White
                        Write-Host "  Registration Status: $($operationStatus.properties.registrationStatus)" -ForegroundColor White
                        Write-Host "  Health Status: $($operationStatus.properties.healthStatus)" -ForegroundColor White
                        Write-Host ""
                    } else {
                        $retryCount++
                        Write-Host "  Waiting for registration... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                    }
                } catch {
                    $retryCount++
                    Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                }
            }
            
            if (-not $operationCompleted) {
                Write-Host ""
                Write-Host "  Registration is taking longer than expected." -ForegroundColor Yellow
                Write-Host "  Please check the Azure Portal to verify registration status." -ForegroundColor Yellow
                Write-Host ""
            }
        } else {
            Write-Host "  Registration operation is in progress." -ForegroundColor Yellow
            Write-Host "  Please check the Azure Portal to verify completion." -ForegroundColor Yellow
            Write-Host ""
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: Storage Account registration failed" -ForegroundColor Red
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
        Write-Host "  1. Storage account is already registered to another vault" -ForegroundColor White
        Write-Host "  2. Insufficient permissions on storage account or vault" -ForegroundColor White
        Write-Host "  3. Storage account doesn't exist or resource ID is incorrect" -ForegroundColor White
        Write-Host "  4. Cross-subscription registration not permitted by policy" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

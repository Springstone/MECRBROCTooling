<#
.SYNOPSIS
    Restores SQL Server databases from Azure Backup on Azure IaaS VMs 
    using the Recovery Services Vault REST API.

.DESCRIPTION
    This script restores SQL Server databases protected by Azure Backup using 
    the Azure Backup REST API.
    
    The script supports:
    - Alternate Location Restore (ALR) - restore to a different database name on the same or different SQL VM
    - Restore as Files - restore backup as .bak/.log files to a file path on a target VM
    - Point-in-Time (Log) restore - restore to a specific point in time (works with both ALR and RestoreAsFiles)
    - Interactive recovery point selection when not specified
    - Interactive database selection when not specified
    
    Flow:
    1. Authenticate to Azure (PowerShell or CLI)
    2. List protected SQL databases on the VM and find the target database
    3. List recovery points (Full + Log), display and let user pick if not specified
    4. For Point-in-Time restore, show log time ranges
    5. Build the restore request body based on RestoreType
    6. Trigger the restore operation
    7. Track the async operation and show job status
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on the Recovery Services Vault
    - For ALR/RestoreAsFiles: target VM must be registered to the same vault

.PARAMETER VaultSubscriptionId
    The Subscription ID where the Recovery Services Vault is located.

.PARAMETER VaultResourceGroup
    The Resource Group name of the Recovery Services Vault.

.PARAMETER VaultName
    The name of the Recovery Services Vault.

.PARAMETER VMResourceGroup
    The Resource Group name of the source SQL Server VM.

.PARAMETER VMName
    The name of the source Azure VM hosting the SQL Server database to restore.

.PARAMETER DatabaseName
    The name of the SQL database to restore. If not specified, the script will 
    list all protected databases on the VM and prompt for selection.

.PARAMETER InstanceName
    The name of the SQL instance (e.g. MSSQLSERVER, SQLEXPRESS).
    When specified, filters protected databases to only those belonging
    to this instance. Useful when a VM has multiple SQL instances and 
    the same database name exists in more than one.

.PARAMETER RestoreType
    The type of restore to perform. Valid values: ALR, RestoreAsFiles.
    - ALR: Alternate Location Restore (restore to different DB name/VM)
    - RestoreAsFiles: Restore backup as .bak/.log files to a file path

.PARAMETER RecoveryPointId
    The ID of the recovery point to restore from. If not specified, the script 
    will list available recovery points and prompt for selection.

.PARAMETER PointInTime
    ISO 8601 datetime string for point-in-time (log) restore. 
    Example: "2026-03-10T14:30:00Z"
    If specified, the restore uses AzureWorkloadSQLPointInTimeRestoreRequest.

.PARAMETER TargetVMName
    The name of the target VM for ALR and RestoreAsFiles. Required for ALR and RestoreAsFiles.

.PARAMETER TargetVMResourceGroup
    The Resource Group of the target VM. Required for ALR and RestoreAsFiles.

.PARAMETER TargetDatabaseName
    The target database name for ALR. Format: INSTANCENAME/DatabaseName.
    Required for ALR.

.PARAMETER TargetFilePath
    The target file path for RestoreAsFiles. The directory on the target VM 
    where .bak/.log files will be restored. Required for RestoreAsFiles.

.PARAMETER OverwriteExisting
    Switch to overwrite existing database/files.
    Default behavior: FailOnConflict for ALR.

.PARAMETER TargetDataPath
    Target directory path for the restored database data files (.mdf/.ndf) in ALR.
    Required for ALR. The script appends the filename based on the target database name.
    Example: "D:\SQLData"

.PARAMETER TargetLogPath
    Target directory path for the restored database log files (.ldf) in ALR.
    Required for ALR. The script appends the filename based on the target database name.
    Example: "D:\SQLLogs"

.EXAMPLE
    # Alternate Location Restore to a different VM
    .\Restore-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" -RestoreType ALR `
        -TargetVMName "sql-vm-02" -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored"

.EXAMPLE
    # Restore as Files to a target VM
    .\Restore-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" -RestoreType RestoreAsFiles `
        -TargetVMName "sql-vm-02" -TargetVMResourceGroup "rg-sql" `
        -TargetFilePath "F:\SQLBackups\Restore"

.EXAMPLE
    # Point-in-Time restore to alternate location
    .\Restore-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" -RestoreType ALR -PointInTime "2026-03-10T14:30:00Z" `
        -TargetVMName "sql-vm-02" -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_PIT"

.NOTES
    Author: Azure Backup Script Generator
    Date: March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/restore-azure-sql-vm-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/restores/trigger
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/recovery-points/list
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Subscription ID where the Recovery Services Vault is located.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultSubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the source SQL Server VM.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the source Azure VM hosting the SQL Server database to restore.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SQL database to restore. If omitted, available databases will be listed for selection.")]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SQL instance to target (e.g. MSSQLSERVER). Filters databases to this instance.")]
    [string]$InstanceName,

    [Parameter(Mandatory = $true, HelpMessage = "Type of restore: ALR (Alternate Location), RestoreAsFiles.")]
    [ValidateSet("ALR", "RestoreAsFiles")]
    [string]$RestoreType,

    [Parameter(Mandatory = $false, HelpMessage = "Recovery point ID to restore from. If omitted, available recovery points will be listed for selection.")]
    [string]$RecoveryPointId,

    [Parameter(Mandatory = $false, HelpMessage = "ISO 8601 datetime for point-in-time (log) restore. Example: 2026-03-10T14:30:00Z")]
    [string]$PointInTime,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the target VM for ALR and RestoreAsFiles.")]
    [string]$TargetVMName,

    [Parameter(Mandatory = $false, HelpMessage = "Resource Group of the target VM for ALR and RestoreAsFiles.")]
    [string]$TargetVMResourceGroup,

    [Parameter(Mandatory = $false, HelpMessage = "Target database name for ALR. Format: INSTANCENAME/DatabaseName")]
    [string]$TargetDatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Target file path for RestoreAsFiles. Directory on target VM for .bak/.log files.")]
    [string]$TargetFilePath,

    [Parameter(Mandatory = $false, HelpMessage = "Overwrite existing database/files. Default: FailOnConflict for ALR.")]
    [switch]$OverwriteExisting,

    [Parameter(Mandatory = $false, HelpMessage = "Target path for data files (.mdf/.ndf). Required for ALR. Example: D:\SQLData")]
    [string]$TargetDataPath,

    [Parameter(Mandatory = $false, HelpMessage = "Target path for log files (.ldf). Required for ALR. Example: D:\SQLLogs")]
    [string]$TargetLogPath
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"
$apiVersionProtection = "2025-08-01"

# ============================================================================
# HELPER FUNCTION: Poll async operation via Location header
# ============================================================================

function Wait-ForAsyncOperation {
    param(
        [string]$LocationUrl,
        [hashtable]$Headers,
        [int]$MaxRetries = 20,
        [int]$DelaySeconds = 6,
        [string]$OperationName = "Operation"
    )
    
    if ([string]::IsNullOrWhiteSpace($LocationUrl)) {
        Write-Host "  No tracking URL available. Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($DelaySeconds * 3)
        return $true
    }
    
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds
        
        try {
            $statusResponse = Invoke-WebRequest -Uri $LocationUrl -Method GET -Headers $Headers -UseBasicParsing
            if ($statusResponse.StatusCode -eq 200 -or $statusResponse.StatusCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        }
        
        $retryCount++
        Write-Host "  Waiting for $OperationName... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
    }
    
    Write-Host "  WARNING: $OperationName timed out." -ForegroundColor Yellow
    return $false
}

# ============================================================================
# HELPER FUNCTION: Parse error response
# ============================================================================

function Write-ApiError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = "API call"
    )
    
    $statusCode = $ErrorRecord.Exception.Response.StatusCode.value__
    Write-Host "  Status Code: $statusCode" -ForegroundColor Red
    Write-Host "  Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    
    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json
        
        if ($errorJson.error) {
            Write-Host "  Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch {
        # Could not parse error response
    }
}

# ============================================================================
# HELPER FUNCTION: Track restore job via Azure-AsyncOperation header
# ============================================================================

function Wait-ForRestoreJob {
    param(
        [string]$AsyncUrl,
        [string]$LocationUrl,
        [hashtable]$Headers,
        [int]$MaxRetries = 60,
        [int]$DelaySeconds = 10,
        [string]$OperationName = "Restore"
    )
    
    $trackingUrl = if (-not [string]::IsNullOrWhiteSpace($AsyncUrl)) { $AsyncUrl } else { $LocationUrl }
    
    if ([string]::IsNullOrWhiteSpace($trackingUrl)) {
        Write-Host "  No tracking URL available. Check Azure Portal for job status." -ForegroundColor Yellow
        return $null
    }
    
    Write-Host "  Tracking $OperationName job..." -ForegroundColor Cyan
    Write-Host "  (This may take several minutes depending on database size)" -ForegroundColor Gray
    Write-Host ""
    
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds
        
        try {
            $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $Headers
            $opStatus = $null
            if ($opResponse.status) { $opStatus = $opResponse.status }
            
            if ($opStatus -eq "Succeeded") {
                Write-Host "  $OperationName completed successfully!" -ForegroundColor Green
                return $opResponse
            } elseif ($opStatus -eq "Failed") {
                Write-Host "  $OperationName FAILED." -ForegroundColor Red
                if ($opResponse.error) {
                    Write-Host "  Error Code: $($opResponse.error.code)" -ForegroundColor Red
                    Write-Host "  Error Message: $($opResponse.error.message)" -ForegroundColor Red
                }
                return $opResponse
            } elseif ($opStatus -eq "Cancelled") {
                Write-Host "  $OperationName was cancelled." -ForegroundColor Yellow
                return $opResponse
            } else {
                $retryCount++
                Write-Host "  Waiting for $OperationName... ($retryCount/$MaxRetries) [Status: $opStatus]" -ForegroundColor Yellow
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                Write-Host "  $OperationName completed." -ForegroundColor Green
                return $null
            }
            $retryCount++
            Write-Host "  Polling... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
        }
    }
    
    Write-Host "  WARNING: $OperationName tracking timed out. Check Azure Portal for status." -ForegroundColor Yellow
    return $null
}

# ============================================================================
# PARAMETER VALIDATION
# ============================================================================

$vaultSubscriptionId = $VaultSubscriptionId
$vaultResourceGroup  = $VaultResourceGroup
$vaultName           = $VaultName
$vmResourceGroup     = $VMResourceGroup
$vmName              = $VMName
$vmResourceId        = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vmResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

# Validate parameters based on RestoreType
if ($RestoreType -eq "ALR") {
    if ([string]::IsNullOrWhiteSpace($TargetVMName)) {
        Write-Host "ERROR: -TargetVMName is required for Alternate Location Restore (ALR)." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetVMResourceGroup)) {
        Write-Host "ERROR: -TargetVMResourceGroup is required for Alternate Location Restore (ALR)." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetDatabaseName)) {
        Write-Host "ERROR: -TargetDatabaseName is required for Alternate Location Restore (ALR)." -ForegroundColor Red
        Write-Host "  Format: INSTANCENAME/DatabaseName (e.g., MSSQLSERVER/SalesDB_Restored)" -ForegroundColor Yellow
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetDataPath)) {
        Write-Host "ERROR: -TargetDataPath is required for Alternate Location Restore (ALR)." -ForegroundColor Red
        Write-Host "  Example: D:\SQLData" -ForegroundColor Yellow
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetLogPath)) {
        Write-Host "ERROR: -TargetLogPath is required for Alternate Location Restore (ALR)." -ForegroundColor Red
        Write-Host "  Example: D:\SQLLogs" -ForegroundColor Yellow
        exit 1
    }
}

if ($RestoreType -eq "RestoreAsFiles") {
    if ([string]::IsNullOrWhiteSpace($TargetVMName)) {
        Write-Host "ERROR: -TargetVMName is required for Restore as Files." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetVMResourceGroup)) {
        Write-Host "ERROR: -TargetVMResourceGroup is required for Restore as Files." -ForegroundColor Red
        exit 1
    }
    if ([string]::IsNullOrWhiteSpace($TargetFilePath)) {
        Write-Host "ERROR: -TargetFilePath is required for Restore as Files." -ForegroundColor Red
        Write-Host "  Example: F:\SQLBackups\Restore" -ForegroundColor Yellow
        exit 1
    }
}

# ============================================================================
# DISPLAY CONFIGURATION SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server on Azure IaaS VM - Restore from Backup" -ForegroundColor Cyan
Write-Host "  (Using Azure Backup REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "  Vault Subscription:  $vaultSubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Resource Group:$vaultResourceGroup" -ForegroundColor Gray
Write-Host "  Vault Name:          $vaultName" -ForegroundColor Gray
Write-Host "  Source VM RG:        $vmResourceGroup" -ForegroundColor Gray
Write-Host "  Source VM Name:      $vmName" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
    Write-Host "  Database Name:       $DatabaseName" -ForegroundColor Gray
} else {
    Write-Host "  Database Name:       (will be selected interactively)" -ForegroundColor Gray
}
Write-Host "  Restore Type:        $RestoreType" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($PointInTime)) {
    Write-Host "  Point-in-Time:       $PointInTime" -ForegroundColor Gray
}
if ($RestoreType -eq "ALR") {
    Write-Host "  Target VM:           $TargetVMName (RG: $TargetVMResourceGroup)" -ForegroundColor Gray
    Write-Host "  Target Database:     $TargetDatabaseName" -ForegroundColor Gray
} elseif ($RestoreType -eq "RestoreAsFiles") {
    Write-Host "  Target VM:           $TargetVMName (RG: $TargetVMResourceGroup)" -ForegroundColor Gray
    Write-Host "  Target File Path:    $TargetFilePath" -ForegroundColor Gray
}
if (-not [string]::IsNullOrWhiteSpace($RecoveryPointId)) {
    Write-Host "  Recovery Point:      $RecoveryPointId" -ForegroundColor Gray
} else {
    Write-Host "  Recovery Point:      (will be selected interactively)" -ForegroundColor Gray
}
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null
$authMethod = $null

# Try Azure PowerShell first
try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    
    # Handle both old (plain string) and new (SecureString) Az.Accounts module versions
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        # Use NetworkCredential trick - works reliably on both Windows and Linux
        $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    } else {
        $token = $tokenResponse.Token
    }
    
    # Validate token looks like a JWT (starts with eyJ)
    if (-not $token.StartsWith("eyJ")) {
        Write-Host "  WARNING: Token does not appear to be a valid JWT. Trying Azure CLI fallback..." -ForegroundColor Yellow
        throw "Invalid token format"
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
    "Content-Type"  = "application/json"
}

# ============================================================================
# STEP 1: LIST PROTECTED SQL DATABASES ON THE VM
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Listing Protected SQL Databases on VM" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersionProtection&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"

$allProtectedItems = @()
$vmProtectedDBs = @()
$selectedDB = $null

try {
    Write-Host "Querying for protected SQL databases..." -ForegroundColor Cyan
    
    $currentUri = $protectedItemsUri
    while ($currentUri) {
        $itemsResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers
        
        if ($itemsResponse.value) {
            $allProtectedItems += $itemsResponse.value
        }
        
        $currentUri = $itemsResponse.nextLink
        if ($currentUri) {
            Write-Host "  Fetching next page..." -ForegroundColor Gray
        }
    }
    
    # Filter to items belonging to our VM
    $vmProtectedDBs = $allProtectedItems | Where-Object {
        $expectedContainerSuffix = ";$vmName".ToLower()
        $expectedContainerFull = "VMAppContainer;Compute;$vmResourceGroup;$vmName".ToLower()
        $_.properties.containerName -and $_.properties.containerName.ToLower().EndsWith($expectedContainerSuffix) -or
        $_.id -and $_.id.ToLower().Contains($expectedContainerFull)
    }
    
    if ($vmProtectedDBs.Count -eq 0) {
        Write-Host "  ERROR: No protected SQL databases found on VM '$vmName'." -ForegroundColor Red
        Write-Host "  Make sure the VM has protected databases in vault '$vaultName'." -ForegroundColor Yellow
        exit 1
    }
    
    Write-Host "  Found $($vmProtectedDBs.Count) protected SQL database(s) on VM '$vmName'" -ForegroundColor Green
    Write-Host ""
    
    # Filter by -InstanceName if provided
    if (-not [string]::IsNullOrWhiteSpace($InstanceName)) {
        $filteredDBs = @($vmProtectedDBs | Where-Object { $_.properties.parentName -ieq $InstanceName })
        if ($filteredDBs.Count -eq 0) {
            Write-Host "  WARNING: No protected databases found for instance '$InstanceName'." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Available instances with protected databases:" -ForegroundColor Yellow
            $instGroups = $vmProtectedDBs | Group-Object { $_.properties.parentName }
            foreach ($g in $instGroups) {
                Write-Host "    - $($g.Name) ($($g.Count) database(s))" -ForegroundColor White
            }
            Write-Host ""
            exit 1
        }
        Write-Host "  Filtered to instance '$InstanceName': $($filteredDBs.Count) database(s)" -ForegroundColor Cyan
        $vmProtectedDBs = $filteredDBs
        Write-Host ""
    }
    
    # Display protected databases grouped by instance if multiple instances
    $instanceGroupsDisplay = $vmProtectedDBs | Group-Object { $_.properties.parentName }
    if ($instanceGroupsDisplay.Count -gt 1) {
        $globalIdx = 1
        foreach ($group in $instanceGroupsDisplay) {
            Write-Host "  [$($group.Name)]" -ForegroundColor Yellow
            foreach ($db in $group.Group) {
                $state = $db.properties.protectionState
                $policy = $db.properties.policyName
                $lastBackup = $db.properties.lastBackupTime
                
                Write-Host "    [$globalIdx] $($db.properties.friendlyName)" -ForegroundColor White
                Write-Host "         State:          $state" -ForegroundColor Gray
                Write-Host "         Policy:         $policy" -ForegroundColor Gray
                Write-Host "         Last Backup:    $lastBackup" -ForegroundColor Gray
                Write-Host ""
                $globalIdx++
            }
        }
    } else {
        $dbIdx = 1
        foreach ($db in $vmProtectedDBs) {
            $state = $db.properties.protectionState
            $policy = $db.properties.policyName
            $lastBackup = $db.properties.lastBackupTime
            
            Write-Host "  [$dbIdx] $($db.properties.friendlyName)" -ForegroundColor White
            Write-Host "       Instance:       $($db.properties.parentName)" -ForegroundColor Gray
            Write-Host "       State:          $state" -ForegroundColor Gray
            Write-Host "       Policy:         $policy" -ForegroundColor Gray
            Write-Host "       Last Backup:    $lastBackup" -ForegroundColor Gray
            Write-Host ""
            $dbIdx++
        }
    }
    
    # Select the database
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        if (-not [string]::IsNullOrWhiteSpace($InstanceName)) {
            # Filter by both DatabaseName and InstanceName
            $selectedDB = $vmProtectedDBs | Where-Object {
                $_.properties.friendlyName -ieq $DatabaseName -and $_.properties.parentName -ieq $InstanceName
            }
        } else {
            $selectedDB = $vmProtectedDBs | Where-Object {
                $_.properties.friendlyName -eq $DatabaseName -or
                $_.properties.friendlyName -ieq $DatabaseName
            }
            
            # If multiple matches (same DB name in different instances), warn and prompt
            if ($selectedDB -is [array] -and $selectedDB.Count -gt 1) {
                Write-Host "  WARNING: Database '$DatabaseName' exists in multiple instances:" -ForegroundColor Yellow
                $mIdx = 1
                foreach ($mdb in $selectedDB) {
                    Write-Host "    [$mIdx] $($mdb.properties.friendlyName) (Instance: $($mdb.properties.parentName))" -ForegroundColor White
                    $mIdx++
                }
                Write-Host ""
                Write-Host "  TIP: Use -InstanceName to target a specific instance." -ForegroundColor Cyan
                $mChoice = Read-Host '  Select instance (default: 1)'
                if ([string]::IsNullOrWhiteSpace($mChoice)) { $mChoice = "1" }
                $mSelectedIdx = [int]$mChoice - 1
                if ($mSelectedIdx -ge 0 -and $mSelectedIdx -lt $selectedDB.Count) {
                    $selectedDB = $selectedDB[$mSelectedIdx]
                } else {
                    $selectedDB = $selectedDB[0]
                }
            }
        }
        
        if (-not $selectedDB) {
            Write-Host "  ERROR: Database '$DatabaseName' not found in protected items." -ForegroundColor Red
            Write-Host "  Available databases:" -ForegroundColor Yellow
            foreach ($db in $vmProtectedDBs) {
                Write-Host "    - $($db.properties.friendlyName)" -ForegroundColor White
            }
            exit 1
        }
        
        if ($selectedDB -is [array]) { $selectedDB = $selectedDB[0] }
        Write-Host "  Selected database: $($selectedDB.properties.friendlyName)" -ForegroundColor Green
    } else {
        # Interactive selection
        if ($vmProtectedDBs.Count -eq 1) {
            $selectedDB = $vmProtectedDBs[0]
            Write-Host "  Auto-selected only available database: $($selectedDB.properties.friendlyName)" -ForegroundColor Green
        } else {
            Write-Host "  Select a database to restore:" -ForegroundColor Cyan
            $dbChoice = Read-Host "  Enter number (default: 1)"
            if ([string]::IsNullOrWhiteSpace($dbChoice)) { $dbChoice = "1" }
            $dbSelectedIdx = [int]$dbChoice - 1
            
            if ($dbSelectedIdx -ge 0 -and $dbSelectedIdx -lt $vmProtectedDBs.Count) {
                $selectedDB = $vmProtectedDBs[$dbSelectedIdx]
            } else {
                Write-Host "  Invalid selection." -ForegroundColor Red
                exit 1
            }
            Write-Host "  Selected database: $($selectedDB.properties.friendlyName)" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "ERROR: Failed to list protected items: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List protected items"
    exit 1
}

# ============================================================================
# STEP 2: EXTRACT CONTAINER AND PROTECTED ITEM DETAILS
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Resolving Protected Item Details" -ForegroundColor Yellow
Write-Host "-------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# The protected item ID is the full ARM resource ID
$protectedItemId = $selectedDB.id

# Extract containerName and protectedItemName from the ID
# Format: .../protectionContainers/{containerName}/protectedItems/{protectedItemName}
$containerName = $null
$protectedItemName = $null

if ($selectedDB.properties.containerName) {
    $containerName = $selectedDB.properties.containerName
} else {
    $idMatch = $protectedItemId -match "/protectionContainers/([^/]+)/"
    if ($idMatch) { $containerName = $Matches[1] }
}

$idMatch2 = $protectedItemId -match "/protectedItems/([^/]+)$"
if ($idMatch2) { $protectedItemName = $Matches[1] }

if ([string]::IsNullOrWhiteSpace($containerName) -or [string]::IsNullOrWhiteSpace($protectedItemName)) {
    Write-Host "  ERROR: Could not extract container/item names from protected item ID." -ForegroundColor Red
    Write-Host "  Protected Item ID: $protectedItemId" -ForegroundColor Gray
    exit 1
}

Write-Host "  Database:          $($selectedDB.properties.friendlyName)" -ForegroundColor Gray
Write-Host "  Container Name:    $containerName" -ForegroundColor Gray
Write-Host "  Protected Item:    $protectedItemName" -ForegroundColor Gray
Write-Host "  Source Resource ID:$($selectedDB.properties.sourceResourceId)" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# STEP 3: LIST RECOVERY POINTS
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Listing Recovery Points" -ForegroundColor Yellow
Write-Host "----------------------------------" -ForegroundColor Yellow
Write-Host ""

$recoveryPointsUri = "https://management.azure.com$protectedItemId/recoveryPoints?api-version=$apiVersionProtection"

$allRecoveryPoints = @()
$selectedRP = $null
$logTimeRanges = @()

try {
    Write-Host "Querying recovery points for '$($selectedDB.properties.friendlyName)'..." -ForegroundColor Cyan
    
    $currentUri = $recoveryPointsUri
    while ($currentUri) {
        $rpResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers
        
        if ($rpResponse.value) {
            $allRecoveryPoints += $rpResponse.value
        }
        
        $currentUri = $rpResponse.nextLink
        if ($currentUri) {
            Write-Host "  Fetching next page of recovery points..." -ForegroundColor Gray
        }
    }
    
    if ($allRecoveryPoints.Count -eq 0) {
        Write-Host "  ERROR: No recovery points found for '$($selectedDB.properties.friendlyName)'." -ForegroundColor Red
        Write-Host "  Make sure at least one backup has been completed." -ForegroundColor Yellow
        exit 1
    }
    
    # Separate recovery point types
    # Full/Differential: any RP that is NOT a DefaultRangeRecoveryPoint
    $fullRecoveryPoints = @($allRecoveryPoints | Where-Object {
        $_.name -ne "DefaultRangeRecoveryPoint"
    })
    
    # Log time ranges: DefaultRangeRecoveryPoint entries
    $logRecoveryPoints = @($allRecoveryPoints | Where-Object {
        $_.name -eq "DefaultRangeRecoveryPoint"
    })
    
    # Extract log time ranges
    $logTimeRanges = @()
    foreach ($lrp in $logRecoveryPoints) {
        if ($lrp.properties.timeRanges) {
            $logTimeRanges += $lrp.properties.timeRanges
        }
    }
    
    Write-Host "  Found $($allRecoveryPoints.Count) total recovery point(s)" -ForegroundColor Gray
    Write-Host "  Found $($fullRecoveryPoints.Count) Full/Differential recovery point(s)" -ForegroundColor Green
    if ($logTimeRanges.Count -gt 0) {
        Write-Host "  Found $($logTimeRanges.Count) Log time range(s)" -ForegroundColor Green
    }
    Write-Host ""
    
    # Display Full/Differential recovery points
    if ($fullRecoveryPoints.Count -gt 0) {
        Write-Host "  Full / Differential Recovery Points:" -ForegroundColor Cyan
        Write-Host "  ------------------------------------" -ForegroundColor Cyan
        
        $rpIdx = 1
        foreach ($rp in $fullRecoveryPoints) {
            $rpTime = $rp.properties.recoveryPointTimeInUTC
            $rpType = $rp.properties.type
            if (-not $rpType) { $rpType = "Full" }
            $rpId = $rp.name
            
            Write-Host "  [$rpIdx] ID: $rpId" -ForegroundColor White
            Write-Host "       Time (UTC): $rpTime" -ForegroundColor Gray
            Write-Host "       Type:       $rpType" -ForegroundColor Gray
            Write-Host ""
            $rpIdx++
        }
    }
    
    # Display Log time ranges for point-in-time restore
    if ($logTimeRanges.Count -gt 0) {
        Write-Host "  Log Restore Time Ranges (for Point-in-Time restore):" -ForegroundColor Cyan
        Write-Host "  ----------------------------------------------------" -ForegroundColor Cyan
        
        foreach ($tr in $logTimeRanges) {
            Write-Host "    From: $($tr.startTime)  To: $($tr.endTime)" -ForegroundColor White
        }
        Write-Host ""
    }
    
    # Select recovery point
    if (-not [string]::IsNullOrWhiteSpace($PointInTime)) {
        # Point-in-Time restore - validate the PointInTime is within a log range
        Write-Host "  Point-in-Time restore requested: $PointInTime" -ForegroundColor Cyan
        
        $pitValid = $false
        if ($logTimeRanges.Count -gt 0) {
            foreach ($tr in $logTimeRanges) {
                $startDt = [DateTime]::Parse($tr.startTime)
                $endDt = [DateTime]::Parse($tr.endTime)
                $pitDt = [DateTime]::Parse($PointInTime)
                
                if ($pitDt -ge $startDt -and $pitDt -le $endDt) {
                    $pitValid = $true
                    break
                }
            }
        }
        
        if (-not $pitValid -and $logTimeRanges.Count -gt 0) {
            Write-Host "  WARNING: PointInTime '$PointInTime' may not be within available log ranges." -ForegroundColor Yellow
            Write-Host "  The restore may fail if the point-in-time is outside the log chain." -ForegroundColor Yellow
            Write-Host ""
        }
        
        # For Point-in-Time restore, we need any recovery point ID (the API uses the timestamp, not the RP ID)
        # Use the DefaultRangeRecoveryPoint or the first available log RP
        if ($logRecoveryPoints.Count -gt 0) {
            $rpForPIT = $logRecoveryPoints[0]
            $RecoveryPointId = $rpForPIT.name
            Write-Host "  Using recovery point '$RecoveryPointId' for point-in-time restore." -ForegroundColor Gray
        } elseif ($fullRecoveryPoints.Count -gt 0) {
            $rpForPIT = $fullRecoveryPoints[0]
            $RecoveryPointId = $rpForPIT.name
            Write-Host "  Using recovery point '$RecoveryPointId' for point-in-time restore." -ForegroundColor Gray
        }
        
    } elseif (-not [string]::IsNullOrWhiteSpace($RecoveryPointId)) {
        # Recovery point was specified - validate it exists
        $selectedRP = $fullRecoveryPoints | Where-Object { $_.name -eq $RecoveryPointId }
        
        if (-not $selectedRP) {
            $selectedRP = $allRecoveryPoints | Where-Object { $_.name -eq $RecoveryPointId }
        }
        
        if (-not $selectedRP) {
            Write-Host "  WARNING: Recovery point '$RecoveryPointId' not found in listed points." -ForegroundColor Yellow
            Write-Host "  Proceeding with the specified recovery point ID." -ForegroundColor Yellow
        } else {
            if ($selectedRP -is [array]) { $selectedRP = $selectedRP[0] }
            Write-Host "  Using specified recovery point: $RecoveryPointId" -ForegroundColor Green
            Write-Host "    Time (UTC): $($selectedRP.properties.recoveryPointTimeInUTC)" -ForegroundColor Gray
        }
    } else {
        # Interactive selection
        if ($fullRecoveryPoints.Count -eq 0) {
            Write-Host "  ERROR: No Full/Differential recovery points available for selection." -ForegroundColor Red
            Write-Host "  For point-in-time restore, use the -PointInTime parameter." -ForegroundColor Yellow
            exit 1
        }
        
        Write-Host "  Select a recovery point to restore from:" -ForegroundColor Cyan
        $rpChoice = Read-Host "  Enter number (default: 1)"
        if ([string]::IsNullOrWhiteSpace($rpChoice)) { $rpChoice = "1" }
        $rpSelectedIdx = [int]$rpChoice - 1
        
        if ($rpSelectedIdx -ge 0 -and $rpSelectedIdx -lt $fullRecoveryPoints.Count) {
            $selectedRP = $fullRecoveryPoints[$rpSelectedIdx]
            $RecoveryPointId = $selectedRP.name
            Write-Host "  Selected recovery point: $RecoveryPointId" -ForegroundColor Green
            Write-Host "    Time (UTC): $($selectedRP.properties.recoveryPointTimeInUTC)" -ForegroundColor Gray
        } else {
            Write-Host "  Invalid selection." -ForegroundColor Red
            exit 1
        }
    }
    
    Write-Host ""
    
} catch {
    Write-Host "ERROR: Failed to list recovery points: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List recovery points"
    exit 1
}

# ============================================================================
# STEP 3B: FETCH RECOVERY POINT EXTENDED INFO (file paths)
# ============================================================================

$rpDataDirectoryPaths = @()

# Determine which RP to fetch file info from
$rpIdForFileInfo = $null
if (-not [string]::IsNullOrWhiteSpace($RecoveryPointId) -and $RecoveryPointId -ne "DefaultRangeRecoveryPoint") {
    $rpIdForFileInfo = $RecoveryPointId
} elseif ($fullRecoveryPoints.Count -gt 0) {
    # For PIT restores, use the latest Full RP to get file layout
    $rpIdForFileInfo = $fullRecoveryPoints[0].name
}

if ($rpIdForFileInfo) {
    Write-Host "  Fetching recovery point details for file path info..." -ForegroundColor Cyan
    try {
        $rpDetailUri = "https://management.azure.com$protectedItemId/recoveryPoints/$rpIdForFileInfo`?api-version=$apiVersionProtection"
        $rpDetailResponse = Invoke-RestMethod -Uri $rpDetailUri -Method GET -Headers $headers
        
        if ($rpDetailResponse.properties.extendedInfo.dataDirectoryPaths) {
            $rpDataDirectoryPaths = $rpDetailResponse.properties.extendedInfo.dataDirectoryPaths
            Write-Host "  Database file layout:" -ForegroundColor Gray
            foreach ($ddp in $rpDataDirectoryPaths) {
                Write-Host "    $($ddp.type): $($ddp.path) (Logical: $($ddp.logicalName))" -ForegroundColor Gray
            }
            Write-Host ""
        }
    } catch {
        Write-Host "  WARNING: Could not fetch RP extended info. Custom paths will use generic mappings." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 4: RESOLVE TARGET VM (for ALR and RestoreAsFiles)
# ============================================================================

$targetVirtualMachineId = $null
$targetContainerId = $null

if ($RestoreType -eq "ALR" -or $RestoreType -eq "RestoreAsFiles") {
    Write-Host ""
    Write-Host "STEP 4: Resolving Target VM" -ForegroundColor Yellow
    Write-Host "-----------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    # Construct the target VM ARM resource ID
    $targetVirtualMachineId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$TargetVMResourceGroup/providers/Microsoft.Compute/virtualMachines/$TargetVMName".ToLower()
    
    Write-Host "  Target VM ARM ID: $targetVirtualMachineId" -ForegroundColor Gray
    
    # Look up the target VM's container in the vault (it must be registered)
    Write-Host "  Looking up target VM container in vault..." -ForegroundColor Cyan
    
    # Try the standard container name format
    $targetContainerName = "VMAppContainer;Compute;$TargetVMResourceGroup;$TargetVMName"
    $targetContainerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$targetContainerName`?api-version=$apiVersion"
    
    try {
        $targetContainerResponse = Invoke-RestMethod -Uri $targetContainerUri -Method GET -Headers $headers
        
        if ($targetContainerResponse -and $targetContainerResponse.properties.registrationStatus -eq "Registered") {
            # Use lowercase containerId - the restore API requires lowercase
            $targetContainerId = $targetContainerResponse.id.ToLower()
            Write-Host "  Target VM is registered with vault." -ForegroundColor Green
            Write-Host "    Container Name: $($targetContainerResponse.name)" -ForegroundColor Gray
            Write-Host "    Container ID:   $targetContainerId" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: Target VM '$TargetVMName' may not be properly registered." -ForegroundColor Yellow
            Write-Host "  Registration Status: $($targetContainerResponse.properties.registrationStatus)" -ForegroundColor Yellow
            $targetContainerId = $targetContainerResponse.id.ToLower()
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        if ($statusCode -eq 404) {
            Write-Host "  ERROR: Target VM '$TargetVMName' is NOT registered with vault '$vaultName'." -ForegroundColor Red
            Write-Host "  The target VM must be registered to the same vault before performing ALR or RestoreAsFiles." -ForegroundColor Yellow
            Write-Host "  Use Register-SQLIaaSVM-ToVault.ps1 to register the target VM first." -ForegroundColor Yellow
            exit 1
        } else {
            Write-Host "  WARNING: Could not verify target VM registration (HTTP $statusCode)." -ForegroundColor Yellow
            Write-Host "  Constructing container ID manually..." -ForegroundColor Yellow
            $targetContainerId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$targetContainerName".ToLower()
        }
    }
    
    Write-Host ""
}

# ============================================================================
# STEP 5: BUILD RESTORE REQUEST BODY
# ============================================================================

Write-Host ""
Write-Host "STEP 5: Building Restore Request" -ForegroundColor Yellow
Write-Host "-----------------------------------" -ForegroundColor Yellow
Write-Host ""

$restoreRequestBody = $null
$isPointInTimeRestore = -not [string]::IsNullOrWhiteSpace($PointInTime)

# Determine overwrite option
$overwriteOption = "FailOnConflict"
if ($OverwriteExisting) {
    $overwriteOption = "Overwrite"
}

# Build alternateDirectoryPaths if custom data/log paths are provided
$alternateDirectoryPaths = @()
$useFallbackDirectory = $true

if (-not [string]::IsNullOrWhiteSpace($TargetDataPath) -or -not [string]::IsNullOrWhiteSpace($TargetLogPath)) {
    $useFallbackDirectory = $false
    
    if ($rpDataDirectoryPaths.Count -gt 0) {
        # Use the actual file info from the recovery point
        # Build target filenames from the TargetDatabaseName
        $targetDBShortName = $TargetDatabaseName
        if ($targetDBShortName -and $targetDBShortName.Contains("/")) {
            $targetDBShortName = $targetDBShortName.Split("/")[1]
        }
        
        Write-Host "  Using database file layout from recovery point:" -ForegroundColor Cyan
        foreach ($ddp in $rpDataDirectoryPaths) {
            $targetPath = $null
            $targetFileName = $null
            
            if ($ddp.type -eq "Data" -and -not [string]::IsNullOrWhiteSpace($TargetDataPath)) {
                # Get source file extension
                $srcExtension = [System.IO.Path]::GetExtension($ddp.path)
                if ([string]::IsNullOrWhiteSpace($srcExtension)) { $srcExtension = ".mdf" }
                $targetFileName = "$targetDBShortName$srcExtension"
                $targetPath = [System.IO.Path]::Combine($TargetDataPath, $targetFileName)
            } elseif ($ddp.type -eq "Log" -and -not [string]::IsNullOrWhiteSpace($TargetLogPath)) {
                $srcExtension = [System.IO.Path]::GetExtension($ddp.path)
                if ([string]::IsNullOrWhiteSpace($srcExtension)) { $srcExtension = ".ldf" }
                $targetFileName = "${targetDBShortName}_log$srcExtension"
                $targetPath = [System.IO.Path]::Combine($TargetLogPath, $targetFileName)
            }
            
            if ($targetPath) {
                $alternateDirectoryPaths += @{
                    mappingType       = $ddp.type
                    sourceLogicalName = $ddp.logicalName
                    sourcePath        = $ddp.path
                    targetPath        = $targetPath
                }
                Write-Host "    $($ddp.type): $($ddp.logicalName) ($($ddp.path)) -> $targetPath" -ForegroundColor Gray
            }
        }
    } else {
        # No RP file info available - use generic mappings with filenames
        $targetDBShortName = $TargetDatabaseName
        if ($targetDBShortName -and $targetDBShortName.Contains("/")) {
            $targetDBShortName = $targetDBShortName.Split("/")[1]
        }
        
        Write-Host "  Using generic file path mappings:" -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($TargetDataPath)) {
            $dataFilePath = [System.IO.Path]::Combine($TargetDataPath, "$targetDBShortName.mdf")
            $alternateDirectoryPaths += @{
                mappingType       = "Data"
                sourceLogicalName = ""
                sourcePath        = ""
                targetPath        = $dataFilePath
            }
            Write-Host "    Data -> $dataFilePath" -ForegroundColor Gray
        }
        
        if (-not [string]::IsNullOrWhiteSpace($TargetLogPath)) {
            $logFilePath = [System.IO.Path]::Combine($TargetLogPath, "${targetDBShortName}_log.ldf")
            $alternateDirectoryPaths += @{
                mappingType       = "Log"
                sourceLogicalName = ""
                sourcePath        = ""
                targetPath        = $logFilePath
            }
            Write-Host "    Log -> $logFilePath" -ForegroundColor Gray
        }
    }
    Write-Host ""
}

switch ($RestoreType) {
    "ALR" {
        Write-Host "  Building Alternate Location Restore (ALR) request..." -ForegroundColor Cyan
        
        $targetInfo = @{
            overwriteOption                 = $overwriteOption
            containerId                     = $targetContainerId
            databaseName                    = $TargetDatabaseName
        }
        
        if ($isPointInTimeRestore) {
            # Point-in-Time ALR
            $restoreRequest = @{
                objectType                     = "AzureWorkloadSQLPointInTimeRestoreRequest"
                recoveryType                   = "AlternateLocation"
                recoveryMode                   = "WorkloadRecovery"
                shouldUseAlternateTargetLocation = $true
                isNonRecoverable               = $false
                alternateDirectoryPaths        = $alternateDirectoryPaths
                isFallbackOnDefaultDirectoryEnabled = $useFallbackDirectory
                pointInTime                    = $PointInTime
                sourceResourceId               = $selectedDB.properties.sourceResourceId
                targetInfo                     = $targetInfo
                targetVirtualMachineId         = $targetVirtualMachineId
            }
            Write-Host "    Type:           Point-in-Time ALR" -ForegroundColor Gray
            Write-Host "    Point-in-Time:  $PointInTime" -ForegroundColor Gray
        } else {
            # Full recovery ALR
            $restoreRequest = @{
                objectType                     = "AzureWorkloadSQLRestoreRequest"
                recoveryType                   = "AlternateLocation"
                recoveryMode                   = "WorkloadRecovery"
                shouldUseAlternateTargetLocation = $true
                isNonRecoverable               = $false
                alternateDirectoryPaths        = $alternateDirectoryPaths
                isFallbackOnDefaultDirectoryEnabled = $useFallbackDirectory
                sourceResourceId               = $selectedDB.properties.sourceResourceId
                targetInfo                     = $targetInfo
                targetVirtualMachineId         = $targetVirtualMachineId
            }
            Write-Host "    Type:           Full Recovery ALR" -ForegroundColor Gray
        }
        
        Write-Host "    Recovery Type:  AlternateLocation" -ForegroundColor Gray
        Write-Host "    Target VM:      $TargetVMName" -ForegroundColor Gray
        Write-Host "    Target DB:      $TargetDatabaseName" -ForegroundColor Gray
        Write-Host "    Overwrite:      $overwriteOption" -ForegroundColor Gray
    }
    
    "RestoreAsFiles" {
        Write-Host "  Building Restore as Files request..." -ForegroundColor Cyan
        
        $targetInfo = @{
            overwriteOption                 = $overwriteOption
            containerId                     = $targetContainerId
            targetDirectoryForFileRestore   = $TargetFilePath
        }
        
        if ($isPointInTimeRestore) {
            # Point-in-Time Restore as Files
            $restoreRequest = @{
                objectType                     = "AzureWorkloadSQLPointInTimeRestoreRequest"
                recoveryType                   = "AlternateLocation"
                recoveryMode                   = "FileRecovery"
                shouldUseAlternateTargetLocation = $false
                isNonRecoverable               = $false
                pointInTime                    = $PointInTime
                sourceResourceId               = $selectedDB.properties.sourceResourceId
                targetInfo                     = $targetInfo
                targetVirtualMachineId         = $targetVirtualMachineId
            }
            Write-Host "    Type:           Point-in-Time Restore as Files" -ForegroundColor Gray
            Write-Host "    Point-in-Time:  $PointInTime" -ForegroundColor Gray
        } else {
            # Full Restore as Files
            $restoreRequest = @{
                objectType                     = "AzureWorkloadSQLRestoreRequest"
                recoveryType                   = "AlternateLocation"
                recoveryMode                   = "FileRecovery"
                shouldUseAlternateTargetLocation = $false
                isNonRecoverable               = $false
                sourceResourceId               = $selectedDB.properties.sourceResourceId
                targetInfo                     = $targetInfo
                targetVirtualMachineId         = $targetVirtualMachineId
            }
            Write-Host "    Type:           Full Restore as Files" -ForegroundColor Gray
        }
        
        Write-Host "    Recovery Type:  AlternateLocation (FileRecovery)" -ForegroundColor Gray
        Write-Host "    Target VM:      $TargetVMName" -ForegroundColor Gray
        Write-Host "    Target Path:    $TargetFilePath" -ForegroundColor Gray
        Write-Host "    Overwrite:      $overwriteOption" -ForegroundColor Gray
    }
}

$restoreRequestBody = @{
    properties = $restoreRequest
} | ConvertTo-Json -Depth 10

Write-Host ""
Write-Host "  Restore request body constructed successfully." -ForegroundColor Green
Write-Host ""

# ============================================================================
# STEP 6: TRIGGER RESTORE
# ============================================================================

Write-Host ""
Write-Host "STEP 6: Triggering Restore Operation" -ForegroundColor Yellow
Write-Host "---------------------------------------" -ForegroundColor Yellow
Write-Host ""

$restoreUri = "https://management.azure.com$protectedItemId/recoveryPoints/$RecoveryPointId/restore?api-version=$apiVersionProtection"

Write-Host "  Restore URI: $restoreUri" -ForegroundColor Gray
Write-Host ""
Write-Host "  Submitting restore request..." -ForegroundColor Cyan

$asyncOperationUrl = $null
$locationUrl = $null

try {
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $restoreRequestBody -UseBasicParsing
    $statusCode = $restoreResponse.StatusCode
    
    if ($statusCode -eq 202) {
        Write-Host "  Restore operation accepted (202 Accepted)" -ForegroundColor Green
        $asyncOperationUrl = $restoreResponse.Headers["Azure-AsyncOperation"]
        $locationUrl = $restoreResponse.Headers["Location"]
        
        if ($asyncOperationUrl) {
            Write-Host "  Async Operation URL: $asyncOperationUrl" -ForegroundColor Gray
        }
        if ($locationUrl) {
            Write-Host "  Location URL: $locationUrl" -ForegroundColor Gray
        }
    } elseif ($statusCode -eq 200) {
        Write-Host "  Restore completed immediately (200 OK)" -ForegroundColor Green
    } else {
        Write-Host "  Unexpected status code: $statusCode" -ForegroundColor Yellow
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Restore operation accepted (202 Accepted)" -ForegroundColor Green
        try {
            $asyncOperationUrl = $_.Exception.Response.Headers | Where-Object { $_.Key -eq "Azure-AsyncOperation" } | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
            $locationUrl = $_.Exception.Response.Headers.Location
        } catch {
            Write-Host "  Could not extract tracking headers." -ForegroundColor Yellow
        }
    } else {
        Write-Host ""
        Write-Host "  ERROR: Failed to trigger restore operation." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "Trigger Restore"
        Write-Host ""
        Write-Host "  Possible causes:" -ForegroundColor Yellow
        Write-Host "    1. Recovery point ID is invalid or expired" -ForegroundColor White
        Write-Host "    2. Insufficient permissions on the vault" -ForegroundColor White
        Write-Host "    3. Another backup/restore job is running on this database" -ForegroundColor White
        Write-Host "    4. Target VM is not properly registered (for ALR/RestoreAsFiles)" -ForegroundColor White
        Write-Host "    5. Point-in-time value is outside the log chain" -ForegroundColor White
        Write-Host ""
        exit 1
    }
}

# ============================================================================
# STEP 7: TRACK RESTORE JOB STATUS
# ============================================================================

Write-Host ""
Write-Host "STEP 7: Tracking Restore Job" -ForegroundColor Yellow
Write-Host "------------------------------" -ForegroundColor Yellow
Write-Host ""

if ($asyncOperationUrl -or $locationUrl) {
    $jobResult = Wait-ForRestoreJob -AsyncUrl $asyncOperationUrl -LocationUrl $locationUrl -Headers $headers -MaxRetries 60 -DelaySeconds 10 -OperationName "Restore"
    
    if ($jobResult -and $jobResult.status -eq "Succeeded") {
        Write-Host ""
        Write-Host "  ==========================================================" -ForegroundColor Green
        Write-Host "    RESTORE COMPLETED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "  ==========================================================" -ForegroundColor Green
    } elseif ($jobResult -and $jobResult.status -eq "Failed") {
        Write-Host ""
        Write-Host "  ==========================================================" -ForegroundColor Red
        Write-Host "    RESTORE FAILED" -ForegroundColor Red
        Write-Host "  ==========================================================" -ForegroundColor Red
    } else {
        Write-Host ""
        Write-Host "  Restore job submitted. Check Azure Portal for final status." -ForegroundColor Yellow
    }
} else {
    Write-Host "  No async tracking URL available." -ForegroundColor Yellow
    Write-Host "  Check Azure Portal > Recovery Services Vault > Backup Jobs for status." -ForegroundColor Yellow
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Restore Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Source Database:     $($selectedDB.properties.friendlyName)" -ForegroundColor White
Write-Host "  Source VM:           $vmName" -ForegroundColor White
Write-Host "  Restore Type:        $RestoreType" -ForegroundColor White
Write-Host "  Recovery Point ID:   $RecoveryPointId" -ForegroundColor White
if ($isPointInTimeRestore) {
    Write-Host "  Point-in-Time:       $PointInTime" -ForegroundColor White
}

switch ($RestoreType) {
    "ALR" {
        Write-Host "  Target VM:           $TargetVMName" -ForegroundColor White
        Write-Host "  Target Database:     $TargetDatabaseName" -ForegroundColor White
    }
    "RestoreAsFiles" {
        Write-Host "  Target VM:           $TargetVMName" -ForegroundColor White
        Write-Host "  Target File Path:    $TargetFilePath" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "  To monitor the restore job:" -ForegroundColor Gray
Write-Host "    Azure Portal > Recovery Services Vault > '$vaultName' > Backup Jobs" -ForegroundColor Gray
Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

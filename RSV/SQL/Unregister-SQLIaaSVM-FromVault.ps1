<#
.SYNOPSIS
    Stops protection (with retain data) for SQL databases on an Azure IaaS VM
    and optionally unregisters the VM from a Recovery Services Vault using REST API.

.DESCRIPTION
    This script manages backup protection for SQL Server databases on Azure IaaS VMs
    and supports full container unregistration while PRESERVING recovery points.

    Two operational modes:

    MODE 1: Stop Protection with Retain Data (default, no -Unregister)
    - Lists all protected SQL databases on a VM
    - Stops protection while retaining existing recovery points
    - Optionally prompts to unregister after all DBs are stopped

    MODE 2: Full Unregistration (-Unregister)
    - Stops protection with retain data for ALL active databases
    - Waits for operations to propagate
    - Unregisters the VM container from the vault
    - Recovery points are preserved (stop-with-retain keeps them)
    - All databases on the VM are processed (cannot target individual DBs)
    - The -StopAll behavior is implied; -DatabaseName is ignored

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on the Recovery Services Vault
    - SQL databases must be in Protected/IRPending/ProtectionStopped state

.PARAMETER VaultSubscriptionId
    The Subscription ID where the Recovery Services Vault is located.

.PARAMETER VaultResourceGroup
    The Resource Group name of the Recovery Services Vault.

.PARAMETER VaultName
    The name of the Recovery Services Vault.

.PARAMETER VMResourceGroup
    The Resource Group name of the SQL Server VM.

.PARAMETER VMName
    The name of the Azure VM hosting SQL Server.

.PARAMETER InstanceName
    The name of the SQL instance (e.g. MSSQLSERVER, SQLEXPRESS).
    When specified, filters protected databases to only those belonging
    to this instance. Useful when a VM has multiple SQL instances.
    Ignored when -Unregister is specified (all instances are processed).

.PARAMETER DatabaseName
    The name of a specific SQL database to stop protection for.
    Only used when -Unregister is NOT specified.
    If omitted, ALL protected databases on the VM will be listed and
    you can choose to stop protection for all or select one.
    Ignored when -Unregister is specified (all DBs must be processed).

.PARAMETER Unregister
    When specified, stops protection for ALL databases with retain data,
    then unregisters the VM container from the vault.
    Recovery points are preserved through the stop-with-retain mechanism.

.PARAMETER StopAll
    When specified without -Unregister, stops protection for ALL protected SQL databases
    on the VM without prompting for individual selection.
    When -Unregister is specified, -StopAll is implied and this switch is ignored.

.EXAMPLE
    # Stop protection for a specific database (retain data, no unregister)
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -DatabaseName "SalesDB"

.EXAMPLE
    # Unregister the VM (stop protection + unregister, preserves recovery points)
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -Unregister

.EXAMPLE
    # Stop protection for ALL databases without unregistering
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -StopAll

.EXAMPLE
    # Interactive mode - lists DBs, prompts for selection, then optionally unregisters
    .\Unregister-SQLIaaSVM-FromVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01"

.NOTES
    Author: Azure Backup Script Generator
    Date: March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister
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

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the SQL Server VM.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Azure VM hosting SQL Server.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SQL instance to target (e.g. MSSQLSERVER). Filters databases to this instance. Ignored when -Unregister is specified.")]
    [string]$InstanceName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of a specific SQL database to stop protection for. Ignored when -Unregister is specified.")]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Unregister the VM container after stopping protection. Processes ALL databases. Recovery points are preserved.")]
    [switch]$Unregister,

    [Parameter(Mandatory = $false, HelpMessage = "Stop protection for ALL protected SQL databases on the VM without prompting. Implied when -Unregister is used.")]
    [switch]$StopAll,

    [Parameter(Mandatory = $false, HelpMessage = "Skip confirmation prompts. Use this for automation/scripting.")]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false, HelpMessage = "Pre-fetched bearer token. When provided, skips authentication. Used by bulk wrapper scripts.")]
    [string]$Token
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"

# ============================================================================
# HELPER FUNCTION: Poll async operation
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
    } catch { }
}

# ============================================================================
# HELPER FUNCTION: Stop protection with retain data for a single DB
# ============================================================================

function Submit-StopProtectionRequest {
    param(
        [object]$ProtectedItem,
        [hashtable]$Headers,
        [string]$ApiVersion
    )

    $dbFriendlyName = $ProtectedItem.properties.friendlyName
    $currentState = $ProtectedItem.properties.protectionState

    # Skip if already stopped
    if ($currentState -eq "ProtectionStopped") {
        return @{ Name = $dbFriendlyName; Status = "Skipped"; TrackingUrl = $null }
    }

    # Construct the PUT URI from the protected item ID
    $itemUri = "https://management.azure.com$($ProtectedItem.id)?api-version=$ApiVersion"

    # Request body: set protectionState to ProtectionStopped with empty policyId
    $stopBody = @{
        properties = @{
            protectedItemType = "AzureVmWorkloadSQLDatabase"
            protectionState   = "ProtectionStopped"
            sourceResourceId  = $ProtectedItem.properties.sourceResourceId
            policyId          = ""
        }
    } | ConvertTo-Json -Depth 10

    try {
        $stopResponse = Invoke-WebRequest -Uri $itemUri -Method PUT -Headers $Headers -Body $stopBody -UseBasicParsing
        $statusCode = $stopResponse.StatusCode

        if ($statusCode -eq 200) {
            return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
        } elseif ($statusCode -eq 202) {
            $asyncUrl = $stopResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $stopResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
            return @{ Name = $dbFriendlyName; Status = "InProgress"; TrackingUrl = $trackingUrl }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            try {
                $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
                $locationUrl = $_.Exception.Response.Headers["Location"]
                $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                return @{ Name = $dbFriendlyName; Status = "InProgress"; TrackingUrl = $trackingUrl }
            } catch {
                return @{ Name = $dbFriendlyName; Status = "InProgress"; TrackingUrl = $null }
            }
        } else {
            Write-Host "    ERROR: Failed to submit stop request for '$dbFriendlyName'" -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Stop Protection"
            return @{ Name = $dbFriendlyName; Status = "Failed"; TrackingUrl = $null }
        }
    }

    return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
}

function Stop-SQLDatabasesParallel {
    param(
        [array]$ProtectedItems,
        [hashtable]$Headers,
        [string]$ApiVersion,
        [int]$MaxPollRetries = 20,
        [int]$PollDelaySeconds = 8
    )

    $stopSuccessCount = 0
    $stopFailCount = 0
    $stopSkipCount = 0
    $pendingOps = @()

    # Phase 1: Fire all stop requests without waiting
    Write-Host "  Phase 1: Submitting stop requests for $($ProtectedItems.Count) database(s)..." -ForegroundColor Cyan
    Write-Host ""

    foreach ($db in $ProtectedItems) {
        $currentState = $db.properties.protectionState
        if ($currentState -eq "ProtectionStopped") {
            Write-Host "    SKIPPED: '$($db.properties.friendlyName)' - already stopped" -ForegroundColor Yellow
            $stopSkipCount++
            continue
        }

        Write-Host "    Submitting stop for '$($db.properties.friendlyName)'..." -ForegroundColor Cyan
        $result = Submit-StopProtectionRequest -ProtectedItem $db -Headers $Headers -ApiVersion $ApiVersion

        if ($result.Status -eq "Succeeded") {
            Write-Host "    SUCCESS: '$($result.Name)' stopped immediately (200 OK)" -ForegroundColor Green
            $stopSuccessCount++
        } elseif ($result.Status -eq "InProgress") {
            Write-Host "    ACCEPTED: '$($result.Name)' (202) - will poll" -ForegroundColor Green
            $pendingOps += $result
        } elseif ($result.Status -eq "Skipped") {
            $stopSkipCount++
        } else {
            $stopFailCount++
        }
    }

    # Phase 2: Poll all pending operations together
    if ($pendingOps.Count -gt 0) {
        Write-Host ""
        Write-Host "  Phase 2: Polling $($pendingOps.Count) pending operation(s)..." -ForegroundColor Cyan

        $retryCount = 0
        while ($pendingOps.Count -gt 0 -and $retryCount -lt $MaxPollRetries) {
            Start-Sleep -Seconds $PollDelaySeconds
            $retryCount++

            $stillPending = @()

            foreach ($op in $pendingOps) {
                if ([string]::IsNullOrWhiteSpace($op.TrackingUrl)) {
                    # No tracking URL - assume success after wait
                    Write-Host "    SUCCESS: '$($op.Name)' (no tracking URL, assumed complete)" -ForegroundColor Green
                    $stopSuccessCount++
                    continue
                }

                try {
                    $opResponse = Invoke-RestMethod -Uri $op.TrackingUrl -Method GET -Headers $Headers
                    $opStatus = if ($opResponse.status) { $opResponse.status } else { $null }

                    if ($opStatus -eq "Succeeded") {
                        Write-Host "    SUCCESS: '$($op.Name)' completed" -ForegroundColor Green
                        $stopSuccessCount++
                    } elseif ($opStatus -eq "Failed") {
                        Write-Host "    FAILED: '$($op.Name)'" -ForegroundColor Red
                        $stopFailCount++
                    } else {
                        $stillPending += $op
                    }
                } catch {
                    $innerCode = $_.Exception.Response.StatusCode.value__
                    if ($innerCode -eq 200 -or $innerCode -eq 204) {
                        Write-Host "    SUCCESS: '$($op.Name)' completed" -ForegroundColor Green
                        $stopSuccessCount++
                    } else {
                        $stillPending += $op
                    }
                }
            }

            $pendingOps = $stillPending

            if ($pendingOps.Count -gt 0) {
                $names = ($pendingOps | ForEach-Object { $_.Name }) -join ", "
                Write-Host "    Waiting... ($retryCount/$MaxPollRetries) - pending: $names" -ForegroundColor Yellow
            }
        }

        # Anything still pending after max retries
        foreach ($op in $pendingOps) {
            Write-Host "    WARNING: '$($op.Name)' timed out. Check Azure Portal." -ForegroundColor Yellow
            $stopFailCount++
        }
    }

    return @{
        Succeeded = $stopSuccessCount
        Failed    = $stopFailCount
        Skipped   = $stopSkipCount
    }
}

# ============================================================================
# MAP PARAMETERS
# ============================================================================

$vaultSubscriptionId = $VaultSubscriptionId
$vaultResourceGroup  = $VaultResourceGroup
$vaultName           = $VaultName
$vmResourceGroup     = $VMResourceGroup
$vmName              = $VMName

# ============================================================================
# DISPLAY CONFIGURATION SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server on Azure IaaS VM - Stop Protection & Unregister" -ForegroundColor Cyan
Write-Host "  (Using Azure Backup REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "  Subscription:        $vaultSubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Resource Group:$vaultResourceGroup" -ForegroundColor Gray
Write-Host "  Vault Name:          $vaultName" -ForegroundColor Gray
Write-Host "  VM Resource Group:   $vmResourceGroup" -ForegroundColor Gray
Write-Host "  VM Name:             $vmName" -ForegroundColor Gray

if ($Unregister) {
    Write-Host "  Mode:                UNREGISTER (stop protection + unregister)" -ForegroundColor Magenta
    Write-Host "  Target Database:     ALL (required for unregistration)" -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        Write-Host "  NOTE: -DatabaseName '$DatabaseName' is ignored when -Unregister is specified" -ForegroundColor Yellow
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        Write-Host "  Target Database:     $DatabaseName" -ForegroundColor Gray
    } elseif ($StopAll) {
        Write-Host "  Target Database:     ALL (stop all protected DBs)" -ForegroundColor Yellow
    } else {
        Write-Host "  Target Database:     (will be selected interactively)" -ForegroundColor Gray
    }
}
Write-Host "  Unregister VM:       $(if ($Unregister) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null

# Use pre-fetched token if provided (e.g. from bulk wrapper)
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $token = $Token
    Write-Host "  Using pre-fetched token (passed via -Token parameter)" -ForegroundColor Green
} else {
try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

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
        Write-Host "  Run 'Connect-AzAccount' or 'az login' first." -ForegroundColor Yellow
        exit 1
    }
}
} # end else (no pre-fetched token)

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# STEP 1: LIST ALL PROTECTED SQL DATABASES ON THE VM
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Listing Protected SQL Databases on VM" -ForegroundColor Yellow
Write-Host "------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"

$allProtectedItems = @()
$vmProtectedDBs = @()
$containerName = $null

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

    # Filter to items belonging to our VM (exact match on container name pattern)
    # Container name format: VMAppContainer;Compute;{resourceGroup};{vmName}
    # We match on the exact ";{vmName}" suffix or the full container pattern to avoid
    # matching VMs with similar names (e.g., sql-vm matching sql-vm-01)
    $expectedContainerSuffix = ";$vmName".ToLower()
    $expectedContainerFull = "VMAppContainer;Compute;$vmResourceGroup;$vmName".ToLower()
    $vmProtectedDBs = $allProtectedItems | Where-Object {
        $cn = if ($_.properties.containerName) { $_.properties.containerName.ToLower() } else { "" }
        $itemId = if ($_.id) { $_.id.ToLower() } else { "" }
        # Match: container name ends with ;vmName (exact VM) OR full container pattern in ID
        $cn.EndsWith($expectedContainerSuffix) -or
        $cn -ieq $expectedContainerFull -or
        $itemId.Contains($expectedContainerFull)
    }

    if ($vmProtectedDBs.Count -gt 0) {
        # Extract container name from the first item
        if ($vmProtectedDBs[0].properties.containerName) {
            $containerName = $vmProtectedDBs[0].properties.containerName
        } else {
            # Parse from ID
            $idMatch = $vmProtectedDBs[0].id -match "/protectionContainers/([^/]+)/"
            if ($idMatch) { $containerName = $Matches[1] }
        }

        Write-Host "  Found $($vmProtectedDBs.Count) protected SQL database(s) on VM '$vmName'" -ForegroundColor Green
        Write-Host "  Container: $containerName" -ForegroundColor Gray
        Write-Host ""

        # Filter by -InstanceName if provided (only in non-Unregister mode)
        if (-not [string]::IsNullOrWhiteSpace($InstanceName) -and -not $Unregister) {
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

        # Display protected databases grouped by instance
        $instanceGroupsDisplay = $vmProtectedDBs | Group-Object { $_.properties.parentName }
        if ($instanceGroupsDisplay.Count -gt 1) {
            foreach ($group in $instanceGroupsDisplay) {
                Write-Host "  [$($group.Name)]" -ForegroundColor Yellow
                $dbIdx = 1
                foreach ($db in $group.Group) {
                    $state = $db.properties.protectionState
                    $policy = $db.properties.policyName
                    $lastBackup = $db.properties.lastBackupTime
                    $stateColor = if ($state -eq "ProtectionStopped") { "Yellow" } else { "White" }

                    Write-Host "    [$dbIdx] $($db.properties.friendlyName)" -ForegroundColor $stateColor
                    Write-Host "         State:          $state" -ForegroundColor Gray
                    Write-Host "         Policy:         $policy" -ForegroundColor Gray
                    Write-Host "         Last Backup:    $lastBackup" -ForegroundColor Gray
                    Write-Host ""
                    $dbIdx++
                }
            }
        } else {
            $dbIdx = 1
            foreach ($db in $vmProtectedDBs) {
                $state = $db.properties.protectionState
                $policy = $db.properties.policyName
                $lastBackup = $db.properties.lastBackupTime
                $stateColor = if ($state -eq "ProtectionStopped") { "Yellow" } else { "White" }

                Write-Host "  [$dbIdx] $($db.properties.friendlyName)" -ForegroundColor $stateColor
                Write-Host "       Instance:       $($db.properties.parentName)" -ForegroundColor Gray
                Write-Host "       State:          $state" -ForegroundColor Gray
                Write-Host "       Policy:         $policy" -ForegroundColor Gray
                Write-Host "       Last Backup:    $lastBackup" -ForegroundColor Gray
                Write-Host ""
                $dbIdx++
            }
        }
    } else {
        Write-Host "  No protected SQL databases found on VM '$vmName'." -ForegroundColor Yellow

        if ($Unregister) {
            Write-Host "  Proceeding to unregister..." -ForegroundColor Cyan
        } else {
            Write-Host "  Nothing to do." -ForegroundColor Yellow
            Write-Host ""
        }
    }
} catch {
    Write-Host "ERROR: Failed to list protected items: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List protected items"
    exit 1
}

# ============================================================================
# BRANCH: When -Unregister is specified
#   Step 2: Stop protection with retain data for ALL active DBs
#   Step 3: Wait 30s, then unregister the container
# ============================================================================

if ($Unregister) {
    # ------------------------------------------------------------------
    # Resolve container name if not found from protected items
    # ------------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($containerName)) {
        Write-Host "  Looking up container name for VM '$vmName'..." -ForegroundColor Cyan

        $possibleNames = @(
            "VMAppContainer;Compute;$vmResourceGroup;$vmName"
        )

        foreach ($name in $possibleNames) {
            $checkUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$name`?api-version=$apiVersion"

            try {
                $checkResponse = Invoke-RestMethod -Uri $checkUri -Method GET -Headers $headers
                if ($checkResponse) {
                    $containerName = $checkResponse.name
                    Write-Host "  Found container: $containerName" -ForegroundColor Green
                    break
                }
            } catch { }
        }

        if ([string]::IsNullOrWhiteSpace($containerName)) {
            Write-Host "  ERROR: Could not find registered container for VM '$vmName'." -ForegroundColor Red
            Write-Host "  The VM may not be registered with the vault." -ForegroundColor Yellow
            exit 1
        }
    }

    # ------------------------------------------------------------------
    # Re-query protected items using the discovered container name
    # (initial query may have missed items due to VM name case mismatch)
    # ------------------------------------------------------------------
    if ($vmProtectedDBs.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($containerName)) {
        Write-Host "  Re-querying protected items using container name..." -ForegroundColor Cyan
        try {
            $reQueryUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"
            $allItems2 = @()
            $curUri = $reQueryUri
            while ($curUri) {
                $resp2 = Invoke-RestMethod -Uri $curUri -Method GET -Headers $headers
                if ($resp2.value) { $allItems2 += $resp2.value }
                $curUri = $resp2.nextLink
            }
            $containerNameLower = $containerName.ToLower()
            $vmProtectedDBs = $allItems2 | Where-Object {
                ($_.properties.containerName -and $_.properties.containerName.ToLower().Contains($containerNameLower)) -or
                ($_.id -and $_.id.ToLower().Contains($containerNameLower))
            }
            if ($vmProtectedDBs.Count -gt 0) {
                Write-Host "  Found $($vmProtectedDBs.Count) protected database(s) via container name match." -ForegroundColor Green
                Write-Host ""
                foreach ($db in $vmProtectedDBs) {
                    Write-Host "    - $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
                }
                Write-Host ""
            }
        } catch {
            Write-Host "  WARNING: Re-query failed. Proceeding with empty item list." -ForegroundColor Yellow
        }
    }

    # ==================================================================
    # STEP 2: Stop Protection with Retain Data for ALL Active DBs
    # ==================================================================
    Write-Host ""
    Write-Host "STEP 2: Stopping Protection (Retain Data) for All Databases" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    # Count active DBs that need stopping
    $activeDBsForStop = $vmProtectedDBs | Where-Object { $_.properties.protectionState -ne "ProtectionStopped" }
    $alreadyStoppedCount = $vmProtectedDBs.Count - $activeDBsForStop.Count

    if ($activeDBsForStop.Count -gt 0 -and -not $SkipConfirmation) {
        Write-Host "  The following $($activeDBsForStop.Count) database(s) will have protection STOPPED (data retained):" -ForegroundColor Magenta
        foreach ($adb in $activeDBsForStop) {
            Write-Host "    - $($adb.properties.friendlyName) (State: $($adb.properties.protectionState))" -ForegroundColor White
        }
        if ($alreadyStoppedCount -gt 0) {
            Write-Host "  ($alreadyStoppedCount database(s) already stopped - will be skipped)" -ForegroundColor Gray
        }
        Write-Host ""
        $confirmStop = Read-Host '  Proceed with stop protection? [Y/N, default: Y]'
        if ($confirmStop -ieq 'N') {
            Write-Host "  Aborted by user." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    $stopSuccessCount = 0
    $stopFailCount = 0
    $stopSkipCount = 0

    if ($vmProtectedDBs.Count -eq 0) {
        Write-Host "  No protected items to stop. Proceeding to container unregistration." -ForegroundColor Yellow
    } else {
        $stopResult = Stop-SQLDatabasesParallel -ProtectedItems $vmProtectedDBs -Headers $headers -ApiVersion $apiVersion
        $stopSuccessCount = $stopResult.Succeeded
        $stopFailCount = $stopResult.Failed
        $stopSkipCount = $stopResult.Skipped

        Write-Host ""
        Write-Host "  Stop Protection Summary: $stopSuccessCount stopped, $stopSkipCount already stopped, $stopFailCount failed" -ForegroundColor Cyan

        if ($stopFailCount -gt 0 -and $stopSuccessCount -eq 0 -and $stopSkipCount -eq 0) {
            Write-Host ""
            Write-Host "  ERROR: All stop operations failed. Cannot proceed with unregistration." -ForegroundColor Red
            exit 1
        }
    }

    # ==================================================================
    # STEP 3: Wait 30s, then Unregister Container
    # ==================================================================
    Write-Host ""
    Write-Host "STEP 3: Unregistering VM Container from Vault" -ForegroundColor Yellow
    Write-Host "-----------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    if (-not $SkipConfirmation) {
        Write-Host "  Container '$containerName' will be UNREGISTERED from vault '$vaultName'." -ForegroundColor Magenta
        Write-Host "  Recovery points will be retained in the vault." -ForegroundColor Gray
        Write-Host ""
        $confirmUnreg = Read-Host '  Proceed with unregistration? [Y/N, default: Y]'
        if ($confirmUnreg -ieq 'N') {
            Write-Host "  Aborted by user. Protection was stopped but container remains registered." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    Write-Host "  Waiting 30 seconds for stop operations to propagate..." -ForegroundColor Cyan
    Start-Sleep -Seconds 30

    Write-Host "  Unregistering container '$containerName'..." -ForegroundColor Cyan

    $unregisterUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"
    $unregisterSucceeded = $false

    try {
        $unregisterResponse = Invoke-WebRequest -Uri $unregisterUri -Method DELETE -Headers $headers -UseBasicParsing
        $statusCode = $unregisterResponse.StatusCode

        if ($statusCode -eq 200 -or $statusCode -eq 204) {
            Write-Host "  Container unregistered successfully." -ForegroundColor Green
            $unregisterSucceeded = $true
        } elseif ($statusCode -eq 202) {
            Write-Host "  Unregistration accepted (202). Tracking..." -ForegroundColor Green
            $asyncUrl = $unregisterResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $unregisterResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

            $result = Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "Container Unregistration"
            $unregisterSucceeded = $result
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "  Unregistration accepted (202). Waiting..." -ForegroundColor Green
            Start-Sleep -Seconds 15
            $unregisterSucceeded = $true
        } elseif ($statusCode -eq 204) {
            Write-Host "  Container was already unregistered (204)." -ForegroundColor Green
            $unregisterSucceeded = $true
        } else {
            Write-Host ""
            Write-Host "  ERROR: Failed to unregister container." -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Unregister Container"

            # Check for specific error codes
            $errorMessage = $_.ErrorDetails.Message
            if ($errorMessage -like "*BMSUserErrorContainerHasDatasources*" -or $errorMessage -like "*delete data*") {
                Write-Host ""
                Write-Host "  REASON: The vault still has active datasource references preventing unregistration." -ForegroundColor Yellow
                Write-Host "  Some stop-protection operations may not have fully propagated yet." -ForegroundColor Yellow
                Write-Host "  Wait a few minutes and retry, or check the Azure Portal." -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""

    # ==================================================================
    # FINAL SUMMARY (Unregister flow)
    # ==================================================================
    Write-Host ""
    if ($unregisterSucceeded) {
        Write-Host "  ==========================================================" -ForegroundColor Green
        Write-Host "    VM UNREGISTERED SUCCESSFULLY!" -ForegroundColor Green
        Write-Host "  ==========================================================" -ForegroundColor Green
    } else {
        Write-Host "  ==========================================================" -ForegroundColor Yellow
        Write-Host "    UNREGISTRATION MAY NOT HAVE COMPLETED" -ForegroundColor Yellow
        Write-Host "  ==========================================================" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Summary:" -ForegroundColor Yellow
    Write-Host "    Container:              $containerName" -ForegroundColor White
    Write-Host "    DBs stopped:            $stopSuccessCount" -ForegroundColor White
    Write-Host "    DBs already stopped:    $stopSkipCount" -ForegroundColor White
    Write-Host "    DBs failed to stop:     $stopFailCount" -ForegroundColor White
    Write-Host "    Container unregistered: $(if ($unregisterSucceeded) { 'Yes' } else { 'Check Portal' })" -ForegroundColor White
    Write-Host ""
    Write-Host "  Recovery points are PRESERVED (stop-with-retain keeps them intact)." -ForegroundColor Green
    Write-Host ""
    Write-Host "Script completed." -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ============================================================================
# NON-UNREGISTER FLOW: STEP 2 - Stop Protection with Retain Data
# ============================================================================

$successCount = 0
$failCount = 0
$dbsToStop = @()

if ($vmProtectedDBs.Count -gt 0) {
    Write-Host ""
    Write-Host "STEP 2: Stopping Protection (Retain Data)" -ForegroundColor Yellow
    Write-Host "--------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    if (-not [string]::IsNullOrWhiteSpace($DatabaseName)) {
        # Specific database provided
        if (-not [string]::IsNullOrWhiteSpace($InstanceName)) {
            # Filter by both DatabaseName and InstanceName
            $targetDB = $vmProtectedDBs | Where-Object {
                $_.properties.friendlyName -ieq $DatabaseName -and $_.properties.parentName -ieq $InstanceName
            }
        } else {
            $targetDB = $vmProtectedDBs | Where-Object {
                $_.properties.friendlyName -eq $DatabaseName -or
                $_.properties.friendlyName -ieq $DatabaseName
            }
            
            # If multiple matches (same DB name in different instances), warn and prompt
            if ($targetDB -is [array] -and $targetDB.Count -gt 1) {
                Write-Host "  WARNING: Database '$DatabaseName' exists in multiple instances:" -ForegroundColor Yellow
                $mIdx = 1
                foreach ($mdb in $targetDB) {
                    Write-Host "    [$mIdx] $($mdb.properties.friendlyName) (Instance: $($mdb.properties.parentName))" -ForegroundColor White
                    $mIdx++
                }
                Write-Host ""
                Write-Host "  TIP: Use -InstanceName to target a specific instance." -ForegroundColor Cyan
                $mChoice = Read-Host '  Select instance (default: 1)'
                if ([string]::IsNullOrWhiteSpace($mChoice)) { $mChoice = "1" }
                $mSelectedIdx = [int]$mChoice - 1
                if ($mSelectedIdx -ge 0 -and $mSelectedIdx -lt $targetDB.Count) {
                    $targetDB = $targetDB[$mSelectedIdx]
                } else {
                    $targetDB = $targetDB[0]
                }
            }
        }

        if ($targetDB) {
            if ($targetDB -is [array]) { $targetDB = $targetDB[0] }
            $dbsToStop = @($targetDB)
        } else {
            Write-Host "  ERROR: Database '$DatabaseName' not found in protected items." -ForegroundColor Red
            Write-Host "  Available databases:" -ForegroundColor Yellow
            foreach ($db in $vmProtectedDBs) {
                Write-Host "    - $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
            }
            exit 1
        }
    } elseif ($StopAll) {
        # Stop all
        $dbsToStop = $vmProtectedDBs
        Write-Host "  -StopAll specified. Stopping protection for all $($dbsToStop.Count) database(s)..." -ForegroundColor Cyan
    } else {
        # Interactive selection
        $activeDBs = $vmProtectedDBs | Where-Object { $_.properties.protectionState -ne "ProtectionStopped" }

        if ($activeDBs.Count -eq 0) {
            Write-Host "  All databases already have protection stopped." -ForegroundColor Green
        } else {
            Write-Host "  Select database(s) to stop protection:" -ForegroundColor Cyan
            Write-Host "    [A] All databases - $($activeDBs.Count) active" -ForegroundColor White

            $idx = 1
            foreach ($db in $activeDBs) {
                Write-Host "    [$idx] $($db.properties.friendlyName) (State: $($db.properties.protectionState))" -ForegroundColor White
                $idx++
            }
            Write-Host ""
            $choice = Read-Host "  Enter number or 'A' for all (default: A)"

            if ([string]::IsNullOrWhiteSpace($choice) -or $choice -ieq 'A') {
                $dbsToStop = $activeDBs
            } else {
                $selIdx = [int]$choice - 1
                if ($selIdx -ge 0 -and $selIdx -lt $activeDBs.Count) {
                    $dbsToStop = @($activeDBs[$selIdx])
                } else {
                    Write-Host "  Invalid selection." -ForegroundColor Red
                    exit 1
                }
            }
        }
    }

    # Execute stop protection in parallel
    if ($dbsToStop.Count -gt 0) {
        $stopResult = Stop-SQLDatabasesParallel -ProtectedItems $dbsToStop -Headers $headers -ApiVersion $apiVersion
        $successCount = $stopResult.Succeeded
        $failCount = $stopResult.Failed

        Write-Host ""
        Write-Host "  Stop Protection Summary:" -ForegroundColor Cyan
        Write-Host "    Succeeded: $successCount" -ForegroundColor Green
        if ($stopResult.Skipped -gt 0) {
            Write-Host "    Skipped:   $($stopResult.Skipped)" -ForegroundColor Yellow
        }
        if ($failCount -gt 0) {
            Write-Host "    Failed:    $failCount" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# ============================================================================
# CHECK IF ALL DBs ARE NOW STOPPED - PROMPT FOR UNREGISTER
# ============================================================================

$runUnregister = $false

if ($vmProtectedDBs.Count -gt 0) {
    # Re-check: are all databases now in ProtectionStopped state?
    $activeRemaining = $vmProtectedDBs | Where-Object {
        $_.properties.protectionState -ne "ProtectionStopped"
    }

    # Subtract the ones we just successfully stopped
    if ($dbsToStop.Count -gt 0 -and $successCount -eq $dbsToStop.Count) {
        $stillActiveCount = $activeRemaining.Count - $successCount
        if ($stillActiveCount -le 0) { $stillActiveCount = 0 }
    } else {
        $stillActiveCount = $activeRemaining.Count
    }

    if ($stillActiveCount -le 0) {
        Write-Host ""
        Write-Host "  All SQL databases on VM '$vmName' now have protection stopped." -ForegroundColor Green
        Write-Host ""
        Write-Host "  Would you like to also UNREGISTER the VM from the vault?" -ForegroundColor Cyan
        Write-Host "  Recovery points are preserved (stop-with-retain keeps them)." -ForegroundColor Gray
        Write-Host ""
        $unregChoice = Read-Host '  Unregister VM? [Y/N, default: N]'

        if ($unregChoice -ieq 'Y') {
            $runUnregister = $true
            Write-Host "  Proceeding with unregistration..." -ForegroundColor Cyan
        } else {
            Write-Host "  Skipping unregistration." -ForegroundColor Gray
        }
    }
} elseif ($vmProtectedDBs.Count -eq 0) {
    # No protected items found - VM might be registered but all DBs already unprotected
    Write-Host ""
    Write-Host "  No protected databases found on VM '$vmName'." -ForegroundColor Yellow
    Write-Host "  Would you like to UNREGISTER the VM from the vault?" -ForegroundColor Cyan
    Write-Host "  Recovery points are preserved (stop-with-retain keeps them)." -ForegroundColor Gray
    Write-Host ""
    $unregChoice = Read-Host '  Unregister VM? [Y/N, default: N]'

    if ($unregChoice -ieq 'Y') {
        $runUnregister = $true
    }
}

# ============================================================================
# PROMPTED UNREGISTER: Re-invoke with -Unregister flag
# ============================================================================

if ($runUnregister) {
    Write-Host ""
    Write-Host "  Re-running with -Unregister flag..." -ForegroundColor Cyan
    Write-Host ""
    & $PSCommandPath -VaultSubscriptionId $VaultSubscriptionId -VaultResourceGroup $VaultResourceGroup -VaultName $VaultName -VMResourceGroup $VMResourceGroup -VMName $VMName -Unregister
    exit $LASTEXITCODE
}

# ============================================================================
# SUMMARY (non-unregister flow, no prompt taken)
# ============================================================================

Write-Host ""
Write-Host "Summary:" -ForegroundColor Yellow
if ($vmProtectedDBs.Count -gt 0 -and $dbsToStop.Count -gt 0) {
    Write-Host "  Databases processed:  $($dbsToStop.Count)" -ForegroundColor White
    Write-Host "  Action:               Stop Protection (Retain Data)" -ForegroundColor White
}
Write-Host ""
Write-Host "  Recovery points are RETAINED and accessible from the vault." -ForegroundColor Green
Write-Host "  To fully unregister the VM, re-run with -Unregister or answer 'Y' when prompted." -ForegroundColor Gray
Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

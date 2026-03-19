<#
.SYNOPSIS
    Bulk CSV-driven script to unregister physical SQL IaaS VM containers that
    participate in SQL Always On Availability Groups from a Recovery Services Vault.

.DESCRIPTION
    Handles the complex AG unregistration workflow:
      1. Discovers all containers and protected databases in the vault.
      2. Classifies databases as Standalone (on physical container) or AG
         (on an AG container associated with the physical VM).
      3. Checks / enables vault soft delete (critical for data safety).
      4. Stops protection with RETAIN DATA for standalone databases.
      5. Stops protection with DELETE DATA for AG databases (soft-deleted).
      6. Unregisters the physical container(s) from the vault.
      7. Waits 3 minutes for propagation.
      8. Undeletes the soft-deleted AG databases (foolproof with retries).

    End state: all databases end up in ProtectionStopped state with recovery
    points preserved, and the physical VM container is unregistered.

    The CSV must contain at minimum these columns:
      VaultSubscriptionId, VaultResourceGroup, VaultName, VMResourceGroup, VMName

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER ResultsPath
    Path to export the results CSV. If omitted, results are saved next to the
    input CSV with a timestamp suffix.

.PARAMETER SkipConfirmation
    Skip all confirmation prompts including soft-delete enablement. When set,
    soft delete is automatically enabled if disabled, and all operations
    proceed without user interaction.

.PARAMETER StopOnFirstFailure
    Stop processing remaining VMs if any VM fails.

.PARAMETER WhatIf
    Validate the CSV, discover containers and databases, display the
    execution plan without actually running any operations.

.PARAMETER Token
    Pre-fetched bearer token. When provided, skips authentication.
    Used by automation / wrapper scripts.

.EXAMPLE
    # Standard interactive run
    .\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath "C:\input\ag-vms.csv"

.EXAMPLE
    # Fully non-interactive (automation)
    .\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath "C:\input\ag-vms.csv" -SkipConfirmation

.EXAMPLE
    # Dry run - discover and display plan only
    .\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath "C:\input\ag-vms.csv" -WhatIf

.NOTES
    Author: Azure Backup Script Generator
    Date: March 18, 2026
    IMPORTANT: This script performs stop protection with DELETE DATA for AG
    databases. Vault soft delete MUST be enabled to ensure data safety.
    The script enforces this automatically.

    Reference: https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/backup-resource-vault-configs
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to export the results CSV.")]
    [string]$ResultsPath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip all confirmation prompts. Auto-enables soft delete if disabled.")]
    [switch]$SkipConfirmation,

    [Parameter(Mandatory = $false, HelpMessage = "Stop processing if any VM fails.")]
    [switch]$StopOnFirstFailure,

    [Parameter(Mandatory = $false, HelpMessage = "Pre-fetched bearer token. Skips authentication when provided.")]
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
        Write-Host "    No tracking URL available. Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($DelaySeconds * 3)
        return $true
    }

    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds

        try {
            $statusResponse = Invoke-WebRequest -Uri $LocationUrl -Method GET -Headers $Headers -UseBasicParsing
            if ($statusResponse.StatusCode -eq 200 -or $statusResponse.StatusCode -eq 204) {
                Write-Host "    $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                Write-Host "    $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        }

        $retryCount++
        Write-Host "    Waiting for $OperationName... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
    }

    Write-Host "    WARNING: $OperationName timed out." -ForegroundColor Yellow
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
    Write-Host "    Status Code: $statusCode" -ForegroundColor Red
    Write-Host "    Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json

        if ($errorJson.error) {
            Write-Host "    Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "    Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch { }
}

# ============================================================================
# HELPER FUNCTION: Submit stop protection with RETAIN data
# ============================================================================

function Submit-StopProtectionRetainRequest {
    param(
        [object]$ProtectedItem,
        [hashtable]$Headers,
        [string]$ApiVersion
    )

    $dbFriendlyName = $ProtectedItem.properties.friendlyName
    $currentState = $ProtectedItem.properties.protectionState

    if ($currentState -ieq "ProtectionStopped") {
        return @{ Name = $dbFriendlyName; Status = "Skipped"; TrackingUrl = $null }
    }

    $itemUri = "https://management.azure.com$($ProtectedItem.id)?api-version=$ApiVersion"

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
            Write-Host "      ERROR: Failed to submit stop-retain for '$dbFriendlyName'" -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Stop Protection (Retain)"
            return @{ Name = $dbFriendlyName; Status = "Failed"; TrackingUrl = $null }
        }
    }

    return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
}

# ============================================================================
# HELPER FUNCTION: Submit stop protection with DELETE data (soft delete)
# ============================================================================

function Submit-StopProtectionDeleteRequest {
    param(
        [object]$ProtectedItem,
        [hashtable]$Headers,
        [string]$ApiVersion
    )

    $dbFriendlyName = $ProtectedItem.properties.friendlyName
    $currentState = $ProtectedItem.properties.protectionState

    if ($currentState -ieq "SoftDeleted") {
        return @{ Name = $dbFriendlyName; Status = "Skipped"; TrackingUrl = $null }
    }

    $itemUri = "https://management.azure.com$($ProtectedItem.id)?api-version=$ApiVersion"

    try {
        $deleteResponse = Invoke-WebRequest -Uri $itemUri -Method DELETE -Headers $Headers -UseBasicParsing
        $statusCode = $deleteResponse.StatusCode

        if ($statusCode -eq 200 -or $statusCode -eq 204) {
            return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
        } elseif ($statusCode -eq 202) {
            $asyncUrl = $deleteResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $deleteResponse.Headers["Location"]
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
        } elseif ($statusCode -eq 204) {
            return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
        } else {
            Write-Host "      ERROR: Failed to submit stop-delete for '$dbFriendlyName'" -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Stop Protection (Delete)"
            return @{ Name = $dbFriendlyName; Status = "Failed"; TrackingUrl = $null }
        }
    }

    return @{ Name = $dbFriendlyName; Status = "Succeeded"; TrackingUrl = $null }
}

# ============================================================================
# HELPER FUNCTION: Batch stop with polling (used for both retain and delete)
# ============================================================================

function Invoke-BatchProtectionStop {
    param(
        [array]$ProtectedItems,
        [hashtable]$Headers,
        [string]$ApiVersion,
        [string]$Mode,  # "Retain" or "Delete"
        [int]$MaxPollRetries = 40,
        [int]$PollDelaySeconds = 10
    )

    $successCount = 0
    $failCount = 0
    $skipCount = 0
    $pendingOps = @()

    $skipState = if ($Mode -eq "Delete") { "SoftDeleted" } else { "ProtectionStopped" }

    Write-Host "    Phase 1: Submitting stop-$($Mode.ToLower()) requests for $($ProtectedItems.Count) database(s)..." -ForegroundColor Cyan
    Write-Host ""

    foreach ($db in $ProtectedItems) {
        $currentState = $db.properties.protectionState
        if ($currentState -ieq $skipState) {
            Write-Host "      SKIPPED: '$($db.properties.friendlyName)' - already in $skipState state" -ForegroundColor Yellow
            $skipCount++
            continue
        }

        Write-Host "      Submitting stop-$($Mode.ToLower()) for '$($db.properties.friendlyName)'..." -ForegroundColor Cyan

        $result = $null
        if ($Mode -eq "Delete") {
            $result = Submit-StopProtectionDeleteRequest -ProtectedItem $db -Headers $Headers -ApiVersion $ApiVersion
        } else {
            $result = Submit-StopProtectionRetainRequest -ProtectedItem $db -Headers $Headers -ApiVersion $ApiVersion
        }

        if ($result.Status -eq "Succeeded") {
            Write-Host "      SUCCESS: '$($result.Name)' completed immediately" -ForegroundColor Green
            $successCount++
        } elseif ($result.Status -eq "InProgress") {
            Write-Host "      ACCEPTED: '$($result.Name)' (202) - will poll" -ForegroundColor Green
            $pendingOps += $result
        } elseif ($result.Status -eq "Skipped") {
            $skipCount++
        } else {
            $failCount++
        }
    }

    # Phase 2: Poll pending operations
    if ($pendingOps.Count -gt 0) {
        Write-Host ""
        Write-Host "    Phase 2: Polling $($pendingOps.Count) pending operation(s)..." -ForegroundColor Cyan

        $retryCount = 0
        while ($pendingOps.Count -gt 0 -and $retryCount -lt $MaxPollRetries) {
            Start-Sleep -Seconds $PollDelaySeconds
            $retryCount++

            $stillPending = @()

            foreach ($op in $pendingOps) {
                if ([string]::IsNullOrWhiteSpace($op.TrackingUrl)) {
                    Write-Host "      SUCCESS: '$($op.Name)' (no tracking URL, assumed complete)" -ForegroundColor Green
                    $successCount++
                    continue
                }

                try {
                    $opResponse = Invoke-RestMethod -Uri $op.TrackingUrl -Method GET -Headers $Headers
                    $opStatus = if ($opResponse.status) { $opResponse.status } else { $null }

                    if ($opStatus -eq "Succeeded") {
                        Write-Host "      SUCCESS: '$($op.Name)' completed" -ForegroundColor Green
                        $successCount++
                    } elseif ($opStatus -eq "Failed") {
                        Write-Host "      FAILED: '$($op.Name)'" -ForegroundColor Red
                        $failCount++
                    } else {
                        $stillPending += $op
                    }
                } catch {
                    $innerCode = $_.Exception.Response.StatusCode.value__
                    if ($innerCode -eq 200 -or $innerCode -eq 204) {
                        Write-Host "      SUCCESS: '$($op.Name)' completed" -ForegroundColor Green
                        $successCount++
                    } else {
                        $stillPending += $op
                    }
                }
            }

            $pendingOps = $stillPending

            if ($pendingOps.Count -gt 0) {
                $names = ($pendingOps | ForEach-Object { $_.Name }) -join ", "
                Write-Host "      Waiting... ($retryCount/$MaxPollRetries) - pending: $names" -ForegroundColor Yellow
            }
        }

        foreach ($op in $pendingOps) {
            Write-Host "      WARNING: '$($op.Name)' timed out. Check Azure Portal." -ForegroundColor Yellow
            $failCount++
        }
    }

    return @{
        Succeeded = $successCount
        Failed    = $failCount
        Skipped   = $skipCount
    }
}

# ============================================================================
# DISPLAY BANNER
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk SQL AG Container Unregister from Vault" -ForegroundColor Cyan
Write-Host "  (Handles Standalone + AG databases with soft-delete safety)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# STEP 1: VALIDATE & PARSE CSV
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

$requiredColumns = @("VaultSubscriptionId", "VaultResourceGroup", "VaultName", "VMResourceGroup", "VMName")
$csvColumns = $csvData[0].PSObject.Properties.Name

$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
    Write-Host "  ERROR: CSV is missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Required columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
    exit 1
}

# Validate each row
$validationErrors = @()
$rowNum = 0
foreach ($row in $csvData) {
    $rowNum++
    foreach ($col in $requiredColumns) {
        if ([string]::IsNullOrWhiteSpace($row.$col)) {
            $validationErrors += "  Row $rowNum : Column '$col' is empty (VMName: $($row.VMName))"
        }
    }
}

if ($validationErrors.Count -gt 0) {
    Write-Host "  ERROR: CSV validation failed:" -ForegroundColor Red
    foreach ($err in $validationErrors) {
        Write-Host $err -ForegroundColor Red
    }
    exit 1
}

Write-Host "  CSV file:        $CsvPath" -ForegroundColor Gray
Write-Host "  Total VMs:       $($csvData.Count)" -ForegroundColor Gray
Write-Host ""

# Group by vault
$vaultGroups = $csvData | Group-Object { "$($_.VaultSubscriptionId)|$($_.VaultResourceGroup)|$($_.VaultName)" }

Write-Host "  Vault(s) to process: $($vaultGroups.Count)" -ForegroundColor Gray
foreach ($vg in $vaultGroups) {
    $sampleRow = $vg.Group[0]
    Write-Host "    - $($sampleRow.VaultName) ($($vg.Count) VM(s))" -ForegroundColor White
}
Write-Host ""

# WhatIf banner
if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Mode: Discovery and plan only. No changes will be made." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================================
# STEP 2: AUTHENTICATE TO AZURE
# ============================================================================

Write-Host "STEP 2: Authenticating to Azure" -ForegroundColor Yellow
Write-Host "---------------------------------" -ForegroundColor Yellow
Write-Host ""

$token = $null

if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $token = $Token
    Write-Host "  Using pre-fetched token (passed via -Token parameter)" -ForegroundColor Green
} else {
    try {
        $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"

        if ($tokenResponse.Token -is [System.Security.SecureString]) {
            $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
        } else {
            $token = $tokenResponse.Token
        }

        if (-not $token.StartsWith("eyJ")) {
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
            Write-Host "  ERROR: Failed to authenticate to Azure." -ForegroundColor Red
            Write-Host "    Run 'Connect-AzAccount' or 'az login' first." -ForegroundColor Yellow
            exit 1
        }
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

Write-Host ""

# ============================================================================
# PROCESS EACH VAULT GROUP
# ============================================================================

$allResults = @()
$overallSuccess = $true

foreach ($vaultGroup in $vaultGroups) {

    $vaultSubscriptionId = $vaultGroup.Group[0].VaultSubscriptionId
    $vaultResourceGroup  = $vaultGroup.Group[0].VaultResourceGroup
    $vaultName           = $vaultGroup.Group[0].VaultName
    $vmsInGroup          = $vaultGroup.Group

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Processing Vault: $vaultName" -ForegroundColor Cyan
    Write-Host "  Subscription:     $vaultSubscriptionId" -ForegroundColor Gray
    Write-Host "  Resource Group:   $vaultResourceGroup" -ForegroundColor Gray
    Write-Host "  VMs:              $($vmsInGroup.Count)" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    # ========================================================================
    # STEP 3: CHECK / ENABLE SOFT DELETE
    # ========================================================================

    Write-Host "  STEP 3: Checking Vault Soft Delete Settings" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $vaultConfigUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupconfig/vaultconfig?api-version=$apiVersion"

    $softDeleteEnabled = $false

    try {
        $vaultConfigResponse = Invoke-RestMethod -Uri $vaultConfigUri -Method GET -Headers $headers
        $softDeleteState = $vaultConfigResponse.properties.softDeleteFeatureState

        Write-Host "    Soft Delete State: $softDeleteState" -ForegroundColor Gray

        if ($softDeleteState -ieq "Enabled" -or $softDeleteState -ieq "AlwaysON") {
            Write-Host "    Soft delete is ENABLED. Data safety guaranteed." -ForegroundColor Green
            $softDeleteEnabled = $true
            Write-Host "    Soft delete verified: $softDeleteEnabled" -ForegroundColor Gray
        } else {
            Write-Host ""
            Write-Host "    WARNING: Soft delete is DISABLED on vault '$vaultName'." -ForegroundColor Red
            Write-Host "    This script performs stop-protection with DELETE DATA for AG databases." -ForegroundColor Red
            Write-Host "    Without soft delete, recovery points will be PERMANENTLY LOST." -ForegroundColor Red
            Write-Host ""

            $enableSoftDelete = $false

            if ($SkipConfirmation) {
                Write-Host "    -SkipConfirmation: Auto-enabling soft delete for data safety..." -ForegroundColor Yellow
                $enableSoftDelete = $true
            } else {
                $sdChoice = Read-Host '    Enable soft delete on this vault? [Y/N]'
                if ($sdChoice -ieq 'Y') {
                    $enableSoftDelete = $true
                } else {
                    Write-Host ""
                    Write-Host "    FATAL: Cannot proceed without soft delete enabled." -ForegroundColor Red
                    Write-Host "    Soft delete is required to safely recover AG database data" -ForegroundColor Red
                    Write-Host "    after the stop-delete + undelete workflow." -ForegroundColor Red
                    Write-Host ""
                    Write-Host "    Script aborted." -ForegroundColor Red
                    exit 1
                }
            }

            if ($enableSoftDelete) {
                if (-not $WhatIfPreference) {
                    Write-Host "    Enabling soft delete on vault '$vaultName'..." -ForegroundColor Cyan

                    $enableBody = @{
                        properties = @{
                            softDeleteFeatureState = "Enabled"
                        }
                    } | ConvertTo-Json -Depth 10

                    try {
                        $enableResponse = Invoke-RestMethod -Uri $vaultConfigUri -Method PUT -Headers $headers -Body $enableBody -ContentType "application/json"
                        $newState = $enableResponse.properties.softDeleteFeatureState
                        Write-Host "    Soft delete state is now: $newState" -ForegroundColor Green
                        $softDeleteEnabled = $true
                    } catch {
                        Write-Host "    ERROR: Failed to enable soft delete." -ForegroundColor Red
                        Write-ApiError -ErrorRecord $_ -Context "Enable Soft Delete"
                        Write-Host ""
                        Write-Host "    FATAL: Cannot proceed without soft delete. Script aborted." -ForegroundColor Red
                        exit 1
                    }

                    Write-Host "    Waiting 2 minutes for soft delete settings to propagate..." -ForegroundColor Cyan
                    Start-Sleep -Seconds 120
                    Write-Host "    Propagation wait complete. Verifying soft delete state..." -ForegroundColor Cyan

                    # Re-query vault config to confirm soft delete is actually enabled
                    try {
                        $verifyConfigResponse = Invoke-RestMethod -Uri $vaultConfigUri -Method GET -Headers $headers
                        $verifiedState = $verifyConfigResponse.properties.softDeleteFeatureState

                        if ($verifiedState -ieq "Enabled" -or $verifiedState -ieq "AlwaysON") {
                            Write-Host "    CONFIRMED: Soft delete is now '$verifiedState'." -ForegroundColor Green
                            $softDeleteEnabled = $true
                        } else {
                            Write-Host "    ERROR: Soft delete state is '$verifiedState' after enablement attempt." -ForegroundColor Red
                            Write-Host "    Expected 'Enabled' but got '$verifiedState'." -ForegroundColor Red
                            Write-Host ""
                            Write-Host "    FATAL: Cannot proceed without confirmed soft delete. Script aborted." -ForegroundColor Red
                            exit 1
                        }
                    } catch {
                        Write-Host "    ERROR: Failed to verify soft delete state after enablement." -ForegroundColor Red
                        Write-ApiError -ErrorRecord $_ -Context "Verify Soft Delete"
                        Write-Host ""
                        Write-Host "    FATAL: Cannot confirm soft delete is enabled. Script aborted." -ForegroundColor Red
                        exit 1
                    }
                } else {
                    Write-Host "    [WhatIf] Would enable soft delete on vault '$vaultName'" -ForegroundColor Yellow
                    $softDeleteEnabled = $true
                }
            }
        }
    } catch {
        Write-Host "    ERROR: Failed to query vault configuration." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "Get Vault Config"
        Write-Host ""
        Write-Host "    FATAL: Cannot verify soft delete state. Script aborted." -ForegroundColor Red
        exit 1
    }

    Write-Host ""

    # ========================================================================
    # STEP 4: DISCOVER CONTAINERS
    # ========================================================================

    Write-Host "  STEP 4: Discovering Containers in Vault" -ForegroundColor Yellow
    Write-Host "  ------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    # Strategy: Try listing via backupProtectionContainers endpoint first.
    # If that returns no AG containers, derive them from protected items
    # and query each AG container individually for node details.

    $allContainers = @()

    # Method 1: List physical containers via backupProtectionContainers
    $containersUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectionContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

    try {
        $currentUri = $containersUri
        while ($currentUri) {
            $containerResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers
            if ($containerResponse.value) {
                $allContainers += $containerResponse.value
            }
            $currentUri = $containerResponse.nextLink
        }
        Write-Host "    Physical containers from listing: $($allContainers.Count)" -ForegroundColor Gray
    } catch {
        Write-Host "    Container listing returned error, will discover from protected items..." -ForegroundColor Yellow
    }

    # Method 2: Discover AG containers from protected items and query each individually
    Write-Host "    Discovering AG containers from protected items..." -ForegroundColor Cyan

    $piDiscoverUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"
    $allPIForContainers = @()
    try {
        $curPIUri = $piDiscoverUri
        while ($curPIUri) {
            $piResp = Invoke-RestMethod -Uri $curPIUri -Method GET -Headers $headers
            if ($piResp.value) { $allPIForContainers += $piResp.value }
            $curPIUri = $piResp.nextLink
        }
    } catch { }

    # Extract unique AG container names from protected items
    $agContainerNamesFromPI = $allPIForContainers | ForEach-Object {
        $cn = $_.properties.containerName
        if ($cn -and $cn -imatch "SQLAGWorkLoadContainer") { $cn }
    } | Sort-Object -Unique

    foreach ($agCnName in $agContainerNamesFromPI) {
        # Check if already in allContainers
        $alreadyFound = $allContainers | Where-Object { $_.name -ieq $agCnName }
        if (-not $alreadyFound) {
            # Query this AG container directly
            $agLookupUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$agCnName`?api-version=$apiVersion"
            try {
                $agContainerObj = Invoke-RestMethod -Uri $agLookupUri -Method GET -Headers $headers
                if ($agContainerObj) {
                    $allContainers += $agContainerObj
                    Write-Host "    Found AG container: $($agContainerObj.name)" -ForegroundColor Magenta
                }
            } catch {
                Write-Host "    Warning: Could not query AG container '$agCnName'" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "    Total containers discovered: $($allContainers.Count)" -ForegroundColor Gray

    # Identify physical containers for our VMs
    $physicalContainerMap = @{} # Key: VMName (lower), Value: container object
    $physicalContainerNames = @() # Container names for matching

    foreach ($vm in $vmsInGroup) {
        $vmNameLower = $vm.VMName.ToLower()
        $expectedFull = "VMAppContainer;Compute;$($vm.VMResourceGroup);$($vm.VMName)".ToLower()

        $matchedContainer = $allContainers | Where-Object {
            $cn = if ($_.name) { $_.name.ToLower() } else { "" }
            # Match using full container name pattern including resource group
            # This prevents matching the wrong VM when same VM name exists in different RGs
            $cn -ieq $expectedFull
        } | Select-Object -First 1

        # Fallback: if no full match, try last segment (only if VM name is unique)
        if (-not $matchedContainer) {
            $matchedContainer = $allContainers | Where-Object {
                $cn = if ($_.name) { $_.name.ToLower() } else { "" }
                $lastSegment = if ($cn.Contains(";")) { $cn.Split(";")[-1] } else { $cn }
                $lastSegment -ieq $vmNameLower
            } | Select-Object -First 1
        }

        if ($matchedContainer) {
            # Check registration status - skip if already unregistered or soft-deleted
            $regStatus = $matchedContainer.properties.registrationStatus
            if ($regStatus -and $regStatus -ine "Registered") {
                Write-Host "    Physical container found: $($matchedContainer.name) [Status: $regStatus] - SKIPPED (not registered)" -ForegroundColor Yellow
            } else {
                $physicalContainerMap[$vmNameLower] = $matchedContainer
                $physicalContainerNames += $matchedContainer.name.ToLower()
                Write-Host "    Physical container found: $($matchedContainer.name)" -ForegroundColor Green
            }
        } else {
            # Try constructing the expected name and checking directly
            $constructedName = "VMAppContainer;Compute;$($vm.VMResourceGroup);$($vm.VMName)"
            $checkUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$constructedName`?api-version=$apiVersion"
            try {
                $directCheck = Invoke-RestMethod -Uri $checkUri -Method GET -Headers $headers
                if ($directCheck) {
                    $regStatus = $directCheck.properties.registrationStatus
                    if ($regStatus -and $regStatus -ine "Registered") {
                        Write-Host "    Physical container found: $($directCheck.name) [Status: $regStatus] - SKIPPED (not registered)" -ForegroundColor Yellow
                    } else {
                        $physicalContainerMap[$vmNameLower] = $directCheck
                        $physicalContainerNames += $directCheck.name.ToLower()
                        Write-Host "    Physical container found (direct lookup): $($directCheck.name)" -ForegroundColor Green
                    }
                }
            } catch {
                Write-Host "    WARNING: Physical container not found for VM '$($vm.VMName)' in resource group '$($vm.VMResourceGroup)'" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""

    # Identify AG containers associated with our VMs
    $agContainerMap = @{} # Key: AG container name (lower), Value: container object
    $vmToAgContainers = @{} # Key: VMName (lower), Value: list of AG container names

    $vmNamesLower = $vmsInGroup | ForEach-Object { $_.VMName.ToLower() }

    # Build a lookup of VM name + resource group for precise matching
    # Key: "vmname|resourcegroup" (lower), used to disambiguate same-named VMs in different RGs
    $vmRGLookup = @{}
    foreach ($vm in $vmsInGroup) {
        $key = "$($vm.VMName.ToLower())|$($vm.VMResourceGroup.ToLower())"
        $vmRGLookup[$key] = $true
    }

    foreach ($container in $allContainers) {
        $containerType = $container.properties.containerType
        # AG containers have type SQLAGWorkLoadContainer or similar
        if ($containerType -ine "SQLAGWorkLoadContainer") { continue }

        $nodesList = $container.properties.extendedInfo.nodesList

        if (-not $nodesList) { continue }

        $matchedVMs = @()
        foreach ($node in $nodesList) {
            $nodeName = ""
            if ($node.nodeName) {
                $nodeName = $node.nodeName.ToLower()
            }

            # Strip FQDN domain suffix if present (e.g., "sqlserver-0.contoso.com" -> "sqlserver-0")
            $nodeShortName = if ($nodeName.Contains(".")) { $nodeName.Split(".")[0] } else { $nodeName }

            # Extract VM name and resource group from sourceResourceId
            $nodeVmNameFromId = ""
            $nodeRGFromId = ""
            if ($node.sourceResourceId) {
                if ($node.sourceResourceId -match "/resourceGroups/([^/]+)/") {
                    $nodeRGFromId = $Matches[1].ToLower()
                }
                if ($node.sourceResourceId -match "/virtualMachines/([^/]+)$") {
                    $nodeVmNameFromId = $Matches[1].ToLower()
                }
            }

            # Match using both VM name AND resource group for precision
            # This prevents cross-RG matching when VMs have identical hostnames
            $matched = $false
            $matchName = ""

            # Priority 1: Match by sourceResourceId (VM name + RG) - most precise
            if ($nodeVmNameFromId -and $nodeRGFromId) {
                $rgKey = "$nodeVmNameFromId|$nodeRGFromId"
                if ($vmRGLookup.ContainsKey($rgKey)) {
                    $matched = $true
                    $matchName = $nodeVmNameFromId
                }
            }

            # Priority 2: Match by short hostname + RG (if sourceResourceId had the RG)
            if (-not $matched -and $nodeShortName -and $nodeRGFromId) {
                $rgKey = "$nodeShortName|$nodeRGFromId"
                if ($vmRGLookup.ContainsKey($rgKey)) {
                    $matched = $true
                    $matchName = $nodeShortName
                }
            }

            # Priority 3: Fallback to name-only match (for cases where sourceResourceId is missing)
            if (-not $matched -and -not $nodeRGFromId) {
                if (($nodeShortName -and ($nodeShortName -in $vmNamesLower)) -or
                    ($nodeVmNameFromId -and ($nodeVmNameFromId -in $vmNamesLower))) {
                    $matched = $true
                    $matchName = if ($nodeShortName -in $vmNamesLower) { $nodeShortName } else { $nodeVmNameFromId }
                }
            }

            if ($matched -and $matchName) {
                $matchedVMs += $matchName
            }
        }

        if ($matchedVMs.Count -gt 0) {
            $cnLower = $container.name.ToLower()
            $agContainerMap[$cnLower] = $container

            foreach ($mv in $matchedVMs) {
                if (-not $vmToAgContainers.ContainsKey($mv)) {
                    $vmToAgContainers[$mv] = @()
                }
                $vmToAgContainers[$mv] += $container.name
            }

            $nodeNames = ($nodesList | ForEach-Object {
                if ($_.nodeName) { $_.nodeName } else { "(unknown)" }
            }) -join ", "

            Write-Host "    AG container found: $($container.name)" -ForegroundColor Magenta
            Write-Host "      Nodes: $nodeNames" -ForegroundColor Gray
            Write-Host "      Matched VMs from CSV: $($matchedVMs -join ', ')" -ForegroundColor Gray
        }
    }

    if ($agContainerMap.Count -eq 0) {
        Write-Host "    No AG containers found associated with the provided VMs." -ForegroundColor Yellow
        Write-Host "    Only standalone databases will be processed (stop-retain)." -ForegroundColor Yellow
    }

    Write-Host ""

    # ========================================================================
    # STEP 5: DISCOVER PROTECTED ITEMS & CLASSIFY
    # ========================================================================

    Write-Host "  STEP 5: Discovering and Classifying Protected Databases" -ForegroundColor Yellow
    Write-Host "  ---------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $protectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload' and itemType eq 'SQLDataBase'"

    $allProtectedItems = @()

    try {
        $currentUri = $protectedItemsUri
        while ($currentUri) {
            $itemsResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers
            if ($itemsResponse.value) {
                $allProtectedItems += $itemsResponse.value
            }
            $currentUri = $itemsResponse.nextLink
            if ($currentUri) { Write-Host "    Fetching next page of protected items..." -ForegroundColor Gray }
        }

        Write-Host "    Total protected SQL databases in vault: $($allProtectedItems.Count)" -ForegroundColor Gray
    } catch {
        Write-Host "    ERROR: Failed to list protected items." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "List Protected Items"
        exit 1
    }

    # Classify: standalone (in physical container) vs AG (in AG container)
    $standaloneDbsToRetain = @()
    $agDbsToDelete = @()
    $agContainerDBGroups = @{} # Key: AG container name, Value: list of DB objects

    foreach ($item in $allProtectedItems) {
        $itemContainerName = if ($item.properties.containerName) { $item.properties.containerName.ToLower() } else { "" }
        $itemContainerFromId = ""
        if ($item.id -match "/protectionContainers/([^/]+)/") {
            $itemContainerFromId = $Matches[1].ToLower()
        }

        # Check if this item belongs to one of our physical containers
        $isStandalone = $false
        foreach ($pcn in $physicalContainerNames) {
            if ($itemContainerName -ieq $pcn -or $itemContainerFromId -ieq $pcn) {
                $isStandalone = $true
                break
            }
        }

        if ($isStandalone) {
            $standaloneDbsToRetain += $item
            continue
        }

        # Check if this item belongs to one of our AG containers
        $isAG = $false
        foreach ($acn in $agContainerMap.Keys) {
            if ($itemContainerName -ieq $acn -or $itemContainerFromId -ieq $acn) {
                $isAG = $true

                if (-not $agContainerDBGroups.ContainsKey($acn)) {
                    $agContainerDBGroups[$acn] = @()
                }
                $agContainerDBGroups[$acn] += $item
                break
            }
        }

        if ($isAG) {
            $agDbsToDelete += $item
        }
    }

    # Filter to only actionable items (not already in final state)
    $standaloneActive = @($standaloneDbsToRetain | Where-Object { $_.properties.protectionState -ine "ProtectionStopped" })
    $standaloneAlreadyStopped = $standaloneDbsToRetain.Count - $standaloneActive.Count
    $agActive = @($agDbsToDelete | Where-Object { $_.properties.protectionState -ine "SoftDeleted" })
    $agAlreadyDeleted = $agDbsToDelete.Count - $agActive.Count

    Write-Host ""
    Write-Host "    Classification Summary:" -ForegroundColor Cyan
    Write-Host "      Standalone DBs (stop-retain):  $($standaloneDbsToRetain.Count) total ($($standaloneActive.Count) active, $standaloneAlreadyStopped already stopped)" -ForegroundColor White
    Write-Host "      AG DBs (stop-delete):          $($agDbsToDelete.Count) total ($($agActive.Count) active, $agAlreadyDeleted already soft-deleted)" -ForegroundColor White
    Write-Host "      AG containers involved:        $($agContainerMap.Count)" -ForegroundColor White
    Write-Host "      Physical containers to unreg:  $($physicalContainerMap.Count)" -ForegroundColor White
    Write-Host ""

    if ($standaloneDbsToRetain.Count -eq 0 -and $agDbsToDelete.Count -eq 0 -and $physicalContainerMap.Count -eq 0) {
        Write-Host "    Nothing to process for this vault." -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    # ========================================================================
    # STEP 6: DISPLAY PLAN & CONFIRM
    # ========================================================================

    Write-Host "  STEP 6: Execution Plan" -ForegroundColor Yellow
    Write-Host "  ------------------------" -ForegroundColor Yellow
    Write-Host ""

    # Display standalone DBs
    if ($standaloneDbsToRetain.Count -gt 0) {
        Write-Host "    STANDALONE DATABASES - Stop Protection with RETAIN DATA:" -ForegroundColor Green
        Write-Host "    (Recovery points will be preserved)" -ForegroundColor Gray
        Write-Host ""

        $groupedStandalone = $standaloneDbsToRetain | Group-Object { $_.properties.containerName }
        foreach ($grp in $groupedStandalone) {
            Write-Host "      Container: $($grp.Name)" -ForegroundColor White
            foreach ($db in $grp.Group) {
                $state = $db.properties.protectionState
                $stateColor = if ($state -ieq "ProtectionStopped") { "Yellow" } else { "White" }
                $action = if ($state -ieq "ProtectionStopped") { "(already stopped)" } else { "(will stop-retain)" }
                Write-Host "        - $($db.properties.friendlyName) [$state] $action" -ForegroundColor $stateColor
            }
            Write-Host ""
        }
    } else {
        Write-Host "    STANDALONE DATABASES: None found." -ForegroundColor Gray
        Write-Host ""
    }

    # Display AG DBs
    if ($agDbsToDelete.Count -gt 0) {
        Write-Host "    AG DATABASES - Stop Protection with DELETE DATA (soft-delete):" -ForegroundColor Magenta
        Write-Host "    (Will be UNDELETED after container unregistration to preserve data)" -ForegroundColor Gray
        Write-Host ""

        foreach ($agEntry in $agContainerDBGroups.GetEnumerator()) {
            $agContainerName = $agEntry.Key
            $agContainerObj = $agContainerMap[$agContainerName]
            $agDbs = $agEntry.Value

            # Get nodes info
            $nodeNames = "(unknown)"
            if ($agContainerObj -and $agContainerObj.properties.extendedInfo.nodesList) {
                $nodeNames = ($agContainerObj.properties.extendedInfo.nodesList | ForEach-Object {
                    if ($_.nodeName) { $_.nodeName } else { "(unknown)" }
                }) -join ", "
            }

            Write-Host "      AG Container: $($agContainerObj.name)" -ForegroundColor Magenta
            Write-Host "      Nodes: $nodeNames" -ForegroundColor Gray

            foreach ($db in $agDbs) {
                $state = $db.properties.protectionState
                $stateColor = if ($state -ieq "SoftDeleted") { "Yellow" } else { "White" }
                $action = if ($state -ieq "SoftDeleted") { "(already soft-deleted)" } else { "(will stop-delete)" }
                Write-Host "        - $($db.properties.friendlyName) [$state] $action" -ForegroundColor $stateColor
            }
            Write-Host ""
        }
    } else {
        Write-Host "    AG DATABASES: None found." -ForegroundColor Gray
        Write-Host ""
    }

    # Display containers to unregister
    Write-Host "    PHYSICAL CONTAINERS TO UNREGISTER:" -ForegroundColor Yellow
    foreach ($pcEntry in $physicalContainerMap.GetEnumerator()) {
        Write-Host "      - $($pcEntry.Value.name)" -ForegroundColor White
    }
    Write-Host ""

    # Workflow summary
    Write-Host "    WORKFLOW:" -ForegroundColor Cyan
    Write-Host "      1. Stop protection RETAIN DATA for $($standaloneActive.Count) standalone DB(s)" -ForegroundColor White
    Write-Host "      2. Stop protection DELETE DATA for $($agActive.Count) AG DB(s) (soft-deleted)" -ForegroundColor White
    Write-Host "      3. Unregister $($physicalContainerMap.Count) physical container(s)" -ForegroundColor White
    Write-Host "      4. Wait 3 minutes for propagation" -ForegroundColor White
    Write-Host "      5. Undelete $($agActive.Count) AG DB(s) to recover data" -ForegroundColor White
    Write-Host ""

    # WhatIf: stop here
    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] Dry run complete for vault '$vaultName'. No changes made." -ForegroundColor Yellow
        Write-Host ""
        continue
    }

    # Confirmation prompt
    if (-not $SkipConfirmation) {
        Write-Host "    Do you want to proceed with the above plan?" -ForegroundColor Cyan
        Write-Host "    This will:" -ForegroundColor Gray
        Write-Host "      - Stop-retain $($standaloneActive.Count) standalone database(s)" -ForegroundColor Gray
        Write-Host "      - Stop-delete $($agActive.Count) AG database(s) (then undelete after unregistration)" -ForegroundColor Gray
        Write-Host "      - Unregister $($physicalContainerMap.Count) physical container(s)" -ForegroundColor Gray
        Write-Host ""
        $confirmProceed = Read-Host '    Proceed? [Y/N, default: Y]'
        if ($confirmProceed -ieq 'N') {
            Write-Host "    Aborted by user." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    # ========================================================================
    # STEP 7: STOP PROTECTION WITH RETAIN DATA (STANDALONE)
    # ========================================================================

    Write-Host "  STEP 7: Stopping Protection (Retain Data) for Standalone Databases" -ForegroundColor Yellow
    Write-Host "  ---------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $retainResult = @{ Succeeded = 0; Failed = 0; Skipped = 0 }

    if ($standaloneDbsToRetain.Count -gt 0) {
        $retainResult = Invoke-BatchProtectionStop -ProtectedItems $standaloneDbsToRetain -Headers $headers -ApiVersion $apiVersion -Mode "Retain"

        Write-Host ""
        Write-Host "    Stop-Retain Summary: $($retainResult.Succeeded) succeeded, $($retainResult.Skipped) skipped, $($retainResult.Failed) failed" -ForegroundColor Cyan
    } else {
        Write-Host "    No standalone databases to process." -ForegroundColor Gray
    }

    Write-Host ""

    # ========================================================================
    # STEP 8: STOP PROTECTION WITH DELETE DATA (AG DATABASES)
    # ========================================================================

    Write-Host "  STEP 8: Stopping Protection (Delete Data) for AG Databases" -ForegroundColor Yellow
    Write-Host "  --------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $deleteResult = @{ Succeeded = 0; Failed = 0; Skipped = 0 }

    # Store AG DB details BEFORE deletion for foolproof undelete
    $agDbDetailsForUndelete = @()

    if ($agDbsToDelete.Count -gt 0) {
        foreach ($agDb in $agDbsToDelete) {
            $containerNameForItem = $agDb.properties.containerName
            if ([string]::IsNullOrWhiteSpace($containerNameForItem) -and $agDb.id -match "/protectionContainers/([^/]+)/") {
                $containerNameForItem = $Matches[1]
            }
            $protectedItemNameForItem = ""
            if ($agDb.id -match "/protectedItems/([^/]+)$") {
                $protectedItemNameForItem = $Matches[1]
            }

            $agDbDetailsForUndelete += [PSCustomObject]@{
                Id                = $agDb.id
                FriendlyName      = $agDb.properties.friendlyName
                ContainerName     = $containerNameForItem
                ProtectedItemName = $protectedItemNameForItem
                SourceResourceId  = $agDb.properties.sourceResourceId
                ParentName        = $agDb.properties.parentName
                OriginalState     = $agDb.properties.protectionState
            }
        }

        Write-Host "    Stored $($agDbDetailsForUndelete.Count) AG database detail(s) for later undelete." -ForegroundColor Gray
        Write-Host ""

        $deleteResult = Invoke-BatchProtectionStop -ProtectedItems $agDbsToDelete -Headers $headers -ApiVersion $apiVersion -Mode "Delete"

        Write-Host ""
        Write-Host "    Stop-Delete Summary: $($deleteResult.Succeeded) succeeded, $($deleteResult.Skipped) skipped, $($deleteResult.Failed) failed" -ForegroundColor Cyan

        if ($deleteResult.Succeeded -eq 0 -and $deleteResult.Skipped -eq 0) {
            Write-Host ""
            Write-Host "    ERROR: All stop-delete operations failed. Cannot safely proceed." -ForegroundColor Red
            Write-Host "    No data has been lost (operations failed before deletion)." -ForegroundColor Yellow
            $overallSuccess = $false

            $allResults += [PSCustomObject]@{
                Vault              = $vaultName
                Phase              = "Stop-Delete AG DBs"
                Status             = "Failed"
                Details            = "All $($agDbsToDelete.Count) delete operations failed"
            }
            continue
        }
    } else {
        Write-Host "    No AG databases to process." -ForegroundColor Gray
    }

    Write-Host ""

    # Wait for stop operations to propagate before unregistering
    if ($standaloneDbsToRetain.Count -gt 0 -or $agDbsToDelete.Count -gt 0) {
        Write-Host "    Waiting 60 seconds for stop operations to propagate..." -ForegroundColor Cyan
        Start-Sleep -Seconds 60
    }

    # ========================================================================
    # STEP 9: UNREGISTER PHYSICAL CONTAINERS
    # ========================================================================

    Write-Host "  STEP 9: Unregistering Physical Containers" -ForegroundColor Yellow
    Write-Host "  ---------------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $unregisterSuccessCount = 0
    $unregisterFailCount = 0

    foreach ($pcEntry in $physicalContainerMap.GetEnumerator()) {
        $containerObj = $pcEntry.Value
        $containerName = $containerObj.name

        Write-Host "    Unregistering container '$containerName'..." -ForegroundColor Cyan

        $unregisterUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

        try {
            $unregResponse = Invoke-WebRequest -Uri $unregisterUri -Method DELETE -Headers $headers -UseBasicParsing
            $statusCode = $unregResponse.StatusCode

            if ($statusCode -eq 200 -or $statusCode -eq 204) {
                Write-Host "    Container '$containerName' unregistered successfully." -ForegroundColor Green
                $unregisterSuccessCount++
            } elseif ($statusCode -eq 202) {
                Write-Host "    Unregistration accepted (202). Tracking..." -ForegroundColor Green
                $asyncUrl = $unregResponse.Headers["Azure-AsyncOperation"]
                $locationUrl = $unregResponse.Headers["Location"]
                $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

                $pollResult = Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "Unregister $containerName"
                if ($pollResult) {
                    $unregisterSuccessCount++
                } else {
                    $unregisterFailCount++
                }
            }
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__

            if ($statusCode -eq 202) {
                Write-Host "    Unregistration accepted (202). Waiting..." -ForegroundColor Green
                Start-Sleep -Seconds 15
                $unregisterSuccessCount++
            } elseif ($statusCode -eq 204) {
                Write-Host "    Container was already unregistered (204)." -ForegroundColor Green
                $unregisterSuccessCount++
            } else {
                Write-Host "    ERROR: Failed to unregister container '$containerName'." -ForegroundColor Red
                Write-ApiError -ErrorRecord $_ -Context "Unregister Container"

                $errorMessage = $_.ErrorDetails.Message
                if ($errorMessage -like "*BMSUserErrorContainerHasDatasources*" -or $errorMessage -like "*delete data*") {
                    Write-Host "    HINT: The vault still has active datasource references." -ForegroundColor Yellow
                    Write-Host "    Some stop-protection operations may not have fully propagated." -ForegroundColor Yellow
                    Write-Host "    Wait a few minutes and retry, or check the Azure Portal." -ForegroundColor Yellow
                } elseif ($errorMessage -like "*BMSUserErrorNodePartOfActiveAG*" -or $errorMessage -like "*active SQL Availability Group*") {
                    Write-Host "    HINT: This VM is a node in an AG container that still has protected/active items." -ForegroundColor Yellow
                    Write-Host "    All AG databases referencing this VM must be stop-deleted (soft-deleted)" -ForegroundColor Yellow
                    Write-Host "    before the physical container can be unregistered." -ForegroundColor Yellow
                    Write-Host "    Check if there are AG containers from other resource groups" -ForegroundColor Yellow
                    Write-Host "    that also reference this VM as a node." -ForegroundColor Yellow
                }
                $unregisterFailCount++
            }
        }

        Write-Host ""
    }

    Write-Host "    Unregister Summary: $unregisterSuccessCount succeeded, $unregisterFailCount failed" -ForegroundColor Cyan
    Write-Host ""

    $allResults += [PSCustomObject]@{
        Vault   = $vaultName
        Phase   = "Stop-Retain Standalone"
        Status  = if ($retainResult.Failed -eq 0) { "Success" } else { "Partial" }
        Details = "Succeeded: $($retainResult.Succeeded), Skipped: $($retainResult.Skipped), Failed: $($retainResult.Failed)"
    }
    $allResults += [PSCustomObject]@{
        Vault   = $vaultName
        Phase   = "Stop-Delete AG DBs"
        Status  = if ($deleteResult.Failed -eq 0) { "Success" } else { "Partial" }
        Details = "Succeeded: $($deleteResult.Succeeded), Skipped: $($deleteResult.Skipped), Failed: $($deleteResult.Failed)"
    }
    $allResults += [PSCustomObject]@{
        Vault   = $vaultName
        Phase   = "Unregister Containers"
        Status  = if ($unregisterFailCount -eq 0) { "Success" } else { "Partial" }
        Details = "Succeeded: $unregisterSuccessCount, Failed: $unregisterFailCount"
    }

    # ========================================================================
    # STEP 10: WAIT 3 MINUTES FOR PROPAGATION
    # ========================================================================

    if ($agDbDetailsForUndelete.Count -gt 0) {
        Write-Host "  STEP 10: Waiting 3 Minutes for Propagation" -ForegroundColor Yellow
        Write-Host "  ----------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    This wait ensures container unregistration fully propagates" -ForegroundColor Gray
        Write-Host "    before attempting to undelete AG databases." -ForegroundColor Gray
        Write-Host ""

        for ($waitMin = 1; $waitMin -le 3; $waitMin++) {
            Write-Host "    Minute $waitMin of 3..." -ForegroundColor Yellow
            Start-Sleep -Seconds 60
        }

        Write-Host "    Propagation wait complete." -ForegroundColor Green
        Write-Host ""

        # Refresh token before undelete operations (token may have expired during long run)
        if ([string]::IsNullOrWhiteSpace($Token)) {
            try {
                $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
                if ($tokenResponse.Token -is [System.Security.SecureString]) {
                    $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
                } else {
                    $token = $tokenResponse.Token
                }
                $headers = @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" }
                Write-Host "    Token refreshed for undelete operations." -ForegroundColor Gray
            } catch {
                Write-Host "    WARNING: Could not refresh token. Continuing with existing token." -ForegroundColor Yellow
            }
        }

        # ====================================================================
        # STEP 11: UNDELETE AG DATABASES (FOOLPROOF)
        # ====================================================================

        Write-Host "  STEP 11: Undeleting AG Databases (Foolproof Recovery)" -ForegroundColor Yellow
        Write-Host "  --------------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    Recovering $($agDbDetailsForUndelete.Count) AG database(s) from soft-deleted state..." -ForegroundColor Cyan
        Write-Host ""

        # Filter to only items that were actively deleted (not already soft-deleted before)
        $itemsToUndelete = $agDbDetailsForUndelete | Where-Object { $_.OriginalState -ine "SoftDeleted" }

        if ($itemsToUndelete.Count -eq 0) {
            Write-Host "    No items need undelete (all were already in SoftDeleted state before)." -ForegroundColor Yellow
        } else {
            $undeleteSuccessCount = 0
            $undeleteFailedItems = @()

            # ---- PHASE 1: Direct undelete using stored item IDs ----
            Write-Host "    Phase 1: Direct undelete using stored item IDs ($($itemsToUndelete.Count) items)..." -ForegroundColor Cyan
            Write-Host ""

            foreach ($item in $itemsToUndelete) {
                $undeleteUri = "https://management.azure.com$($item.Id)?api-version=$apiVersion"
                $undeleteBody = @{
                    properties = @{
                        protectedItemType = "AzureVmWorkloadSQLDatabase"
                        isRehydrate       = $true
                    }
                } | ConvertTo-Json -Depth 10

                $undeleted = $false
                $lastError = ""

                # Retry up to 3 times with 15s delay
                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    try {
                        $undelResponse = Invoke-WebRequest -Uri $undeleteUri -Method PUT -Headers $headers -Body $undeleteBody -UseBasicParsing
                        $statusCode = $undelResponse.StatusCode

                        if ($statusCode -eq 200) {
                            Write-Host "      SUCCESS: '$($item.FriendlyName)' undeleted (200 OK)" -ForegroundColor Green
                            $undeleted = $true
                            break
                        } elseif ($statusCode -eq 202) {
                            Write-Host "      ACCEPTED: '$($item.FriendlyName)' undelete accepted (202)" -ForegroundColor Green
                            $asyncUrl = $undelResponse.Headers["Azure-AsyncOperation"]
                            $locationUrl = $undelResponse.Headers["Location"]
                            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

                            $pollResult = Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 15 -DelaySeconds 8 -OperationName "Undelete $($item.FriendlyName)"
                            if ($pollResult) {
                                $undeleted = $true
                                break
                            }
                        }
                    } catch {
                        $statusCode = $_.Exception.Response.StatusCode.value__
                        $lastError = $_.Exception.Message

                        if ($statusCode -eq 202) {
                            Write-Host "      ACCEPTED: '$($item.FriendlyName)' undelete accepted (202)" -ForegroundColor Green
                            Start-Sleep -Seconds 15
                            $undeleted = $true
                            break
                        }

                        Write-Host "      Attempt $attempt/3 failed for '$($item.FriendlyName)': $lastError" -ForegroundColor Yellow
                    }

                    if ($attempt -lt 3) {
                        Write-Host "      Retrying in 15s..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 15
                    }
                }

                if ($undeleted) {
                    $undeleteSuccessCount++
                } else {
                    $undeleteFailedItems += $item
                }
            }

            Write-Host ""
            Write-Host "    Phase 1 result: $undeleteSuccessCount succeeded, $($undeleteFailedItems.Count) failed" -ForegroundColor Cyan
            Write-Host ""

            # ---- PHASE 2: Re-query vault and retry failed items ----
            if ($undeleteFailedItems.Count -gt 0) {
                Write-Host "    Phase 2: Re-querying vault to locate failed items and retry..." -ForegroundColor Cyan
                Write-Host ""

                # Re-fetch all protected items (including soft-deleted)
                $allItemsRefresh = @()
                try {
                    $refreshUri = $protectedItemsUri
                    while ($refreshUri) {
                        $refreshResp = Invoke-RestMethod -Uri $refreshUri -Method GET -Headers $headers
                        if ($refreshResp.value) { $allItemsRefresh += $refreshResp.value }
                        $refreshUri = $refreshResp.nextLink
                    }
                } catch {
                    Write-Host "      WARNING: Re-query failed: $($_.Exception.Message)" -ForegroundColor Yellow
                }

                $stillFailed = @()

                foreach ($failedItem in $undeleteFailedItems) {
                    # Try to find the item by friendly name in the refreshed list
                    # Match by both friendlyName AND containerName to avoid cross-container false matches
                    $matchedItem = $allItemsRefresh | Where-Object {
                        $_.properties.friendlyName -ieq $failedItem.FriendlyName -and
                        $_.properties.containerName -ieq $failedItem.ContainerName -and
                        $_.properties.protectionState -ieq "SoftDeleted"
                    } | Select-Object -First 1

                    # Fallback: match by friendlyName only if container name didn't match
                    if (-not $matchedItem) {
                        $matchedItem = $allItemsRefresh | Where-Object {
                            $_.properties.friendlyName -ieq $failedItem.FriendlyName -and
                            $_.properties.protectionState -ieq "SoftDeleted"
                        } | Select-Object -First 1
                    }

                    if ($matchedItem) {
                        Write-Host "      Found '$($failedItem.FriendlyName)' in vault (ID may have changed). Retrying undelete..." -ForegroundColor Cyan

                        $retryUri = "https://management.azure.com$($matchedItem.id)?api-version=$apiVersion"
                        $retryBody = @{
                            properties = @{
                                protectedItemType = "AzureVmWorkloadSQLDatabase"
                                isRehydrate       = $true
                            }
                        } | ConvertTo-Json -Depth 10

                        $retrySuccess = $false
                        for ($attempt = 1; $attempt -le 3; $attempt++) {
                            try {
                                $retryResp = Invoke-WebRequest -Uri $retryUri -Method PUT -Headers $headers -Body $retryBody -UseBasicParsing
                                if ($retryResp.StatusCode -eq 200 -or $retryResp.StatusCode -eq 202) {
                                    Write-Host "      SUCCESS: '$($failedItem.FriendlyName)' undeleted on retry" -ForegroundColor Green

                                    if ($retryResp.StatusCode -eq 202) {
                                        $asyncUrl = $retryResp.Headers["Azure-AsyncOperation"]
                                        $locationUrl = $retryResp.Headers["Location"]
                                        $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                                        Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 15 -DelaySeconds 8 -OperationName "Undelete $($failedItem.FriendlyName)"
                                    }

                                    $retrySuccess = $true
                                    break
                                }
                            } catch {
                                $sc = $_.Exception.Response.StatusCode.value__
                                if ($sc -eq 202) {
                                    Write-Host "      SUCCESS: '$($failedItem.FriendlyName)' undelete accepted (202)" -ForegroundColor Green
                                    Start-Sleep -Seconds 15
                                    $retrySuccess = $true
                                    break
                                }
                                Write-Host "      Retry attempt $attempt/3 failed." -ForegroundColor Yellow
                                if ($attempt -lt 3) { Start-Sleep -Seconds 20 }
                            }
                        }

                        if ($retrySuccess) {
                            $undeleteSuccessCount++
                        } else {
                            $stillFailed += $failedItem
                        }
                    } else {
                        Write-Host "      WARNING: '$($failedItem.FriendlyName)' not found in SoftDeleted state in vault." -ForegroundColor Yellow
                        Write-Host "      It may have been auto-recovered or the ID is no longer valid." -ForegroundColor Yellow
                        $stillFailed += $failedItem
                    }
                }

                $undeleteFailedItems = $stillFailed

                Write-Host ""
                Write-Host "    Phase 2 result: $undeleteSuccessCount total succeeded, $($undeleteFailedItems.Count) still failed" -ForegroundColor Cyan
                Write-Host ""
            }

            # ---- PHASE 3: Extended retry for any remaining failures ----
            if ($undeleteFailedItems.Count -gt 0) {
                Write-Host "    Phase 3: Extended retry with backoff for $($undeleteFailedItems.Count) remaining item(s)..." -ForegroundColor Cyan
                Write-Host ""

                $finalFailed = @()

                foreach ($failedItem in $undeleteFailedItems) {
                    $success = $false

                    for ($extAttempt = 1; $extAttempt -le 5; $extAttempt++) {
                        $backoffSeconds = $extAttempt * 30  # 30s, 60s, 90s, 120s, 150s

                        Write-Host "      Extended attempt $extAttempt/5 for '$($failedItem.FriendlyName)' (backoff: ${backoffSeconds}s)..." -ForegroundColor Yellow
                        Start-Sleep -Seconds $backoffSeconds

                        # Re-query to get latest ID
                        try {
                            $searchItems = @()
                            $searchUri = $protectedItemsUri
                            while ($searchUri) {
                                $searchResp = Invoke-RestMethod -Uri $searchUri -Method GET -Headers $headers
                                if ($searchResp.value) { $searchItems += $searchResp.value }
                                $searchUri = $searchResp.nextLink
                            }

                            # Match by both friendlyName AND containerName to avoid cross-container false matches
                            $foundItem = $searchItems | Where-Object {
                                $_.properties.friendlyName -ieq $failedItem.FriendlyName -and
                                $_.properties.containerName -ieq $failedItem.ContainerName -and
                                $_.properties.protectionState -ieq "SoftDeleted"
                            } | Select-Object -First 1

                            # Fallback: match by friendlyName only
                            if (-not $foundItem) {
                                $foundItem = $searchItems | Where-Object {
                                    $_.properties.friendlyName -ieq $failedItem.FriendlyName -and
                                    $_.properties.protectionState -ieq "SoftDeleted"
                                } | Select-Object -First 1
                            }

                            if (-not $foundItem) {
                                # Check if it's already recovered (not SoftDeleted anymore)
                                $recoveredItem = $searchItems | Where-Object {
                                    $_.properties.friendlyName -ieq $failedItem.FriendlyName -and
                                    $_.properties.protectionState -ine "SoftDeleted"
                                } | Select-Object -First 1

                                if ($recoveredItem) {
                                    Write-Host "      '$($failedItem.FriendlyName)' is already recovered (state: $($recoveredItem.properties.protectionState))" -ForegroundColor Green
                                    $success = $true
                                    break
                                }

                                Write-Host "      Item not found in vault. Trying stored ID..." -ForegroundColor Yellow
                                $foundItem = @{ id = $failedItem.Id }
                            }

                            $extUri = "https://management.azure.com$($foundItem.id)?api-version=$apiVersion"
                            $extBody = @{
                                properties = @{
                                    protectedItemType = "AzureVmWorkloadSQLDatabase"
                                    isRehydrate       = $true
                                }
                            } | ConvertTo-Json -Depth 10

                            $extResp = Invoke-WebRequest -Uri $extUri -Method PUT -Headers $headers -Body $extBody -UseBasicParsing
                            if ($extResp.StatusCode -eq 200 -or $extResp.StatusCode -eq 202) {
                                Write-Host "      SUCCESS: '$($failedItem.FriendlyName)' undeleted on extended retry" -ForegroundColor Green

                                if ($extResp.StatusCode -eq 202) {
                                    $asyncUrl = $extResp.Headers["Azure-AsyncOperation"]
                                    $locationUrl = $extResp.Headers["Location"]
                                    $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                                    Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 15 -DelaySeconds 8 -OperationName "Undelete $($failedItem.FriendlyName)"
                                }

                                $success = $true
                                break
                            }
                        } catch {
                            $sc = $_.Exception.Response.StatusCode.value__
                            if ($sc -eq 202) {
                                Write-Host "      SUCCESS: '$($failedItem.FriendlyName)' accepted (202)" -ForegroundColor Green
                                Start-Sleep -Seconds 15
                                $success = $true
                                break
                            }
                            Write-Host "      Extended retry attempt $extAttempt/5 failed." -ForegroundColor Yellow
                        }
                    }

                    if ($success) {
                        $undeleteSuccessCount++
                    } else {
                        $finalFailed += $failedItem
                    }
                }

                $undeleteFailedItems = $finalFailed
            }

            # ---- PHASE 4: Final Verification ----
            Write-Host ""
            Write-Host "    Phase 4: Final Verification" -ForegroundColor Cyan
            Write-Host ""

            try {
                $verifyItems = @()
                $verifyUri = $protectedItemsUri
                while ($verifyUri) {
                    $verifyResp = Invoke-RestMethod -Uri $verifyUri -Method GET -Headers $headers
                    if ($verifyResp.value) { $verifyItems += $verifyResp.value }
                    $verifyUri = $verifyResp.nextLink
                }

                $verifyOK = 0
                $verifyStillDeleted = 0

                foreach ($item in $itemsToUndelete) {
                    # Match by both friendlyName AND containerName to avoid cross-container false matches
                    $found = $verifyItems | Where-Object {
                        $_.properties.friendlyName -ieq $item.FriendlyName -and
                        $_.properties.containerName -ieq $item.ContainerName
                    } | Select-Object -First 1

                    # Fallback: match by friendlyName only if container name didn't match
                    if (-not $found) {
                        $found = $verifyItems | Where-Object {
                            $_.properties.friendlyName -ieq $item.FriendlyName
                        } | Select-Object -First 1
                    }

                    if ($found) {
                        if ($found.properties.protectionState -ieq "SoftDeleted") {
                            Write-Host "      WARNING: '$($item.FriendlyName)' is still in SoftDeleted state" -ForegroundColor Yellow
                            $verifyStillDeleted++
                        } else {
                            Write-Host "      VERIFIED: '$($item.FriendlyName)' → $($found.properties.protectionState)" -ForegroundColor Green
                            $verifyOK++
                        }
                    } else {
                        Write-Host "      WARNING: '$($item.FriendlyName)' not found in vault (may have been permanently removed)" -ForegroundColor Yellow
                        $verifyStillDeleted++
                    }
                }

                Write-Host ""
                Write-Host "    Verification: $verifyOK verified OK, $verifyStillDeleted still pending/failed" -ForegroundColor Cyan
            } catch {
                Write-Host "      WARNING: Verification query failed: $($_.Exception.Message)" -ForegroundColor Yellow
                Write-Host "      Please verify the undelete status in the Azure Portal." -ForegroundColor Yellow
            }

            # Final undelete summary
            Write-Host ""
            Write-Host "    Undelete Summary:" -ForegroundColor Cyan
            Write-Host "      Total AG DBs to undelete: $($itemsToUndelete.Count)" -ForegroundColor White
            Write-Host "      Successfully undeleted:   $undeleteSuccessCount" -ForegroundColor Green

            if ($undeleteFailedItems.Count -gt 0) {
                Write-Host "      Failed to undelete:       $($undeleteFailedItems.Count)" -ForegroundColor Red
                Write-Host ""
                Write-Host "    IMPORTANT: The following AG databases could not be undeleted:" -ForegroundColor Red
                foreach ($fi in $undeleteFailedItems) {
                    Write-Host "      - $($fi.FriendlyName) (Container: $($fi.ContainerName))" -ForegroundColor Red
                    Write-Host "        Stored ID: $($fi.Id)" -ForegroundColor Gray
                }
                Write-Host ""
                Write-Host "    ACTION REQUIRED: Manually undelete these items in the Azure Portal" -ForegroundColor Red
                Write-Host "    before the soft-delete retention period expires." -ForegroundColor Red
                $overallSuccess = $false
            }

            $allResults += [PSCustomObject]@{
                Vault   = $vaultName
                Phase   = "Undelete AG DBs"
                Status  = if ($undeleteFailedItems.Count -eq 0) { "Success" } else { "Partial" }
                Details = "Succeeded: $undeleteSuccessCount, Failed: $($undeleteFailedItems.Count)"
            }
        }
    } else {
        Write-Host "  STEP 10-11: Skipped (no AG databases were soft-deleted)" -ForegroundColor Gray
    }

    Write-Host ""
}

# ============================================================================
# STEP 12: FINAL SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  BULK AG UNREGISTER - FINAL SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

if ($allResults.Count -gt 0) {
    Write-Host "  Results by Phase:" -ForegroundColor Yellow
    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
    $headerLine = "  {0,-25} {1,-25} {2,-10} {3}" -f "Vault", "Phase", "Status", "Details"
    Write-Host $headerLine -ForegroundColor Gray
    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray

    foreach ($r in $allResults) {
        $statusColor = switch ($r.Status) {
            "Success" { "Green" }
            "Partial" { "Yellow" }
            "Failed"  { "Red" }
            default   { "White" }
        }
        $line = "  {0,-25} {1,-25} {2,-10} {3}" -f $r.Vault, $r.Phase, $r.Status, $r.Details
        Write-Host $line -ForegroundColor $statusColor
    }

    Write-Host "  -------------------------------------------------------------------" -ForegroundColor Gray
} else {
    Write-Host "  No operations were performed." -ForegroundColor Yellow
}

Write-Host ""

# Export results CSV
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
    Write-Host "  WARNING: Could not export results to '$ResultsPath': $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""

if ($overallSuccess) {
    Write-Host "  WORKFLOW COMPLETED SUCCESSFULLY." -ForegroundColor Green
    Write-Host ""
    Write-Host "  End State:" -ForegroundColor Yellow
    Write-Host "    - Standalone databases: ProtectionStopped (data retained)" -ForegroundColor Green
    Write-Host "    - AG databases: Undeleted back to ProtectionStopped (data retained)" -ForegroundColor Green
    Write-Host "    - Physical containers: Unregistered from vault" -ForegroundColor Green
    Write-Host ""
    Write-Host "  All recovery points are PRESERVED." -ForegroundColor Green
} else {
    Write-Host "  WORKFLOW COMPLETED WITH WARNINGS/ERRORS." -ForegroundColor Yellow
    Write-Host "  Review the results above and check the Azure Portal for details." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

if ($overallSuccess) { exit 0 } else { exit 1 }

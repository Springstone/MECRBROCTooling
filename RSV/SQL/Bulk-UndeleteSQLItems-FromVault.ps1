<#
.SYNOPSIS
    Bulk CSV-driven script to undelete (rehydrate) soft-deleted SQL backup items
    in a Recovery Services Vault.

.DESCRIPTION
    Handles the recovery of SQL databases that are in SoftDeleted state
    (stop protection with delete data). Undeletes them back to ProtectionStopped
    state with recovery points preserved.

    Optionally resumes protection by re-applying a backup policy after undelete.

    The CSV must contain at minimum these columns:
      VaultSubscriptionId, VaultResourceGroup, VaultName

    Optional columns:
      VMResourceGroup, VMName   - Filter to specific VM(s). If omitted, all
                                  soft-deleted items in the vault are processed.
      PolicyName                - If provided, resumes protection with this policy
                                  after undelete (re-protects the database).

.PARAMETER CsvPath
    Path to the input CSV file.

.PARAMETER ResultsPath
    Path to export the results CSV. If omitted, results are saved next to the
    input CSV with a machine name and timestamp suffix.

.PARAMETER SkipConfirmation
    Skip all confirmation prompts. Use for automation.

.PARAMETER Token
    Pre-fetched bearer token. When provided, skips authentication.

.PARAMETER WhatIf
    Discover soft-deleted items and display the plan without executing.

.EXAMPLE
    # Undelete all soft-deleted items in vaults listed in CSV
    .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv"

.EXAMPLE
    # Undelete + resume protection with a policy (fully non-interactive)
    .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv" -SkipConfirmation

.EXAMPLE
    # Dry run - discover only
    .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv" -WhatIf

.NOTES
    Author: Azure Backup Script Generator
    Date: March 19, 2026
    API Version: 2025-08-01
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-security-feature-cloud
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the input CSV file.")]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter(Mandatory = $false, HelpMessage = "Path to export the results CSV.")]
    [string]$ResultsPath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip all confirmation prompts.")]
    [switch]$SkipConfirmation,

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
        [int]$DelaySeconds = 8,
        [string]$OperationName = "Operation"
    )

    if ([string]::IsNullOrWhiteSpace($LocationUrl)) {
        Write-Host "      No tracking URL available. Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($DelaySeconds * 3)
        return $true
    }

    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds

        try {
            $statusResponse = Invoke-WebRequest -Uri $LocationUrl -Method GET -Headers $Headers -UseBasicParsing
            if ($statusResponse.StatusCode -eq 200 -or $statusResponse.StatusCode -eq 204) {
                return $true
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                return $true
            }
        }

        $retryCount++
        Write-Host "      Waiting for $OperationName... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
    }

    Write-Host "      WARNING: $OperationName timed out." -ForegroundColor Yellow
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
    Write-Host "      Status Code: $statusCode" -ForegroundColor Red
    Write-Host "      Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red

    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json

        if ($errorJson.error) {
            Write-Host "      Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "      Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch { }
}

# ============================================================================
# DISPLAY BANNER
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Undelete Soft-Deleted SQL Backup Items" -ForegroundColor Cyan
Write-Host "  (Rehydrate items from SoftDeleted → ProtectionStopped)" -ForegroundColor Cyan
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

$requiredColumns = @("VaultSubscriptionId", "VaultResourceGroup", "VaultName")
$csvColumns = $csvData[0].PSObject.Properties.Name

$missingColumns = $requiredColumns | Where-Object { $_ -notin $csvColumns }
if ($missingColumns.Count -gt 0) {
    Write-Host "  ERROR: CSV is missing required column(s): $($missingColumns -join ', ')" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Required columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
    Write-Host "  Optional columns: VMResourceGroup, VMName, PolicyName" -ForegroundColor Gray
    exit 1
}

# Check for optional columns
$hasVMFilter = ($csvColumns -contains "VMResourceGroup") -and ($csvColumns -contains "VMName")
$hasPolicyName = $csvColumns -contains "PolicyName"

# Validate required fields
$validationErrors = @()
$rowNum = 0
foreach ($row in $csvData) {
    $rowNum++
    foreach ($col in $requiredColumns) {
        if ([string]::IsNullOrWhiteSpace($row.$col)) {
            $validationErrors += "  Row $rowNum : Column '$col' is empty"
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
Write-Host "  Total rows:      $($csvData.Count)" -ForegroundColor Gray
Write-Host "  VM filter:       $(if ($hasVMFilter) { 'Yes' } else { 'No (all items in vault)' })" -ForegroundColor Gray
Write-Host "  Resume protect:  $(if ($hasPolicyName) { 'Yes (PolicyName column present)' } else { 'No (undelete only)' })" -ForegroundColor Gray
Write-Host ""

# Group by vault
$vaultGroups = $csvData | Group-Object { "$($_.VaultSubscriptionId)|$($_.VaultResourceGroup)|$($_.VaultName)" }

Write-Host "  Vault(s) to process: $($vaultGroups.Count)" -ForegroundColor Gray
foreach ($vg in $vaultGroups) {
    $sampleRow = $vg.Group[0]
    Write-Host "    - $($sampleRow.VaultName) ($($vg.Count) row(s))" -ForegroundColor White
}
Write-Host ""

if ($WhatIfPreference) {
    Write-Host "  [WhatIf] Mode: Discovery only. No changes will be made." -ForegroundColor Yellow
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
    $rowsInGroup         = $vaultGroup.Group

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "  Processing Vault: $vaultName" -ForegroundColor Cyan
    Write-Host "  Subscription:     $vaultSubscriptionId" -ForegroundColor Gray
    Write-Host "  Resource Group:   $vaultResourceGroup" -ForegroundColor Gray
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host ""

    # ========================================================================
    # STEP 3: DISCOVER SOFT-DELETED ITEMS
    # ========================================================================

    Write-Host "  STEP 3: Discovering Soft-Deleted Items" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------" -ForegroundColor Yellow
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
        }

        Write-Host "    Total protected SQL databases in vault: $($allProtectedItems.Count)" -ForegroundColor Gray
    } catch {
        Write-Host "    ERROR: Failed to list protected items." -ForegroundColor Red
        Write-ApiError -ErrorRecord $_ -Context "List Protected Items"
        $overallSuccess = $false

        $allResults += [PSCustomObject]@{
            Vault   = $vaultName
            Phase   = "Discovery"
            Status  = "Failed"
            Details = "Could not list protected items"
        }
        continue
    }

    # Filter to soft-deleted items only
    $softDeletedItems = @($allProtectedItems | Where-Object {
        $_.properties.isScheduledForDeferredDelete -eq $true -or
        $_.properties.protectionState -ieq "SoftDeleted"
    })

    Write-Host "    Soft-deleted items found: $($softDeletedItems.Count)" -ForegroundColor $(if ($softDeletedItems.Count -gt 0) { "Yellow" } else { "Green" })

    # Apply VM filter if VMResourceGroup and VMName columns are provided and non-empty
    $vmFilters = @()
    if ($hasVMFilter) {
        foreach ($row in $rowsInGroup) {
            if (-not [string]::IsNullOrWhiteSpace($row.VMResourceGroup) -and -not [string]::IsNullOrWhiteSpace($row.VMName)) {
                $vmFilters += @{
                    RG   = $row.VMResourceGroup
                    Name = $row.VMName
                    Policy = if ($hasPolicyName -and -not [string]::IsNullOrWhiteSpace($row.PolicyName)) { $row.PolicyName } else { $null }
                }
            }
        }
    }

    # Get the PolicyName from the first row if available and no VM filter
    $defaultPolicy = $null
    if ($hasPolicyName -and $vmFilters.Count -eq 0) {
        $defaultPolicy = $rowsInGroup[0].PolicyName
    }

    if ($vmFilters.Count -gt 0) {
        Write-Host "    VM filter applied: $($vmFilters.Count) VM(s)" -ForegroundColor Gray
        foreach ($vf in $vmFilters) {
            Write-Host "      - $($vf.Name) @ $($vf.RG)$(if ($vf.Policy) { " → Policy: $($vf.Policy)" })" -ForegroundColor Gray
        }

        $filteredItems = @()
        foreach ($item in $softDeletedItems) {
            $itemContainer = if ($item.properties.containerName) { $item.properties.containerName.ToLower() } else { "" }

            foreach ($vf in $vmFilters) {
                $expectedContainer = "VMAppContainer;Compute;$($vf.RG);$($vf.Name)".ToLower()
                if ($itemContainer -ieq $expectedContainer) {
                    # Attach the policy to this item for later use
                    $item | Add-Member -NotePropertyName "_policyToApply" -NotePropertyValue $vf.Policy -Force
                    $filteredItems += $item
                    break
                }
            }
        }

        # Also check AG containers for filtered VMs
        foreach ($item in $softDeletedItems) {
            if ($item -in $filteredItems) { continue }
            $itemContainer = if ($item.properties.containerName) { $item.properties.containerName } else { "" }
            if ($itemContainer -imatch "SQLAGWorkLoadContainer") {
                # Check if any filtered VM is a node of this AG container
                $agContainerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$itemContainer`?api-version=$apiVersion"
                try {
                    $agContainer = Invoke-RestMethod -Uri $agContainerUri -Method GET -Headers $headers
                    if ($agContainer.properties.extendedInfo.nodesList) {
                        foreach ($node in $agContainer.properties.extendedInfo.nodesList) {
                            $nodeRG = ""
                            $nodeVM = ""
                            if ($node.sourceResourceId -match "/resourceGroups/([^/]+)/") { $nodeRG = $Matches[1] }
                            if ($node.sourceResourceId -match "/virtualMachines/([^/]+)$") { $nodeVM = $Matches[1] }

                            foreach ($vf in $vmFilters) {
                                if ($nodeVM -ieq $vf.Name -and $nodeRG -ieq $vf.RG) {
                                    $item | Add-Member -NotePropertyName "_policyToApply" -NotePropertyValue $vf.Policy -Force
                                    $filteredItems += $item
                                    break
                                }
                            }
                            if ($item -in $filteredItems) { break }
                        }
                    }
                } catch { }
            }
        }

        $softDeletedItems = $filteredItems
        Write-Host "    After VM filter: $($softDeletedItems.Count) soft-deleted item(s)" -ForegroundColor Gray
    } else {
        # Attach default policy to all items
        foreach ($item in $softDeletedItems) {
            $item | Add-Member -NotePropertyName "_policyToApply" -NotePropertyValue $defaultPolicy -Force
        }
    }

    if ($softDeletedItems.Count -eq 0) {
        Write-Host ""
        Write-Host "    No soft-deleted items to process for this vault." -ForegroundColor Green
        Write-Host ""

        $allResults += [PSCustomObject]@{
            Vault   = $vaultName
            Phase   = "Discovery"
            Status  = "Success"
            Details = "No soft-deleted items found"
        }
        continue
    }

    Write-Host ""

    # ========================================================================
    # STEP 4: DISPLAY PLAN & CONFIRM
    # ========================================================================

    Write-Host "  STEP 4: Execution Plan" -ForegroundColor Yellow
    Write-Host "  ------------------------" -ForegroundColor Yellow
    Write-Host ""

    Write-Host "    SOFT-DELETED ITEMS TO UNDELETE:" -ForegroundColor Magenta
    Write-Host ""

    $groupedByContainer = $softDeletedItems | Group-Object { $_.properties.containerName }
    foreach ($grp in $groupedByContainer) {
        Write-Host "      Container: $($grp.Name)" -ForegroundColor White
        foreach ($db in $grp.Group) {
            $policy = $db._policyToApply
            $policyInfo = if ($policy) { " → re-protect with '$policy'" } else { "" }
            Write-Host "        - $($db.properties.friendlyName) [SoftDeleted]$policyInfo" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    $itemsWithPolicy = @($softDeletedItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_._policyToApply) })
    Write-Host "    WORKFLOW:" -ForegroundColor Cyan
    Write-Host "      1. Undelete $($softDeletedItems.Count) soft-deleted item(s)" -ForegroundColor White
    if ($itemsWithPolicy.Count -gt 0) {
        Write-Host "      2. Resume protection for $($itemsWithPolicy.Count) item(s) with specified policy" -ForegroundColor White
    }
    Write-Host ""

    if ($WhatIfPreference) {
        Write-Host "    [WhatIf] Dry run complete for vault '$vaultName'. No changes made." -ForegroundColor Yellow
        Write-Host ""

        $allResults += [PSCustomObject]@{
            Vault   = $vaultName
            Phase   = "WhatIf"
            Status  = "DryRun"
            Details = "$($softDeletedItems.Count) soft-deleted items found"
        }
        continue
    }

    if (-not $SkipConfirmation) {
        Write-Host "    Proceed with undeleting $($softDeletedItems.Count) item(s)? [Y/N, default: Y]" -ForegroundColor Cyan
        $confirm = Read-Host "    "
        if ($confirm -ieq 'N') {
            Write-Host "    Aborted by user." -ForegroundColor Yellow
            exit 0
        }
        Write-Host ""
    }

    # ========================================================================
    # STEP 5: UNDELETE SOFT-DELETED ITEMS
    # ========================================================================

    Write-Host "  STEP 5: Undeleting Soft-Deleted Items" -ForegroundColor Yellow
    Write-Host "  ----------------------------------------" -ForegroundColor Yellow
    Write-Host ""

    $undeleteSuccessCount = 0
    $undeleteFailedItems = @()

    foreach ($item in $softDeletedItems) {
        $dbName = $item.properties.friendlyName
        $containerName = $item.properties.containerName
        $undeleteUri = "https://management.azure.com$($item.id)?api-version=$apiVersion"

        $undeleteBody = @{
            properties = @{
                protectedItemType = "AzureVmWorkloadSQLDatabase"
                isRehydrate       = $true
            }
        } | ConvertTo-Json -Depth 10

        $undeleted = $false

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $undelResponse = Invoke-WebRequest -Uri $undeleteUri -Method PUT -Headers $headers -Body $undeleteBody -UseBasicParsing
                $statusCode = $undelResponse.StatusCode

                if ($statusCode -eq 200) {
                    Write-Host "    SUCCESS: '$dbName' undeleted (200 OK)" -ForegroundColor Green
                    $undeleted = $true
                    break
                } elseif ($statusCode -eq 202) {
                    Write-Host "    ACCEPTED: '$dbName' undelete accepted (202)" -ForegroundColor Green
                    $asyncUrl = $undelResponse.Headers["Azure-AsyncOperation"]
                    $locationUrl = $undelResponse.Headers["Location"]
                    $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

                    $pollResult = Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 15 -DelaySeconds 8 -OperationName "Undelete $dbName"
                    if ($pollResult) {
                        Write-Host "    SUCCESS: '$dbName' undelete completed" -ForegroundColor Green
                        $undeleted = $true
                        break
                    }
                }
            } catch {
                $statusCode = $_.Exception.Response.StatusCode.value__

                if ($statusCode -eq 202) {
                    Write-Host "    ACCEPTED: '$dbName' undelete accepted (202)" -ForegroundColor Green
                    Start-Sleep -Seconds 15
                    $undeleted = $true
                    break
                }

                Write-Host "    Attempt $attempt/3 failed for '$dbName'" -ForegroundColor Yellow
                Write-ApiError -ErrorRecord $_ -Context "Undelete $dbName"
            }

            if ($attempt -lt 3) {
                Write-Host "    Retrying in 15s..." -ForegroundColor Yellow
                Start-Sleep -Seconds 15
            }
        }

        if ($undeleted) {
            $undeleteSuccessCount++
        } else {
            Write-Host "    FAILED: '$dbName' could not be undeleted after 3 attempts" -ForegroundColor Red
            $undeleteFailedItems += $item
        }
    }

    Write-Host ""
    Write-Host "    Undelete Summary: $undeleteSuccessCount succeeded, $($undeleteFailedItems.Count) failed" -ForegroundColor Cyan
    Write-Host ""

    $allResults += [PSCustomObject]@{
        Vault   = $vaultName
        Phase   = "Undelete"
        Status  = if ($undeleteFailedItems.Count -eq 0) { "Success" } else { "Partial" }
        Details = "Succeeded: $undeleteSuccessCount, Failed: $($undeleteFailedItems.Count)"
    }

    if ($undeleteFailedItems.Count -gt 0) {
        $overallSuccess = $false
        Write-Host "    FAILED ITEMS:" -ForegroundColor Red
        foreach ($fi in $undeleteFailedItems) {
            Write-Host "      - $($fi.properties.friendlyName) (Container: $($fi.properties.containerName))" -ForegroundColor Red
        }
        Write-Host ""
    }

    # ========================================================================
    # STEP 6: RESUME PROTECTION (OPTIONAL)
    # ========================================================================

    $itemsToReprotect = @($softDeletedItems | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_._policyToApply) -and
        $_ -notin $undeleteFailedItems
    })

    if ($itemsToReprotect.Count -gt 0) {
        Write-Host "  STEP 6: Resuming Protection" -ForegroundColor Yellow
        Write-Host "  ------------------------------" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "    Waiting 30 seconds for undelete operations to propagate..." -ForegroundColor Cyan
        Start-Sleep -Seconds 30
        Write-Host ""

        # Resolve policy IDs
        $policyCache = @{}
        $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersion"

        try {
            $policiesResp = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
            foreach ($p in $policiesResp.value) {
                $policyCache[$p.name.ToLower()] = $p.id
            }
        } catch {
            Write-Host "    ERROR: Could not list policies. Skipping resume protection." -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "List Policies"

            $allResults += [PSCustomObject]@{
                Vault   = $vaultName
                Phase   = "Resume Protection"
                Status  = "Failed"
                Details = "Could not list backup policies"
            }
            $overallSuccess = $false
            continue
        }

        $reprotectSuccess = 0
        $reprotectFail = 0

        foreach ($item in $itemsToReprotect) {
            $dbName = $item.properties.friendlyName
            $policyName = $item._policyToApply
            $policyId = $policyCache[$policyName.ToLower()]

            if (-not $policyId) {
                Write-Host "    SKIPPED: '$dbName' - policy '$policyName' not found in vault" -ForegroundColor Yellow
                $reprotectFail++
                continue
            }

            # Re-query to get the updated item (it should now be in ProtectionStopped)
            $refreshUri = "https://management.azure.com$($item.id)?api-version=$apiVersion"
            try {
                $refreshedItem = Invoke-RestMethod -Uri $refreshUri -Method GET -Headers $headers
                if ($refreshedItem.properties.protectionState -ieq "SoftDeleted") {
                    Write-Host "    SKIPPED: '$dbName' - still in SoftDeleted state (undelete may not have propagated)" -ForegroundColor Yellow
                    $reprotectFail++
                    continue
                }
            } catch {
                # Item may have a new ID after undelete, proceed with stored ID
            }

            $reprotectUri = "https://management.azure.com$($item.id)?api-version=$apiVersion"
            $reprotectBody = @{
                properties = @{
                    protectedItemType = "AzureVmWorkloadSQLDatabase"
                    policyId          = $policyId
                    sourceResourceId  = $item.properties.sourceResourceId
                }
            } | ConvertTo-Json -Depth 10

            Write-Host "    Resuming protection: '$dbName' with policy '$policyName'..." -ForegroundColor Cyan

            try {
                $rpResp = Invoke-WebRequest -Uri $reprotectUri -Method PUT -Headers $headers -Body $reprotectBody -UseBasicParsing
                if ($rpResp.StatusCode -eq 200 -or $rpResp.StatusCode -eq 202) {
                    Write-Host "    SUCCESS: '$dbName' protection resumed ($($rpResp.StatusCode))" -ForegroundColor Green

                    if ($rpResp.StatusCode -eq 202) {
                        $asyncUrl = $rpResp.Headers["Azure-AsyncOperation"]
                        $locationUrl = $rpResp.Headers["Location"]
                        $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                        Wait-ForAsyncOperation -LocationUrl $trackingUrl -Headers $headers -MaxRetries 15 -DelaySeconds 8 -OperationName "Resume $dbName"
                    }

                    $reprotectSuccess++
                }
            } catch {
                $sc = $_.Exception.Response.StatusCode.value__
                if ($sc -eq 202) {
                    Write-Host "    SUCCESS: '$dbName' resume accepted (202)" -ForegroundColor Green
                    $reprotectSuccess++
                } else {
                    Write-Host "    FAILED: '$dbName'" -ForegroundColor Red
                    Write-ApiError -ErrorRecord $_ -Context "Resume Protection"
                    $reprotectFail++
                }
            }
        }

        Write-Host ""
        Write-Host "    Resume Protection Summary: $reprotectSuccess succeeded, $reprotectFail failed" -ForegroundColor Cyan
        Write-Host ""

        $allResults += [PSCustomObject]@{
            Vault   = $vaultName
            Phase   = "Resume Protection"
            Status  = if ($reprotectFail -eq 0) { "Success" } else { "Partial" }
            Details = "Succeeded: $reprotectSuccess, Failed: $reprotectFail"
        }

        if ($reprotectFail -gt 0) {
            $overallSuccess = $false
        }
    } else {
        Write-Host "  STEP 6: Resume Protection - Skipped (no PolicyName specified or all items failed undelete)" -ForegroundColor Gray
        Write-Host ""
    }

    # ========================================================================
    # STEP 7: VERIFICATION
    # ========================================================================

    Write-Host "  STEP 7: Verification" -ForegroundColor Yellow
    Write-Host "  -----------------------" -ForegroundColor Yellow
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

        foreach ($item in $softDeletedItems) {
            $found = $verifyItems | Where-Object {
                $_.properties.friendlyName -ieq $item.properties.friendlyName -and
                $_.properties.containerName -ieq $item.properties.containerName
            } | Select-Object -First 1

            if (-not $found) {
                $found = $verifyItems | Where-Object {
                    $_.properties.friendlyName -ieq $item.properties.friendlyName
                } | Select-Object -First 1
            }

            if ($found) {
                if ($found.properties.isScheduledForDeferredDelete -eq $true -or $found.properties.protectionState -ieq "SoftDeleted") {
                    Write-Host "    WARNING: '$($item.properties.friendlyName)' is still SoftDeleted" -ForegroundColor Yellow
                    $verifyStillDeleted++
                } else {
                    Write-Host "    VERIFIED: '$($item.properties.friendlyName)' → $($found.properties.protectionState)" -ForegroundColor Green
                    $verifyOK++
                }
            } else {
                Write-Host "    WARNING: '$($item.properties.friendlyName)' not found in vault" -ForegroundColor Yellow
                $verifyStillDeleted++
            }
        }

        Write-Host ""
        Write-Host "    Verification: $verifyOK OK, $verifyStillDeleted still pending/failed" -ForegroundColor Cyan
    } catch {
        Write-Host "    WARNING: Verification query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "    Please verify in the Azure Portal." -ForegroundColor Yellow
    }

    Write-Host ""
}

# ============================================================================
# STEP 8: FINAL SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  BULK UNDELETE - FINAL SUMMARY" -ForegroundColor Cyan
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
            "DryRun"  { "Cyan" }
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
    Write-Host "    - Undeleted items: ProtectionStopped (data retained)" -ForegroundColor Green
    if ($itemsToReprotect.Count -gt 0) {
        Write-Host "    - Re-protected items: Protected (backup resumed)" -ForegroundColor Green
    }
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

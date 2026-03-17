<#
.SYNOPSIS
    Batch stop backup protection (retain data) for Azure IaaS VMs using CSV input.

.DESCRIPTION
    Reads a CSV file with columns: VaultId, VmId
    For each row, verifies the VM is currently protected and stops protection while
    retaining existing backup data via Azure Backup REST API.

    After stop-protection-with-retain-data:
    - No new backups will be taken for this VM.
    - All existing recovery points are preserved and can be used for restore.
    - The VM remains listed in the vault as a stopped-protection item.
    - Protection can be resumed later by re-associating a backup policy.

    CSV Format Example:
      VaultId,VmId
      /subscriptions/.../resourceGroups/.../providers/Microsoft.RecoveryServices/vaults/myVault,/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/myVM

.PARAMETER CsvPath
    Path to the CSV file containing VaultId and VmId columns.

.EXAMPLE
    .\Bulk-Stop-IaaSVM-Protection-FromCSV.ps1 -CsvPath "C:\input.csv"

.NOTES
    Author: AFS Backup Expert
    Date: March 17, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms#stop-protection-but-retain-existing-data
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath
)

# ============================================================================
# VALIDATE CSV INPUT
# ============================================================================

if (-not (Test-Path -Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

$csvData = Import-Csv -Path $CsvPath

if ($csvData.Count -eq 0) {
    Write-Host "ERROR: CSV file is empty." -ForegroundColor Red
    exit 1
}

$requiredColumns = @("VaultId", "VmId")
$csvColumns = $csvData[0].PSObject.Properties.Name
foreach ($col in $requiredColumns) {
    if ($col -notin $csvColumns) {
        Write-Host "ERROR: CSV is missing required column: $col" -ForegroundColor Red
        Write-Host "Required columns: $($requiredColumns -join ', ')" -ForegroundColor Yellow
        exit 1
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Batch Stop IaaS VM Protection (Retain Data) from CSV" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Rows to process: $($csvData.Count)" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# CONFIRMATION
# ============================================================================

Write-Host "WARNING: This will STOP BACKUP PROTECTION for $($csvData.Count) VM(s)." -ForegroundColor Yellow
Write-Host "  - No new backups will be taken after stop-protection." -ForegroundColor Gray
Write-Host "  - Existing recovery points will be RETAINED." -ForegroundColor Gray
Write-Host "  - Protection can be resumed later." -ForegroundColor Gray
Write-Host ""
Write-Host "Continue? (yes/no):" -ForegroundColor Cyan
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
    $tokenResult = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    if ($tokenResult.Token -is [System.Security.SecureString]) {
        $token = $tokenResult.Token | ConvertFrom-SecureString -AsPlainText
    } else {
        $token = $tokenResult.Token
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
        Write-Host "ERROR: Failed to authenticate. Run Connect-AzAccount or az login first." -ForegroundColor Red
        exit 1
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# HELPER: PARSE RESOURCE ID
# ============================================================================

function Parse-ResourceId {
    param([string]$ResourceId)

    $parts = $ResourceId.Trim().TrimStart("/").Split("/")
    $result = @{}

    for ($i = 0; $i -lt $parts.Count - 1; $i += 2) {
        $result[$parts[$i]] = $parts[$i + 1]
    }
    return $result
}

# ============================================================================
# PROCESS EACH ROW
# ============================================================================

$apiVersion = "2019-05-13"

$summary = @()
$rowNumber = 0

foreach ($row in $csvData) {
    $rowNumber++
    $vaultId = $row.VaultId.Trim()
    $vmId    = $row.VmId.Trim()

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "  Processing Row $rowNumber / $($csvData.Count)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    # --- Parse Vault ID ---
    $vaultParts = Parse-ResourceId -ResourceId $vaultId
    $vaultSubscriptionId = $vaultParts["subscriptions"]
    $vaultResourceGroup  = $vaultParts["resourceGroups"]
    $vaultName           = $vaultParts["vaults"]

    if (-not $vaultSubscriptionId -or -not $vaultResourceGroup -or -not $vaultName) {
        Write-Host "  ERROR: Could not parse VaultId: $vaultId" -ForegroundColor Red
        $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmId; Status = "FAILED"; Detail = "Invalid VaultId" }
        continue
    }

    # --- Parse VM ID ---
    $vmParts = Parse-ResourceId -ResourceId $vmId
    $vmSubscriptionId = $vmParts["subscriptions"]
    $vmResourceGroup  = $vmParts["resourceGroups"]
    $vmName           = $vmParts["virtualMachines"]

    if (-not $vmSubscriptionId -or -not $vmResourceGroup -or -not $vmName) {
        Write-Host "  ERROR: Could not parse VmId: $vmId" -ForegroundColor Red
        $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmId; Status = "FAILED"; Detail = "Invalid VmId" }
        continue
    }

    Write-Host "  Vault:  $vaultName (RG: $vaultResourceGroup, Sub: $vaultSubscriptionId)" -ForegroundColor Gray
    Write-Host "  VM:     $vmName (RG: $vmResourceGroup, Sub: $vmSubscriptionId)" -ForegroundColor Gray

    # --- Construct container / protected item names ---
    $containerName     = "iaasvmcontainer;iaasvmcontainerv2;$vmResourceGroup;$vmName"
    $protectedItemName = "vm;iaasvmcontainerv2;$vmResourceGroup;$vmName"

    # ------------------------------------------------------------------
    # STEP A: Check if VM is currently protected
    # ------------------------------------------------------------------

    Write-Host "  Checking protection status..." -ForegroundColor Cyan

    $listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureIaasVM'"

    $matchingItem = $null

    try {
        $protectedItemsResponse = Invoke-RestMethod -Uri $listProtectedItemsUri -Method GET -Headers $headers

        if ($protectedItemsResponse.value -and $protectedItemsResponse.value.Count -gt 0) {
            # Find matching item by friendly name and source resource ID
            $matchingItem = $protectedItemsResponse.value | Where-Object {
                $_.properties.friendlyName -eq $vmName -and
                $_.properties.sourceResourceId -eq $vmId
            }

            # Fallback: match by friendly name and resource group
            if (-not $matchingItem) {
                $matchingItem = $protectedItemsResponse.value | Where-Object {
                    $_.properties.friendlyName -eq $vmName -and
                    $_.properties.containerName -match $vmResourceGroup
                }
            }

            if ($matchingItem) {
                if ($matchingItem -is [array]) {
                    $matchingItem = $matchingItem[0]
                }

                # Extract actual container and protected item names from the ID
                if ($matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
                    $containerName = $matches[1]
                    $protectedItemName = $matches[2]
                }

                Write-Host "  Found: $vmName (State: $($matchingItem.properties.protectionState), Policy: $($matchingItem.properties.policyName))" -ForegroundColor Green

                # Check if already stopped
                if ($matchingItem.properties.protectionState -eq "ProtectionStopped") {
                    Write-Host "  ALREADY STOPPED — skipping" -ForegroundColor Yellow
                    $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "ALREADY_STOPPED"; Detail = "Protection already stopped" }
                    continue
                }
            } else {
                Write-Host "  ERROR: VM '$vmName' not found in vault '$vaultName'" -ForegroundColor Red
                $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "FAILED"; Detail = "VM not found in vault" }
                continue
            }
        } else {
            Write-Host "  ERROR: No protected IaaS VMs found in vault '$vaultName'" -ForegroundColor Red
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "FAILED"; Detail = "No VMs in vault" }
            continue
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Host "  ERROR: Failed to query protected items (HTTP $statusCode)" -ForegroundColor Red
        $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "FAILED"; Detail = "Query failed - HTTP $statusCode" }
        continue
    }

    # ------------------------------------------------------------------
    # STEP B: Stop protection (retain data)
    # ------------------------------------------------------------------

    Write-Host "  Stopping backup protection (retain data)..." -ForegroundColor Cyan

    $protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersion"

    $stopProtectionBody = @{
        properties = @{
            protectionState  = "ProtectionStopped"
            sourceResourceId = $vmId
        }
    } | ConvertTo-Json -Depth 10

    try {
        $stopResponse = Invoke-WebRequest -Uri $protectedItemUri -Method PUT -Headers $headers -Body $stopProtectionBody -UseBasicParsing
        $statusCode = $stopResponse.StatusCode

        if ($statusCode -eq 200) {
            Write-Host "  PROTECTION STOPPED (200 OK)" -ForegroundColor Green
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "STOPPED"; Detail = "Immediate success" }
        } elseif ($statusCode -eq 202) {
            Write-Host "  Stop-protection request accepted (202), tracking..." -ForegroundColor Green

            $asyncUrl    = $stopResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $stopResponse.Headers["Location"]
            $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }

            $opResult = "ACCEPTED"
            if ($trackingUrl) {
                $maxRetries = 30
                $retryCount = 0
                $operationCompleted = $false

                while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                    Start-Sleep -Seconds 10
                    try {
                        $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers
                        $opStatus = if ($opResponse.status) { $opResponse.status } elseif ($opResponse.properties.protectionState) { $opResponse.properties.protectionState } else { $null }

                        if ($opStatus -eq "Succeeded" -or $opStatus -eq "ProtectionStopped") {
                            $operationCompleted = $true
                            $opResult = "STOPPED"
                            Write-Host "  PROTECTION STOPPED (Status: $opStatus)" -ForegroundColor Green
                        } else {
                            $retryCount++
                            Write-Host "  Waiting... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                        }
                    } catch {
                        $retryCount++
                    }
                }

                if (-not $operationCompleted) {
                    Write-Host "  Operation still in progress — verify in Azure Portal" -ForegroundColor Yellow
                    $opResult = "IN_PROGRESS"
                }
            }
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = $opResult; Detail = "Retain data" }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "  Stop-protection request accepted (202)" -ForegroundColor Green
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "ACCEPTED"; Detail = "Check portal for status" }
        } else {
            $errorMessage = $_.Exception.Message
            try {
                $errorStream = $_.Exception.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($errorStream)
                $errorBody = $reader.ReadToEnd() | ConvertFrom-Json
                $errorMessage = $errorBody.error.message
            } catch {}

            Write-Host "  FAILED (HTTP $statusCode): $errorMessage" -ForegroundColor Red
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "FAILED"; Detail = "HTTP $statusCode - $errorMessage" }
        }
    }
}

# ============================================================================
# SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  BATCH STOP-PROTECTION SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$summary | Format-Table -Property Row, VM, Status, Detail -AutoSize

$stopped = ($summary | Where-Object { $_.Status -in @("STOPPED", "ALREADY_STOPPED") }).Count
$failed  = ($summary | Where-Object { $_.Status -eq "FAILED" }).Count
$pending = ($summary | Where-Object { $_.Status -in @("ACCEPTED", "IN_PROGRESS") }).Count

Write-Host "  Total: $($summary.Count)  |  Stopped: $stopped  |  Pending: $pending  |  Failed: $failed" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Note: Backup data has been RETAINED for all stopped VMs." -ForegroundColor Yellow
Write-Host "  - Existing recovery points are still available for restore." -ForegroundColor Gray
Write-Host "  - No new backups will be taken." -ForegroundColor Gray
Write-Host "  - Protection can be resumed by re-associating a backup policy." -ForegroundColor Gray
Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

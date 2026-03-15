<#
.SYNOPSIS
    Batch-protect Azure IaaS VMs to Recovery Services Vaults using CSV input.

.DESCRIPTION
    Reads a CSV file with columns: VaultId, VmId, PolicyName
    For each row, checks if the VM is already protected and enables protection if not.

    CSV Format Example:
      VaultId,VmId,PolicyName
      /subscriptions/.../resourceGroups/.../providers/Microsoft.RecoveryServices/vaults/myVault,/subscriptions/.../resourceGroups/.../providers/Microsoft.Compute/virtualMachines/myVM,DefaultPolicy

.PARAMETER CsvPath
    Path to the CSV file containing VaultId, VmId, and PolicyName columns.

.EXAMPLE
    .\Protect-IaaSVM-FromCSV.ps1 -CsvPath "C:\input.csv"
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

$requiredColumns = @("VaultId", "VmId", "PolicyName")
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
Write-Host "  Batch Protect IaaS VMs from CSV" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Rows to process: $($csvData.Count)" -ForegroundColor Cyan
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

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

$apiVersion = "2016-12-01"
$apiVersionProtection = "2019-05-13"

$summary = @()
$rowNumber = 0

foreach ($row in $csvData) {
    $rowNumber++
    $vaultId   = $row.VaultId.Trim()
    $vmId      = $row.VmId.Trim()
    $policyName = $row.PolicyName.Trim()

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
    Write-Host "  Policy: $policyName" -ForegroundColor Gray

    # --- Construct container / protected item names ---
    $containerName     = "iaasvmcontainer;iaasvmcontainerv2;$vmResourceGroup;$vmName"
    $protectedItemName = "vm;iaasvmcontainerv2;$vmResourceGroup;$vmName"
    $policyId          = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$policyName"

    # ------------------------------------------------------------------
    # STEP A: Check if VM is already protected
    # ------------------------------------------------------------------

    Write-Host "  Checking protection status..." -ForegroundColor Cyan

    $protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"

    $isAlreadyProtected = $false

    try {
        $protectedItemResponse = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers

        if ($protectedItemResponse -and $protectedItemResponse.properties) {
            $isAlreadyProtected = $true
            $state = $protectedItemResponse.properties.protectionState
            Write-Host "  ALREADY PROTECTED (State: $state, Policy: $($protectedItemResponse.properties.policyName))" -ForegroundColor Green
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "ALREADY_PROTECTED"; Detail = "State=$state, Policy=$($protectedItemResponse.properties.policyName)" }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Host "  VM is not protected — will enable protection" -ForegroundColor Yellow
        } else {
            Write-Host "  Could not determine status (HTTP $statusCode), will attempt protection" -ForegroundColor Yellow
        }
    }

    if ($isAlreadyProtected) {
        continue
    }

    # ------------------------------------------------------------------
    # STEP B: Enable protection
    # ------------------------------------------------------------------

    Write-Host "  Enabling backup protection..." -ForegroundColor Cyan

    $enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"

    $protectionBody = @{
        properties = @{
            protectedItemType = "Microsoft.Compute/virtualMachines"
            sourceResourceId  = $vmId
            policyId          = $policyId
        }
    } | ConvertTo-Json -Depth 10

    try {
        $protectionResponse = Invoke-WebRequest -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody -UseBasicParsing
        $statusCode = $protectionResponse.StatusCode

        if ($statusCode -eq 200) {
            Write-Host "  PROTECTION ENABLED (200 OK)" -ForegroundColor Green
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = "PROTECTED"; Detail = "Immediate success" }
        } elseif ($statusCode -eq 202) {
            Write-Host "  Protection request accepted (202), tracking..." -ForegroundColor Green

            $asyncUrl    = $protectionResponse.Headers["Azure-AsyncOperation"]
            $locationUrl = $protectionResponse.Headers["Location"]
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

                        if ($opStatus -in @("Succeeded", "Protected", "IRPending")) {
                            $operationCompleted = $true
                            $opResult = "PROTECTED"
                            Write-Host "  PROTECTION ENABLED (Status: $opStatus)" -ForegroundColor Green
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
            $summary += [PSCustomObject]@{ Row = $rowNumber; VM = $vmName; Status = $opResult; Detail = "Policy=$policyName" }
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__

        if ($statusCode -eq 202) {
            Write-Host "  Protection request accepted (202)" -ForegroundColor Green
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
Write-Host "  BATCH PROCESSING SUMMARY" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$summary | Format-Table -Property Row, VM, Status, Detail -AutoSize

$protected = ($summary | Where-Object { $_.Status -in @("PROTECTED", "ALREADY_PROTECTED") }).Count
$failed    = ($summary | Where-Object { $_.Status -eq "FAILED" }).Count
$pending   = ($summary | Where-Object { $_.Status -in @("ACCEPTED", "IN_PROGRESS") }).Count

Write-Host "  Total: $($summary.Count)  |  Protected: $protected  |  Pending: $pending  |  Failed: $failed" -ForegroundColor Cyan
Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

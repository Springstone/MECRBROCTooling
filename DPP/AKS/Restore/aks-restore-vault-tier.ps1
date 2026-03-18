<#
.SYNOPSIS
    AKS Restore from Vault Tier (Cross-Region / Vault Region Restore)

.NOTES
    TROUBLESHOOTING - If failures appear to be caused by Azure CLI issues (e.g. unknown commands,
    missing parameters, or extension errors), try the following steps:

    1. Upgrade the Azure CLI to the latest version:
         az upgrade

    2. Remove and reinstall the aks-preview extension:
         az extension remove --name aks-preview
         az extension add --name aks-preview

    3. Re-run the script after the above steps.
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Azure Subscription ID")]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group containing the Backup Vault")]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Backup Vault")]
    [string]$VaultName,

    [Parameter(Mandatory = $true, HelpMessage = "Backup Instance name in the vault")]
    [string]$BackupInstanceName,

    [Parameter(Mandatory = $true, HelpMessage = "ARM Resource ID of the target AKS cluster for restore")]
    [string]$TargetClusterId,

    [Parameter(Mandatory = $true, HelpMessage = "ARM Resource ID of the staging resource group")]
    [string]$StagingResourceGroupId,

    [Parameter(Mandatory = $true, HelpMessage = "ARM Resource ID of the staging storage account")]
    [string]$StagingStorageAccountId,

    [Parameter(Mandatory = $false, HelpMessage = "Recovery Point ID to restore from. If not specified, uses the latest.")]
    [string]$RecoveryPointId,

    [Parameter(Mandatory = $false, HelpMessage = "Namespace mapping as JSON string")]
    [string]$NamespaceMappingJson = '{}',

    [Parameter(Mandatory = $false, HelpMessage = "Conflict policy: Skip or Patch")]
    [ValidateSet("Skip", "Patch")]
    [string]$ConflictPolicy = "Skip",

    [Parameter(Mandatory = $false, HelpMessage = "Persistent volume restore mode")]
    [ValidateSet("RestoreWithVolumeData", "RestoreWithoutVolumeData")]
    [string]$PersistentVolumeRestoreMode = "RestoreWithVolumeData",

    [Parameter(Mandatory = $false, HelpMessage = "Polling interval in seconds for job status")]
    [int]$PollIntervalSeconds = 30,

    [Parameter(Mandatory = $false, HelpMessage = "Maximum number of polling retries")]
    [int]$MaxRetries = 60,

    [switch]$SkipPermissions
)

$ErrorActionPreference = "Stop"

# ---- Ensure CLI extensions are installed ----
Write-Host "[Pre-req] Ensuring CLI extensions are installed..." -ForegroundColor Yellow

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"

$dpVersion = az extension show -n dataprotection --query version -o tsv 2>$null
if ($dpVersion) {
    Write-Host "  dataprotection extension installed (v$dpVersion)"
} else {
    Write-Host "  Installing dataprotection extension..." -ForegroundColor Yellow
    az extension add -n dataprotection --yes 2>$null
    $dpVersion = az extension show -n dataprotection --query version -o tsv 2>$null
    Write-Host "  dataprotection extension installed (v$dpVersion)" -ForegroundColor Green
}

$k8sExt = az extension show -n k8s-extension --query version -o tsv 2>$null
if ($k8sExt) {
    Write-Host "  k8s-extension installed (v$k8sExt)"
} else {
    Write-Host "  Installing k8s-extension..." -ForegroundColor Yellow
    az extension add -n k8s-extension --yes 2>$null
    Write-Host "  k8s-extension installed" -ForegroundColor Green
}

$aksPreview = az extension show -n aks-preview --query version -o tsv 2>$null
if ($aksPreview) {
    Write-Host "  aks-preview extension installed (v$aksPreview)"
} else {
    Write-Host "  Installing aks-preview extension..." -ForegroundColor Yellow
    az extension add -n aks-preview --yes 2>$null
    $aksPreview = az extension show -n aks-preview --query version -o tsv 2>$null
    Write-Host "  aks-preview extension installed (v$aksPreview)" -ForegroundColor Green
}

$ErrorActionPreference = $prevEAP

# Parse namespace mapping
$namespaceMapping = @{}
if ($NamespaceMappingJson -and $NamespaceMappingJson -ne '{}') {
    $namespaceMapping = $NamespaceMappingJson | ConvertFrom-Json -AsHashtable
}

Write-Host "=== AKS Vault-Tier Restore ===" -ForegroundColor Cyan
Write-Host "  Subscription:        $SubscriptionId"
Write-Host "  Vault:               $VaultName"
Write-Host "  Resource Group:      $ResourceGroupName"
Write-Host "  Backup Instance:     $BackupInstanceName"
Write-Host "  Target Cluster:      $TargetClusterId"
Write-Host "  Staging RG:          $StagingResourceGroupId"
Write-Host "  Staging SA:          $StagingStorageAccountId"
Write-Host "  Conflict Policy:     $ConflictPolicy"
Write-Host "  PV Restore Mode:     $PersistentVolumeRestoreMode"
Write-Host ""

az account set --subscription $SubscriptionId

# Extract location from the target cluster
$targetParts = $TargetClusterId -split '/'
$targetClusterSubscription = $targetParts[2]
$targetRg = $targetParts[4]
$targetClusterName = $targetParts[8]

# Validate cluster and vault are in the same subscription
if ($targetClusterSubscription -ne $SubscriptionId) {
    Write-Host "ERROR: Target cluster subscription ($targetClusterSubscription) does not match the vault subscription ($SubscriptionId)." -ForegroundColor Red
    Write-Host "This script requires the AKS cluster and backup vault to be in the same subscription." -ForegroundColor Red
    exit 1
}

$clusterJson = az aks show --resource-group $targetRg --name $targetClusterName -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $clusterJson) {
    Write-Host "ERROR: Failed to retrieve AKS cluster details (az aks show failed for cluster '$targetClusterName' in RG '$targetRg')" -ForegroundColor Red
    Write-Host "Verify the TargetClusterId is correct and you have access to the cluster." -ForegroundColor Red
    exit 1
}
$cluster = $clusterJson | ConvertFrom-Json
if (-not $cluster.id) {
    Write-Host "ERROR: az aks show returned an empty or invalid response for cluster '$targetClusterName'" -ForegroundColor Red
    exit 1
}
$restoreLocation = $cluster.location
Write-Host "Restore location (from target cluster): $restoreLocation" -ForegroundColor Green

# Handle both SystemAssigned and UserAssigned managed identities
$identityType = $cluster.identity.type
if ($identityType -match "UserAssigned" -and $cluster.identity.userAssignedIdentities) {
    $uaIdentities = $cluster.identity.userAssignedIdentities
    $firstKey = ($uaIdentities | Get-Member -MemberType NoteProperty | Select-Object -First 1).Name
    $clusterPrincipalId = $uaIdentities.$firstKey.principalId
    Write-Host "  Cluster Identity Type: UserAssigned"
    Write-Host "  Cluster UA Identity:   $firstKey"
} else {
    $clusterPrincipalId = $cluster.identity.principalId
    Write-Host "  Cluster Identity Type: SystemAssigned"
}

if (-not $clusterPrincipalId) {
    Write-Host "  ERROR: Could not determine cluster MSI principal ID (identity type: $identityType)" -ForegroundColor Red
    exit 1
}
Write-Host "  Cluster MSI Principal ID: $clusterPrincipalId" -ForegroundColor Green

# -------------------------------------------------------
# Pre-check: Verify backup extension is installed on target cluster
# -------------------------------------------------------
Write-Host "`n[Pre-check] Verifying backup extension on target cluster..." -ForegroundColor Cyan

$extensionJson = az k8s-extension show --name azure-aks-backup --cluster-name $targetClusterName --resource-group $targetRg --cluster-type managedClusters -o json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $extensionJson) {
    Write-Host "ERROR: Backup extension 'azure-aks-backup' is not installed on cluster '$targetClusterName'." -ForegroundColor Red
    Write-Host "Please install the backup extension first:" -ForegroundColor Yellow
    Write-Host "  az k8s-extension create --name azure-aks-backup --extension-type microsoft.dataprotection.kubernetes --scope cluster --cluster-type managedClusters --cluster-name $targetClusterName --resource-group $targetRg --release-train stable --configuration-settings blobContainer=<container> storageAccount=<sa> storageAccountResourceGroup=<sa-rg> storageAccountSubscriptionId=$SubscriptionId" -ForegroundColor Yellow
    exit 1
}
$extension = $extensionJson | ConvertFrom-Json
if ($extension.provisioningState -ne "Succeeded") {
    Write-Host "ERROR: Backup extension is in '$($extension.provisioningState)' state. It must be 'Succeeded' to proceed." -ForegroundColor Red
    exit 1
}
$extensionPrincipalId = $extension.aksAssignedIdentity.principalId
Write-Host "  Backup extension installed and healthy" -ForegroundColor Green
Write-Host "  Extension MSI Principal ID: $extensionPrincipalId"

# -------------------------------------------------------
# Step 1b: Setup permissions and trusted access
# -------------------------------------------------------
if (-not $SkipPermissions) {
    Write-Host "`n[Step 1b] Setting up permissions and trusted access..." -ForegroundColor Cyan

    # Get vault MSI principal ID
    $vaultJson = az dataprotection backup-vault show -g $ResourceGroupName --vault-name $VaultName -o json 2>$null
    $vault = $vaultJson | ConvertFrom-Json
    $vaultPrincipalId = $vault.identity.principalId
    $vaultId = $vault.id
    Write-Host "  Vault MSI Principal ID: $vaultPrincipalId"

    # Cluster MSI principal ID already resolved above (handles both SystemAssigned and UserAssigned)
    Write-Host "  Cluster MSI Principal ID: $clusterPrincipalId"

    # --- Trusted Access ---
    Write-Host "  Checking trusted access binding..." -ForegroundColor Yellow
    $existingBindings = az aks trustedaccess rolebinding list --resource-group $targetRg --cluster-name $targetClusterName -o json 2>$null | ConvertFrom-Json
    $hasBinding = $existingBindings | Where-Object { $_.sourceResourceId.ToLower() -eq $vaultId.ToLower() }
    if ($hasBinding) {
        Write-Host "  Trusted access already configured: $($hasBinding.name)" -ForegroundColor Green
    } else {
        $bindingName = "restore-tarb-$(Get-Random -Maximum 99999)"
        Write-Host "  Creating trusted access binding: $bindingName" -ForegroundColor Yellow
        az aks trustedaccess rolebinding create `
            --resource-group $targetRg `
            --cluster-name $targetClusterName `
            --name $bindingName `
            --source-resource-id $vaultId `
            --roles "Microsoft.DataProtection/backupVaults/backup-operator" `
            -o none 2>$null
        Write-Host "  Trusted access configured" -ForegroundColor Green
    }

    # --- Role Assignments ---
    function Assign-RoleIfMissing {
        param($Role, $Assignee, $Scope, $Label)
        $existing = az role assignment list --assignee $Assignee --role $Role --scope $Scope -o json 2>$null | ConvertFrom-Json
        if ($existing -and $existing.Count -gt 0) {
            Write-Host "  [OK] $Label - $Role already assigned" -ForegroundColor DarkGray
        } else {
            az role assignment create --role $Role --assignee-object-id $Assignee --assignee-principal-type ServicePrincipal --scope $Scope -o none 2>$null
            Write-Host "  [+] $Label - $Role assigned" -ForegroundColor Green
        }
    }

    # Vault MSI roles
    Assign-RoleIfMissing -Role "Reader" -Assignee $vaultPrincipalId -Scope $TargetClusterId -Label "Vault MSI on Cluster"
    Assign-RoleIfMissing -Role "Contributor" -Assignee $vaultPrincipalId -Scope $StagingResourceGroupId -Label "Vault MSI on Staging RG"
    Assign-RoleIfMissing -Role "Storage Blob Data Contributor" -Assignee $vaultPrincipalId -Scope $StagingStorageAccountId -Label "Vault MSI on Staging SA"
    Assign-RoleIfMissing -Role "Storage Blob Data Owner" -Assignee $vaultPrincipalId -Scope $StagingStorageAccountId -Label "Vault MSI on Staging SA (Blob Owner)"
    Assign-RoleIfMissing -Role "Storage Account Contributor" -Assignee $vaultPrincipalId -Scope $StagingStorageAccountId -Label "Vault MSI on Staging SA (SA Contributor)"

    # Cluster MSI roles
    Assign-RoleIfMissing -Role "Contributor" -Assignee $clusterPrincipalId -Scope $StagingResourceGroupId -Label "Cluster MSI on Staging RG"
    Assign-RoleIfMissing -Role "Storage Account Contributor" -Assignee $clusterPrincipalId -Scope $StagingStorageAccountId -Label "Cluster MSI on Staging SA (SA Contributor)"
    Assign-RoleIfMissing -Role "Storage Blob Data Contributor" -Assignee $clusterPrincipalId -Scope $StagingStorageAccountId -Label "Cluster MSI on Staging SA (Blob Contributor)"
    Assign-RoleIfMissing -Role "Disk Snapshot Contributor" -Assignee $clusterPrincipalId -Scope $StagingResourceGroupId -Label "Cluster MSI on Staging RG (Disk Snapshot Contributor)"

    # Extension MSI roles on staging SA
    Assign-RoleIfMissing -Role "Storage Account Contributor" -Assignee $extensionPrincipalId -Scope $StagingStorageAccountId -Label "Extension MSI on Staging SA (SA Contributor)"
    Assign-RoleIfMissing -Role "Storage Blob Data Contributor" -Assignee $extensionPrincipalId -Scope $StagingStorageAccountId -Label "Extension MSI on Staging SA (Blob Contributor)"
} else {
    Write-Host "`n[Step 1b] Skipping permission setup (-SkipPermissions)" -ForegroundColor Yellow
}

# -------------------------------------------------------
# Step 2: List available recovery points from vault store
# -------------------------------------------------------
Write-Host "`n[Step 2] Listing recovery points from VaultStore..." -ForegroundColor Cyan

$rpListJson = az dataprotection recovery-point list `
    --backup-instance-name $BackupInstanceName `
    --resource-group $ResourceGroupName `
    --vault-name $VaultName `
    -o json

$rpList = $rpListJson | ConvertFrom-Json

if (-not $rpList -or $rpList.Count -eq 0) {
    Write-Host "No recovery points found." -ForegroundColor Red
    exit 1
}

# Filter to only vault-tier recovery points
$vaultRpList = @($rpList | Where-Object {
    $_.properties.recoveryPointDataStoresDetails | Where-Object { $_.type -eq "VaultStore" }
})

Write-Host "Found $($rpList.Count) total recovery point(s), $($vaultRpList.Count) in VaultStore:" -ForegroundColor Green
$vaultRpList | ForEach-Object {
    Write-Host "  RP ID: $($_.name)  |  Time: $($_.properties.recoveryPointTime)  |  Type: $($_.properties.recoveryPointType)"
}

if ($vaultRpList.Count -eq 0) {
    Write-Host "No vault-tier recovery points found." -ForegroundColor Red
    exit 1
}

if ($RecoveryPointId) {
    # Validate the user-specified recovery point exists in vault-tier RPs
    $matchedRp = $vaultRpList | Where-Object { $_.name -eq $RecoveryPointId }
    if (-not $matchedRp) {
        Write-Host "Specified recovery point '$RecoveryPointId' not found in vault-tier recovery points." -ForegroundColor Red
        exit 1
    }
    Write-Host "`nUsing specified recovery point: $RecoveryPointId" -ForegroundColor Yellow
}
else {
    # Use the latest vault-tier recovery point
    $RecoveryPointId = $vaultRpList[0].name
    Write-Host "`nUsing latest vault-tier recovery point: $RecoveryPointId" -ForegroundColor Yellow
}

# -------------------------------------------------------
# Step 3: Initialize restore configuration for vault store
# -------------------------------------------------------
Write-Host "`n[Step 3] Initializing restore configuration..." -ForegroundColor Cyan

# First generate the restore config template
$restoreConfigFile = [System.IO.Path]::Combine($env:TEMP, "aks_restoreconfig.json")
az dataprotection backup-instance initialize-restoreconfig `
    --datasource-type AzureKubernetesService `
    -o json | Set-Content -Path $restoreConfigFile -Encoding UTF8

$restoreConfigJson = az dataprotection backup-instance restore initialize-for-item-recovery `
    --datasource-type AzureKubernetesService `
    --restore-location $restoreLocation `
    --source-datastore VaultStore `
    --recovery-point-id $RecoveryPointId `
    --target-resource-id $TargetClusterId `
    --restore-configuration $restoreConfigFile `
    -o json

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to initialize restore configuration." -ForegroundColor Red
    exit 1
}

$restoreConfig = $restoreConfigJson | ConvertFrom-Json
Write-Host "Restore configuration initialized." -ForegroundColor Green

# -------------------------------------------------------
# Step 4: Update restore criteria with staging resources and namespace mapping
# -------------------------------------------------------
Write-Host "`n[Step 4] Updating restore criteria with staging resources and namespace mapping..." -ForegroundColor Cyan

# Patch the restore request body with vault-tier restore criteria
$criteria = $restoreConfig.restore_target_info.restore_criteria[0]
$criteria | Add-Member -NotePropertyName "staging_resource_group_id" -NotePropertyValue $StagingResourceGroupId -Force
$criteria | Add-Member -NotePropertyName "staging_storage_account_id" -NotePropertyValue $StagingStorageAccountId -Force
$criteria | Add-Member -NotePropertyName "object_type" -NotePropertyValue "KubernetesClusterVaultTierRestoreCriteria" -Force

# Namespace mapping
if ($namespaceMapping.Count -gt 0) {
    $criteria | Add-Member -NotePropertyName "namespace_mappings" -NotePropertyValue $namespaceMapping -Force
    Write-Host "Namespace mapping:" -ForegroundColor Yellow
    $namespaceMapping.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Key) -> $($_.Value)" }
}

$criteria | Add-Member -NotePropertyName "conflict_policy" -NotePropertyValue $ConflictPolicy -Force
$criteria | Add-Member -NotePropertyName "persistent_volume_restore_mode" -NotePropertyValue $PersistentVolumeRestoreMode -Force

$restoreRequestFile = [System.IO.Path]::Combine($env:TEMP, "aks_restore_request.json")
$restoreConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $restoreRequestFile -Encoding UTF8

Write-Host "Restore request saved to: $restoreRequestFile" -ForegroundColor Green
Write-Host ($restoreConfig | ConvertTo-Json -Depth 10)

# -------------------------------------------------------
# Step 5: Validate for restore
# -------------------------------------------------------
Write-Host "`n[Step 5] Validating restore request..." -ForegroundColor Cyan

az dataprotection backup-instance validate-for-restore `
    --backup-instance-name $BackupInstanceName `
    --resource-group $ResourceGroupName `
    --vault-name $VaultName `
    --restore-request-object $restoreRequestFile

if ($LASTEXITCODE -ne 0) {
    Write-Host "Validate-for-restore failed. Check errors above." -ForegroundColor Red
    exit 1
}
Write-Host "Validation passed." -ForegroundColor Green

# -------------------------------------------------------
# Step 6: Trigger the restore
# -------------------------------------------------------
Write-Host "`n[Step 6] Triggering restore..." -ForegroundColor Cyan

try {
    az dataprotection backup-instance restore trigger `
        --backup-instance-name $BackupInstanceName `
        --resource-group $ResourceGroupName `
        --vault-name $VaultName `
        --restore-request-object $restoreRequestFile `
        --no-wait

    if ($LASTEXITCODE -ne 0) { throw "Restore trigger failed with exit code $LASTEXITCODE" }

    Write-Host "Restore triggered successfully." -ForegroundColor Green
}
catch {
    Write-Host "Restore trigger failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}

# -------------------------------------------------------
# Step 7: Poll restore job status
# -------------------------------------------------------
$retryCount = 0

Write-Host "`n[Step 7] Polling for restore job completion..." -ForegroundColor Cyan

do {
    Start-Sleep -Seconds $PollIntervalSeconds
    $retryCount++

    $jobsJson = az dataprotection job list `
        --resource-group $ResourceGroupName `
        --vault-name $VaultName `
        -o json
    $jobs = $jobsJson | ConvertFrom-Json

    # Find the latest restore job for this backup instance
    $restoreJob = $jobs | Where-Object {
        $_.properties.operationCategory -eq "Restore" -and
        $_.properties.backupInstanceId -match $BackupInstanceName
    } | Sort-Object { $_.properties.startTime } -Descending | Select-Object -First 1

    if (-not $restoreJob) {
        Write-Host "[$retryCount] Restore job not found yet..." -ForegroundColor Yellow
        continue
    }

    $jobStatus = $restoreJob.properties.status
    Write-Host "[$retryCount] Job: $($restoreJob.name) | Status: $jobStatus" -ForegroundColor Yellow

    if ($jobStatus -match "Completed|Succeeded|Failed|Cancelled") {
        break
    }

} while ($retryCount -lt $MaxRetries)

Write-Host "`nFinal job state:" -ForegroundColor Cyan
Write-Host ($restoreJob | ConvertTo-Json -Depth 10)

# Cleanup temp file
if (Test-Path $restoreRequestFile) {
    Remove-Item $restoreRequestFile -Force
}
if (Test-Path $restoreConfigFile) {
    Remove-Item $restoreConfigFile -Force
}

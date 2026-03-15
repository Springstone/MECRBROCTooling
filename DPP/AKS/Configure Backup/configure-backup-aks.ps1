<#
.SYNOPSIS
    Configure AKS backup end-to-end using standard az dataprotection CLI commands.

.DESCRIPTION
    1. Ensures dataprotection and k8s-extension CLI extensions are installed
    2. Creates a backup vault (LRS, SystemAssigned) in the specified region
    3. Creates an AKS backup policy (30d op-store + 90d vault-store)
    4. Installs backup extension on the AKS cluster
    5. Assigns permissions (vault MSI, cluster MSI, extension MSI)
    6. Sets up trusted access binding
    7. Initializes and validates backup instance
    8. Configures backup (creates backup instance)

.PARAMETER VaultRegion
    Azure region for backup vault (e.g., swedencentral, eastus2euap)

.PARAMETER ClusterId
    Full ARM resource ID of the AKS cluster to protect

.PARAMETER VaultResourceGroup
    Resource group containing the backup vault

.PARAMETER Subscription
    Subscription ID

.PARAMETER VaultName
    Name of the backup vault (default: test-vault-<region>)

.PARAMETER StorageAccountName
    Name of the storage account for backup extension (default: auto-generated)

.PARAMETER StorageAccountResourceGroup
    Resource group of the storage account (default: same as VaultResourceGroup)

.PARAMETER BlobContainerName
    Name of the blob container for backup snapshots (default: aksbackup)

.PARAMETER Tags
    Hashtable of tags (default: standard test tags)

.PARAMETER SkipPermissions
    Skip role assignment and trusted access setup

.EXAMPLE
    .\configure-backup-aks.ps1 -VaultRegion swedencentral -ClusterId "/subscriptions/<sub-id>/resourceGroups/<cluster-rg>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>" -VaultResourceGroup "<vault-rg>" -Subscription "<sub-id>" -VaultName "<vault-name>"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$VaultRegion,

    [Parameter(Mandatory=$true)]
    [string]$ClusterId,

    [Parameter(Mandatory=$true)]
    [string]$VaultResourceGroup,

    [Parameter(Mandatory=$true)]
    [string]$Subscription,

    [string]$VaultName = "",

    [Parameter(Mandatory=$false)]
    [string]$StorageAccountName = "",

    [string]$StorageAccountResourceGroup = "",

    [string]$BlobContainerName = "aksbackup",

    [hashtable]$Tags = @{
        "createdby" = "configure-backup-aks"
    },

    [switch]$SkipPermissions
)

$ErrorActionPreference = "Stop"
if (-not $VaultName) { $VaultName = "test-vault-$VaultRegion" }
if (-not $StorageAccountName) { $StorageAccountName = "testsabackup" + (Get-Random -Maximum 999) }
if (-not $StorageAccountResourceGroup) { $StorageAccountResourceGroup = $VaultResourceGroup }
$policyName = "test-policy-30d-90d"

# Extract cluster details from ARM ID
$clusterParts = $ClusterId -split '/'
$clusterRg = $clusterParts[4]
$clusterName = $clusterParts[8]

Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Configure AKS Backup E2E Script" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "Vault Region:   $VaultRegion"
Write-Host "Cluster:        $ClusterId"
Write-Host "Cluster Name:   $clusterName"
Write-Host "Cluster RG:     $clusterRg"
Write-Host "Vault RG:       $VaultResourceGroup"
Write-Host "Subscription:   $Subscription"
Write-Host "Vault:          $VaultName"
Write-Host "Policy:         $policyName"
Write-Host "Storage Acct:   $StorageAccountName"
Write-Host "Blob Container: $BlobContainerName"
Write-Host ""

# ---- Step 1: Ensure CLI extensions are installed ----
Write-Host "[1/8] Ensuring CLI extensions are installed..." -ForegroundColor Yellow

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

$ErrorActionPreference = $prevEAP

# ---- Step 2: Set Subscription ----
Write-Host ""
Write-Host "[2/8] Setting subscription..." -ForegroundColor Yellow
az account set -s $Subscription 2>$null
$currentSub = az account show --query id -o tsv 2>$null
Write-Host "  Active subscription: $currentSub"

# ---- Step 3: Create Backup Vault ----
Write-Host ""
Write-Host "[3/8] Creating backup vault: $VaultName in $VaultRegion..." -ForegroundColor Yellow

$existingVault = az dataprotection backup-vault show -g $VaultResourceGroup --vault-name $VaultName --query name -o tsv 2>$null
if ($existingVault -eq $VaultName) {
    Write-Host "  Vault already exists, skipping creation"
} else {
    $createArgs = @(
        "dataprotection", "backup-vault", "create",
        "-g", $VaultResourceGroup,
        "--vault-name", $VaultName,
        "-l", $VaultRegion,
        "--storage-settings", "datastore-type=VaultStore", "type=LocallyRedundant",
        "--mi-system-assigned",
        "--soft-delete-state", "On",
        "-o", "none"
    )
    if ($Tags.Count -gt 0) {
        $createArgs += "--tags"
        $Tags.GetEnumerator() | ForEach-Object { $createArgs += "$($_.Key)=$($_.Value)" }
    }
    az @createArgs

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to create vault" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Vault created successfully" -ForegroundColor Green

    # Enable Cross Region Backup via REST API
    Write-Host "  Enabling Cross Region Backup settings..." -ForegroundColor Yellow
    $apiVersion = "2025-08-15-preview"
    $vaultResourceId = "/subscriptions/$Subscription/resourceGroups/$VaultResourceGroup/providers/Microsoft.DataProtection/BackupVaults/$VaultName"
    $vaultUri = "https://management.azure.com${vaultResourceId}?api-version=$apiVersion"

    $armToken = (az account get-access-token --resource "https://management.azure.com" --output json 2>$null | ConvertFrom-Json).accessToken
    $armHeaders = @{ "Authorization" = "Bearer $armToken"; "Content-Type" = "application/json" }

    $existingVaultJson = Invoke-RestMethod -Method GET -Uri $vaultUri -Headers $armHeaders
    $updateBody = @{
        location   = $existingVaultJson.location
        identity   = $existingVaultJson.identity
        properties = @{
            storageSettings            = $existingVaultJson.properties.storageSettings
            isVaultProtectedByResourceGuard = $existingVaultJson.properties.isVaultProtectedByResourceGuard
            securitySettings           = @{
                softDeleteSettings = @{
                    state                   = $existingVaultJson.properties.securitySettings.softDeleteSettings.state
                    retentionDurationInDays = $existingVaultJson.properties.securitySettings.softDeleteSettings.retentionDurationInDays
                }
            }
            crossRegionBackupSettings  = "Enabled"
        }
    } | ConvertTo-Json -Depth 10

    try {
        Invoke-RestMethod -Method PUT -Uri $vaultUri -Headers $armHeaders -Body $updateBody | Out-Null
        Write-Host "  Cross Region Backup enabled" -ForegroundColor Green
    } catch {
        Write-Host "  Warning: Could not enable Cross Region Backup (may not be supported in $VaultRegion): $($_.Exception.Message.Substring(0, [Math]::Min(150, $_.Exception.Message.Length)))" -ForegroundColor DarkYellow
    }
}

$vaultJson = az dataprotection backup-vault show -g $VaultResourceGroup --vault-name $VaultName -o json 2>$null
$vault = $vaultJson | ConvertFrom-Json
$vaultId = $vault.id
$vaultPrincipalId = $vault.identity.principalId
Write-Host "  Vault ID: $vaultId"
Write-Host "  Vault MSI Principal ID: $vaultPrincipalId"

# ---- Step 4: Create Backup Policy ----
Write-Host ""
Write-Host "[4/8] Creating backup policy: $policyName..." -ForegroundColor Yellow

$existingPolicy = az dataprotection backup-policy show -g $VaultResourceGroup --vault-name $VaultName -n $policyName --query name -o tsv 2>$null
if ($existingPolicy -eq $policyName) {
    Write-Host "  Policy already exists, skipping creation"
} else {
    $policyJson = @{
        objectType = "BackupPolicy"
        datasourceTypes = @("Microsoft.ContainerService/managedClusters")
        policyRules = @(
            @{
                isDefault = $true
                lifecycles = @(
                    @{
                        deleteAfter = @{ duration = "P30D"; objectType = "AbsoluteDeleteOption" }
                        sourceDataStore = @{ dataStoreType = "OperationalStore"; objectType = "DataStoreInfoBase" }
                        targetDataStoreCopySettings = @(
                            @{
                                copyAfter = @{ objectType = "ImmediateCopyOption" }
                                dataStore = @{ dataStoreType = "VaultStore"; objectType = "DataStoreInfoBase" }
                            }
                        )
                    },
                    @{
                        deleteAfter = @{ duration = "P90D"; objectType = "AbsoluteDeleteOption" }
                        sourceDataStore = @{ dataStoreType = "VaultStore"; objectType = "DataStoreInfoBase" }
                        targetDataStoreCopySettings = @()
                    }
                )
                name = "Default"
                objectType = "AzureRetentionRule"
            },
            @{
                backupParameters = @{ backupType = "Incremental"; objectType = "AzureBackupParams" }
                dataStore = @{ dataStoreType = "OperationalStore"; objectType = "DataStoreInfoBase" }
                name = "BackupDaily"
                objectType = "AzureBackupRule"
                trigger = @{
                    objectType = "ScheduleBasedTriggerContext"
                    schedule = @{
                        repeatingTimeIntervals = @("R/2024-01-01T00:00:00+00:00/P1D")
                        timeZone = "Coordinated Universal Time"
                    }
                    taggingCriteria = @(
                        @{
                            isDefault = $true
                            tagInfo = @{ id = "Default_"; tagName = "Default" }
                            taggingPriority = 99
                        }
                    )
                }
            }
        )
    } | ConvertTo-Json -Depth 20 -Compress

    $policyFile = [System.IO.Path]::GetTempFileName() + ".json"
    $policyJson | Set-Content -Path $policyFile -Encoding utf8

    az dataprotection backup-policy create `
        -g $VaultResourceGroup `
        --vault-name $VaultName `
        -n $policyName `
        --policy "@$policyFile" `
        -o none 2>$null

    Remove-Item $policyFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to create policy" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Policy created successfully" -ForegroundColor Green
}

$policyId = az dataprotection backup-policy show -g $VaultResourceGroup --vault-name $VaultName -n $policyName --query id -o tsv 2>$null
Write-Host "  Policy ID: $policyId"

# Get cluster MSI principal ID and location (needed before extension install for SA creation)
$clusterJson = az aks show --resource-group $clusterRg --name $clusterName -o json 2>$null
$cluster = $clusterJson | ConvertFrom-Json
$clusterPrincipalId = $cluster.identity.principalId
$clusterLocation = $cluster.location
Write-Host "  Cluster MSI Principal ID: $clusterPrincipalId"
Write-Host "  Cluster Location: $clusterLocation"

# ---- Step 5: Install Backup Extension on AKS Cluster ----
Write-Host ""
Write-Host "[5/8] Installing backup extension on cluster..." -ForegroundColor Yellow

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "SilentlyContinue"
$extensionJson = az k8s-extension show --name azure-aks-backup --cluster-name $clusterName --resource-group $clusterRg --cluster-type managedClusters -o json 2>$null
$extExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($extExitCode -eq 0 -and $extensionJson) {
    $extension = $extensionJson | ConvertFrom-Json
    Write-Host "  Backup extension already installed (state: $($extension.provisioningState))"

    # Extract storage details from extension configuration
    $extConfig = $extension.configurationSettings
    $StorageAccountName = $extConfig.'configuration.backupStorageLocation.config.storageAccount'
    $StorageAccountResourceGroup = $extConfig.'configuration.backupStorageLocation.config.resourceGroup'
    $BlobContainerName = $extConfig.'configuration.backupStorageLocation.bucket'
    Write-Host "  Storage Account (from extension): $StorageAccountName"
    Write-Host "  Storage Account RG (from extension): $StorageAccountResourceGroup"
    Write-Host "  Blob Container (from extension): $BlobContainerName"
} else {
    Write-Host "  Installing backup extension..." -ForegroundColor Yellow

    # Create storage account if not exists
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    $existingSa = az storage account show --name $StorageAccountName --resource-group $StorageAccountResourceGroup --query name -o tsv 2>$null
    $ErrorActionPreference = $prevEAP
    if ($existingSa -ne $StorageAccountName) {
        Write-Host "  Creating storage account: $StorageAccountName" -ForegroundColor Yellow
        $saArgs = @(
            "storage", "account", "create",
            "--name", $StorageAccountName,
            "--resource-group", $StorageAccountResourceGroup,
            "--location", $clusterLocation,
            "--sku", "Standard_LRS",
            "-o", "none"
        )
        if ($Tags.Count -gt 0) {
            $saArgs += "--tags"
            $Tags.GetEnumerator() | ForEach-Object { $saArgs += "$($_.Key)=$($_.Value)" }
        }
        az @saArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  ERROR: Failed to create storage account" -ForegroundColor Red
            exit 1
        }
        Write-Host "  Storage account created" -ForegroundColor Green
    } else {
        Write-Host "  Storage account already exists: $StorageAccountName"
    }

    # Create blob container if not exists
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "SilentlyContinue"
    az storage container create --name $BlobContainerName --account-name $StorageAccountName --auth-mode login -o none 2>$null
    $ErrorActionPreference = $prevEAP

    az k8s-extension create `
        --name azure-aks-backup `
        --extension-type microsoft.dataprotection.kubernetes `
        --scope cluster `
        --cluster-type managedClusters `
        --cluster-name $clusterName `
        --resource-group $clusterRg `
        --release-train stable `
        --configuration-settings `
            blobContainer=$BlobContainerName `
            storageAccount=$StorageAccountName `
            storageAccountResourceGroup=$StorageAccountResourceGroup `
            storageAccountSubscriptionId=$Subscription `
        -o none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  ERROR: Failed to install backup extension" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Backup extension installed successfully" -ForegroundColor Green

    $extensionJson = az k8s-extension show --name azure-aks-backup --cluster-name $clusterName --resource-group $clusterRg --cluster-type managedClusters -o json 2>$null
    $extension = $extensionJson | ConvertFrom-Json
}

if ($extension.provisioningState -ne "Succeeded") {
    Write-Host "  WARNING: Extension is in '$($extension.provisioningState)' state. Waiting may be needed." -ForegroundColor Yellow
}

$extensionPrincipalId = $extension.aksAssignedIdentity.principalId
Write-Host "  Extension MSI Principal ID: $extensionPrincipalId"

# Build storage account resource ID
$storageAccountId = "/subscriptions/$Subscription/resourceGroups/$StorageAccountResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"

# Snapshot resource group = Vault resource group
$snapshotResourceGroupId = "/subscriptions/$Subscription/resourceGroups/$VaultResourceGroup"
Write-Host "  Snapshot RG: $snapshotResourceGroupId"

# ---- Step 6: Assign Permissions ----
if (-not $SkipPermissions) {
    Write-Host "[6/8] Setting up permissions and trusted access..." -ForegroundColor Yellow

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
    Assign-RoleIfMissing -Role "Reader" -Assignee $vaultPrincipalId -Scope $ClusterId -Label "Vault MSI on Cluster"
    Assign-RoleIfMissing -Role "Reader" -Assignee $vaultPrincipalId -Scope $SnapshotResourceGroupId -Label "Vault MSI on Snapshot RG"
    Assign-RoleIfMissing -Role "Storage Blob Data Reader" -Assignee $vaultPrincipalId -Scope $storageAccountId -Label "Vault MSI on Storage Account (Blob Reader)"
    Assign-RoleIfMissing -Role "Disk Snapshot Contributor" -Assignee $vaultPrincipalId -Scope $SnapshotResourceGroupId -Label "Vault MSI on Snapshot RG (Disk Snapshot Contributor)"
    Assign-RoleIfMissing -Role "Data Operator for Managed Disks" -Assignee $vaultPrincipalId -Scope $SnapshotResourceGroupId -Label "Vault MSI on Snapshot RG (Data Operator for Managed Disks)"

    # Cluster MSI roles
    Assign-RoleIfMissing -Role "Contributor" -Assignee $clusterPrincipalId -Scope $SnapshotResourceGroupId -Label "Cluster MSI on Snapshot RG"

    # Extension MSI roles on storage account
    Assign-RoleIfMissing -Role "Storage Account Contributor" -Assignee $extensionPrincipalId -Scope $storageAccountId -Label "Extension MSI on Storage Account (SA Contributor)"
    Assign-RoleIfMissing -Role "Storage Blob Data Contributor" -Assignee $extensionPrincipalId -Scope $storageAccountId -Label "Extension MSI on Storage Account (Blob Contributor)"

    # --- Trusted Access ---
    Write-Host "  Checking trusted access binding..." -ForegroundColor Yellow
    $existingBindings = az aks trustedaccess rolebinding list --resource-group $clusterRg --cluster-name $clusterName -o json 2>$null | ConvertFrom-Json
    $hasBinding = $existingBindings | Where-Object { $_.sourceResourceId.ToLower() -eq $vaultId.ToLower() }
    if ($hasBinding) {
        Write-Host "  Trusted access already configured: $($hasBinding.name)" -ForegroundColor Green
    } else {
        $bindingName = "backup-tarb-$(Get-Random -Maximum 99999)"
        Write-Host "  Creating trusted access binding: $bindingName" -ForegroundColor Yellow
        az aks trustedaccess rolebinding create `
            --resource-group $clusterRg `
            --cluster-name $clusterName `
            --name $bindingName `
            --source-resource-id $vaultId `
            --roles "Microsoft.DataProtection/backupVaults/backup-operator" `
            -o none 2>$null
        Write-Host "  Trusted access configured" -ForegroundColor Green
    }
} else {
    Write-Host ""
    Write-Host "[6/8] Skipping permission setup (-SkipPermissions)" -ForegroundColor Yellow
}

# ---- Step 7: Initialize and Validate Backup Instance ----
Write-Host ""
Write-Host "[7/8] Initializing and validating backup instance..." -ForegroundColor Yellow

# Step 7a: Generate backup configuration
$backupConfigFile = [System.IO.Path]::GetTempFileName() + ".json"
az dataprotection backup-instance initialize-backupconfig `
    --datasource-type AzureKubernetesService `
    -o json | Set-Content -Path $backupConfigFile -Encoding UTF8

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Failed to initialize backup config" -ForegroundColor Red
    exit 1
}
Write-Host "  Backup config generated: $backupConfigFile" -ForegroundColor Green

# Step 7b: Initialize backup instance with backup config
$backupInstanceFile = [System.IO.Path]::GetTempFileName() + ".json"
az dataprotection backup-instance initialize `
    --datasource-type AzureKubernetesService `
    --datasource-id $ClusterId `
    --datasource-location $clusterLocation `
    --policy-id $policyId `
    --backup-configuration $backupConfigFile `
    --friendly-name $clusterName `
    --snapshot-resource-group-name ($snapshotResourceGroupId -split '/')[-1] `
    -o json | Set-Content -Path $backupInstanceFile -Encoding UTF8

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Failed to initialize backup instance" -ForegroundColor Red
    Remove-Item $backupConfigFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "  Backup instance initialized" -ForegroundColor Green

# Step 7c: Validate for backup
Write-Host "  Validating backup instance..." -ForegroundColor Yellow
$vaultArmId = "/subscriptions/$Subscription/resourceGroups/$VaultResourceGroup/providers/Microsoft.DataProtection/backupVaults/$VaultName"
az dataprotection backup-instance validate-for-backup `
    --backup-instance $backupInstanceFile `
    --ids $vaultArmId

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Validate-for-backup failed" -ForegroundColor Red
    Remove-Item $backupInstanceFile, $backupConfigFile -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host "  Validation passed" -ForegroundColor Green

# ---- Step 8: Configure Backup (Create Backup Instance) ----
Write-Host ""
Write-Host "[8/8] Configuring backup (creating backup instance)..." -ForegroundColor Yellow

az dataprotection backup-instance create `
    --backup-instance $backupInstanceFile `
    --resource-group $VaultResourceGroup `
    --vault-name $VaultName

$exitCode = $LASTEXITCODE

# Cleanup temp files
Remove-Item $backupInstanceFile, $backupConfigFile -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "  BACKUP CONFIGURED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
} else {
    Write-Host "============================================" -ForegroundColor Red
    Write-Host "  BACKUP CONFIGURATION FAILED (exit code: $exitCode)" -ForegroundColor Red
    Write-Host "============================================" -ForegroundColor Red
}

exit $exitCode

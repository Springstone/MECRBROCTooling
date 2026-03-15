# Configure AKS Backup E2E Script

PowerShell script to configure AKS backup end-to-end using standard `az dataprotection` CLI commands. Creates a backup vault with cross-region backup, creates a vault-tier policy, installs the backup extension, assigns permissions, and configures the backup instance.

> **Note:** You must have **Owner** or **Contributor + User Access Administrator** role on the subscription. The script assigns roles to vault MSI, cluster MSI, and extension MSI identities.

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed and logged in (`az login`)
- `dataprotection` and `k8s-extension` CLI extensions (auto-installed by the script if missing)
- The **VaultResourceGroup** must already exist before running the script

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-VaultRegion` | Yes | — | Azure region for the backup vault |
| `-ClusterId` | Yes | — | Full ARM resource ID of the AKS cluster |
| `-VaultResourceGroup` | Yes | — | Resource group containing the backup vault |
| `-Subscription` | Yes | — | Azure Subscription ID |
| `-VaultName` | No | `test-vault-<region>` | Name of the backup vault |
| `-StorageAccountName` | No | auto-generated | Storage account for the backup extension. If the extension is already installed, this is read from the extension config. |
| `-StorageAccountResourceGroup` | No | same as `-VaultResourceGroup` | Resource group of the storage account |
| `-BlobContainerName` | No | `aksbackup` | Blob container name for backup snapshots |
| `-Tags` | No | `createdby=configure-backup-aks` | Hashtable of tags for the vault |
| `-SkipPermissions` | No | `$false` | Skip role assignment and trusted access setup |

## Usage

```powershell
.\configure-backup-aks.ps1 `
  -VaultRegion <region> `
  -ClusterId <cluster-arm-id> `
  -VaultResourceGroup <vault-rg> `
  -Subscription <sub-id>
```

### Examples

```powershell
# Configure backup with auto-generated storage account name
.\configure-backup-aks.ps1 `
  -VaultRegion swedencentral `
  -ClusterId "/subscriptions/<sub-id>/resourceGroups/<cluster-rg>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>" `
  -VaultName "<vault-name>" `
  -VaultResourceGroup "<vault-rg>" `
  -Subscription "<sub-id>"

# Configure backup with explicit storage account
.\configure-backup-aks.ps1 `
  -VaultRegion swedencentral `
  -ClusterId "/subscriptions/<sub-id>/resourceGroups/<cluster-rg>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>" `
  -VaultName "<vault-name>" `
  -VaultResourceGroup "<vault-rg>" `
  -Subscription "<sub-id>" `
  -StorageAccountName "<storage-account>" `
  -BlobContainerName "<container-name>"

# Skip permissions (if already configured)
.\configure-backup-aks.ps1 `
  -VaultRegion swedencentral `
  -ClusterId "/subscriptions/<sub-id>/resourceGroups/<cluster-rg>/providers/Microsoft.ContainerService/managedClusters/<cluster-name>" `
  -VaultName "<vault-name>" `
  -VaultResourceGroup "<vault-rg>" `
  -Subscription "<sub-id>" `
  -SkipPermissions
```

## What It Does

| Step | Action |
|------|--------|
| 1 | Ensures `dataprotection` and `k8s-extension` CLI extensions are installed |
| 2 | Sets the active subscription |
| 3 | Creates backup vault (LRS, SystemAssigned, soft delete on) + enables Cross Region Backup |
| 4 | Creates backup policy (30-day op-store + 90-day vault-store, daily incremental) |
| 5 | Installs backup extension on cluster (or reads config from existing extension) |
| 6 | Assigns role permissions and sets up trusted access binding |
| 7 | Generates backup config, initializes backup instance (with cluster location, snapshot RG, friendly name), validates for backup |
| 8 | Creates the backup instance (configures backup) |

## Role Assignments

| Identity | Scope | Role |
|----------|-------|------|
| Vault MSI | AKS Cluster | Reader |
| Vault MSI | Snapshot Resource Group | Reader |
| Vault MSI | Storage Account | Storage Blob Data Reader |
| Vault MSI | Snapshot Resource Group | Disk Snapshot Contributor |
| Vault MSI | Snapshot Resource Group | Data Operator for Managed Disks |
| Cluster MSI | Snapshot Resource Group | Contributor |
| Extension MSI | Storage Account | Storage Account Contributor |
| Extension MSI | Storage Account | Storage Blob Data Contributor |

## Storage Account Handling

- If the backup extension is **already installed** on the cluster, the script reads the storage account name, resource group, and blob container from the extension's configuration settings — no need to supply them.
- If the extension is **not installed**, the script creates the storage account (if it doesn't exist), creates the blob container, and installs the extension. The `-StorageAccountName` is auto-generated if not provided.

## Notes

- The **snapshot resource group** is the same as the vault resource group (`-VaultResourceGroup`)
- The **datasource location** is automatically derived from the AKS cluster's region (not the vault region)
- The backup instance **friendly name** is set to the AKS cluster name
- Script is **idempotent** — skips vault, policy, extension, storage account, and role assignments that already exist

# Bulk Register IaaS VM to Recovery Services Vault — README

## Overview

**Bult-Register-IaaSVM-FromCSV.ps1** is a PowerShell script that batch-protects Azure IaaS Virtual Machines to Recovery Services Vaults using a CSV file as input. For each VM, it checks whether protection is already enabled and, if not, enables backup protection with the specified policy — all via Azure Backup REST API.

## Prerequisites

- **PowerShell 5.1+** or **PowerShell 7+**
- One of the following authenticated sessions:
  - **Azure PowerShell** — run `Connect-AzAccount` before executing the script
  - **Azure CLI** — run `az login` before executing the script
- **RBAC Permissions**:
  - `Backup Contributor` (or equivalent) on each Recovery Services Vault
  - `Reader` on each target VM (or its resource group/subscription)

## CSV Input Format

Create a CSV file with the following three columns:

| Column       | Description                                      | Example                                                                                                                         |
|--------------|--------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `VaultId`    | Full Azure Resource ID of the Recovery Services Vault | `/subscriptions/aaaa-bbbb/resourceGroups/myRG/providers/Microsoft.RecoveryServices/vaults/myVault`                              |
| `VmId`       | Full Azure Resource ID of the Virtual Machine         | `/subscriptions/aaaa-bbbb/resourceGroups/vmRG/providers/Microsoft.Compute/virtualMachines/myVM`                                 |
| `PolicyName` | Name of the backup policy in the vault                | `DefaultPolicy`                                                                                                                  |

### Sample CSV (`input.csv`)

```csv
VaultId,VmId,PolicyName
/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vault-rg/providers/Microsoft.RecoveryServices/vaults/prodVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/web-vm-01,DefaultPolicy
/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vault-rg/providers/Microsoft.RecoveryServices/vaults/prodVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/sql-vm-01,EnhancedPolicy
/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/dr-rg/providers/Microsoft.RecoveryServices/vaults/drVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/app-vm-01,DefaultPolicy
```

> **Note:** Cross-subscription scenarios are supported — the VM and vault can be in different subscriptions.

## Usage

```powershell
.\Bult-Register-IaaSVM-FromCSV.ps1 -CsvPath "C:\path\to\input.csv"
```

### Parameters

| Parameter  | Required | Description                          |
|------------|----------|--------------------------------------|
| `-CsvPath` | Yes      | Path to the CSV file with VM details |

## How It Works

For each row in the CSV, the script performs the following steps:

1. **Parse Resource IDs** — Extracts subscription, resource group, vault name, and VM name from the full resource IDs.
2. **Check Protection Status** — Queries the Azure Backup REST API to see if the VM is already registered and protected. If yes, it skips the row.
3. **Enable Protection** — Sends a PUT request to enable backup protection using the specified policy.
4. **Track Async Operation** — If the API returns `202 Accepted`, the script polls the operation status until completion or timeout.

## Output

### Console Output

The script prints progress for each row and a summary table at the end:

```
============================================================
  BATCH PROCESSING SUMMARY
============================================================

Row VM         Status            Detail
--- --         ------            ------
  1 web-vm-01  PROTECTED         Immediate success
  2 sql-vm-01  ALREADY_PROTECTED State=Protected, Policy=EnhancedPolicy
  3 app-vm-01  FAILED            HTTP 403 - Authorization failed

  Total: 3  |  Protected: 2  |  Pending: 0  |  Failed: 1
```

### Status Values

| Status              | Meaning                                                       |
|---------------------|---------------------------------------------------------------|
| `PROTECTED`         | Protection was successfully enabled during this run           |
| `ALREADY_PROTECTED` | VM was already protected — no action taken                    |
| `ACCEPTED`          | Protection request accepted; verify completion in the portal  |
| `IN_PROGRESS`       | Async operation did not complete within the polling window     |
| `FAILED`            | Protection failed — see the `Detail` column for the error     |

## Troubleshooting

| Issue | Possible Cause | Resolution |
|-------|----------------|------------|
| `ERROR: CSV is missing required column` | Column names don't match exactly | Ensure headers are `VaultId`, `VmId`, `PolicyName` (case-sensitive) |
| `Could not parse VaultId / VmId` | Malformed resource ID | Use the full ARM resource ID starting with `/subscriptions/...` |
| `HTTP 403` | Insufficient permissions | Assign `Backup Contributor` on the vault and `Reader` on the VM |
| `HTTP 404` on enable protection | VM not discovered by the vault | The script does not run container refresh; run `Register-IaaSVM-ToVault.ps1` first, or manually refresh containers in the portal |
| `HTTP 409` | VM is protected by another vault | A VM can only be protected by one vault at a time |

## API Versions Used

| API Version    | Used For                                |
|----------------|-----------------------------------------|
| `2019-05-13`   | Protection status check, enable protection |

## References

- [Back up an Azure VM using REST API](https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms)
- [Azure Backup REST API reference](https://learn.microsoft.com/en-us/rest/api/backup/)
- [Azure VM Backup automation with PowerShell](https://learn.microsoft.com/en-us/azure/backup/backup-azure-vms-automation)

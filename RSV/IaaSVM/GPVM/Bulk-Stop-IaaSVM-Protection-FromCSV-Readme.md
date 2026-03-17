# Bulk Stop IaaS VM Protection (Retain Data) — README

## Overview

**Bulk-Stop-IaaSVM-Protection-FromCSV.ps1** is a PowerShell script that batch-stops backup protection for Azure IaaS Virtual Machines while retaining existing backup data. It reads a CSV file with vault and VM resource IDs and processes each row via the Azure Backup REST API.

After stop-protection-with-retain-data:
- No new backups will be taken for the VM.
- All existing recovery points are preserved and can be used for restore.
- The VM remains listed in the vault as a stopped-protection item.
- Protection can be resumed later by re-associating a backup policy.

## Prerequisites

- **PowerShell 5.1+** or **PowerShell 7+**
- One of the following authenticated sessions:
  - **Azure PowerShell** — run `Connect-AzAccount` before executing the script
  - **Azure CLI** — run `az login` before executing the script
- **RBAC Permissions**:
  - `Backup Contributor` (or equivalent) on each Recovery Services Vault
  - `Reader` on each target VM (or its resource group/subscription)

## CSV Input Format

Create a CSV file with the following two columns:

| Column    | Description                                           | Example                                                                                                       |
|-----------|-------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| `VaultId` | Full Azure Resource ID of the Recovery Services Vault | `/subscriptions/aaaa-bbbb/resourceGroups/myRG/providers/Microsoft.RecoveryServices/vaults/myVault`            |
| `VmId`    | Full Azure Resource ID of the Virtual Machine         | `/subscriptions/aaaa-bbbb/resourceGroups/vmRG/providers/Microsoft.Compute/virtualMachines/myVM`               |

### Sample CSV

```csv
VaultId,VmId
/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vault-rg/providers/Microsoft.RecoveryServices/vaults/prodVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/web-vm-01
/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vault-rg/providers/Microsoft.RecoveryServices/vaults/prodVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/sql-vm-01
/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/resourceGroups/dr-rg/providers/Microsoft.RecoveryServices/vaults/drVault,/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/vm-rg/providers/Microsoft.Compute/virtualMachines/app-vm-01
```

> **Note:** Cross-subscription scenarios are supported — the VM and vault can be in different subscriptions.

## Usage

```powershell
.\Bulk-Stop-IaaSVM-Protection-FromCSV.ps1 -CsvPath "C:\path\to\input.csv"
```

### Parameters

| Parameter  | Required | Description                          |
|------------|----------|--------------------------------------|
| `-CsvPath` | Yes      | Path to the CSV file with VM details |

## How It Works

For each row in the CSV, the script performs the following steps:

1. **Parse Resource IDs** — Extracts subscription, resource group, vault name, and VM name from the full resource IDs.
2. **Check Protection Status** — Queries the Azure Backup REST API to find the VM among protected items. If already stopped, it skips the row.
3. **Stop Protection (Retain Data)** — Sends a PUT request with `protectionState = "ProtectionStopped"` and no policy, which stops future backups while retaining existing recovery points.
4. **Track Async Operation** — If the API returns `202 Accepted`, the script polls the operation status until completion or timeout.

## Output

### Console Output

The script prints progress for each row and a summary table at the end:

```
============================================================
  BATCH STOP-PROTECTION SUMMARY
============================================================

Row VM         Status          Detail
--- --         ------          ------
  1 web-vm-01  STOPPED         Immediate success
  2 sql-vm-01  ALREADY_STOPPED Protection already stopped
  3 app-vm-01  FAILED          HTTP 403 - Authorization failed

  Total: 3  |  Stopped: 2  |  Pending: 0  |  Failed: 1
```

### Status Values

| Status            | Meaning                                                    |
|-------------------|------------------------------------------------------------|
| `STOPPED`         | Protection successfully stopped, backup data retained      |
| `ALREADY_STOPPED` | Protection was already stopped — no action taken           |
| `ACCEPTED`        | Request accepted (202) — check Azure Portal for final status |
| `IN_PROGRESS`     | Operation still running after polling timeout              |
| `FAILED`          | Operation failed — see Detail column for error info        |

## References

- [Stop protection but retain existing data (REST API)](https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-backupazurevms#stop-protection-but-retain-existing-data)
- [Protected Items - Create Or Update](https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update)

# SQL IaaS VM Backup Migration Scripts

## Overview

This toolkit provides PowerShell scripts to migrate SQL Server backup protection from one Recovery Services Vault (RSV) to another — typically when moving protection to a different Azure region.

**The core challenge:** To register a SQL VM to a new vault, it must first be unregistered from the old vault. This is straightforward for standalone databases but complex for VMs participating in SQL Always On Availability Groups (AGs).

---

## Why Is AG Unregistration Complex?

| Database Type | Stop Protection Method | Why |
|---|---|---|
| **Standalone DBs** | Stop with **retain data** | Simple — recovery points stay in vault |
| **AG DBs** | Stop with **delete data** (soft-delete) | AG databases belong to an AG container, not the physical VM container. To unregister the physical VM, AG protection references must be fully removed. After unregistration, the script **undeletes** the AG items to recover recovery points |

> ⚠️ **CRITICAL PRE-REQUISITE:** Soft delete **must** be enabled on the vault before running the AG unregistration script. The script enforces this automatically, but the customer should verify it beforehand.

---

## Scripts Reference

| Script | Purpose |
|---|---|
| `Bulk-UnregisterSQLAG-FromVault.ps1` | Unregister SQL VMs with AG databases from a vault |
| `Bulk-UnregisterSQLIaaSVM-FromVault.ps1` | Unregister standalone SQL VMs (no AG) from a vault |
| `Bulk-RegisterSQLIaaSVM-ToVault.ps1` | Register SQL VMs to a new vault + enable protection |
| `Enable-AGAutoProtection.ps1` | Enable auto-protection on AG availability groups |
| `Bulk-UndeleteSQLItems-FromVault.ps1` | Undelete (recover) soft-deleted backup items |
| `Register-SQLIaaSVM-ToVault.ps1` | Register a single SQL VM to a vault |
| `Unregister-SQLIaaSVM-FromVault.ps1` | Unregister a single standalone SQL VM from a vault |
| `Restore-SQLIaaSVM-FromVault.ps1` | Restore a SQL database from backup (ALR / RestoreAsFiles) |

All scripts use **API version 2025-08-01** and support Azure PowerShell (`Connect-AzAccount`) or Azure CLI (`az login`) authentication.

---

## Migration Flow

### Step 0: Determine If the VM Has AG Databases

Before starting, determine whether the SQL VM participates in an Availability Group:

- **No AG databases** → Use the [Standalone VM Flow](#flow-a-standalone-vms-no-ag)
- **Has AG databases** (standalone + AG, or AG only) → Use the [AG VM Flow](#flow-b-vms-with-ag-databases)

---

### Flow A: Standalone VMs (No AG)

```
Old Vault                              New Vault
────────                              ─────────
1. Stop protection (retain data)
2. Unregister container
                                       3. Register VM
                                       4. Enable protection (auto-protect)
```

#### Step 1–2: Unregister from Old Vault

Prepare CSV (`unregister-standalone.csv`):
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
af95aa3c-...,rg-vault,oldVault,rg-sql,sql-vm-01
af95aa3c-...,rg-vault,oldVault,rg-sql,sql-vm-02
```

Run:
```powershell
.\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath ".\unregister-standalone.csv"
```

**What happens:** The script stops protection with retain data for all databases on each VM, then unregisters the container. All recovery points are preserved in the old vault.

**Check:** Review the script output for any errors. All VMs should show `Status: Success`.

#### Step 3–4: Register to New Vault

Prepare CSV (`register-new.csv`):
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,DatabaseName,PolicyName,EnableAutoProtection,AutoProtectAllInstances
af95aa3c-...,rg-new-vault,newVault,rg-sql,sql-vm-01,,,HourlyLogBackup,,true
af95aa3c-...,rg-new-vault,newVault,rg-sql,sql-vm-02,,,HourlyLogBackup,,true
```

Run:
```powershell
.\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath ".\register-new.csv"
```

**What happens:** Registers each VM, runs SQL workload inquiry, and enables auto-protection on all SQL instances with the specified policy. All current and future databases are automatically protected.

---

### Flow B: VMs with AG Databases

```
Old Vault                              New Vault
────────                              ─────────
1. Verify soft delete is enabled
2. Stop-retain standalone DBs
3. Stop-delete AG DBs (soft-deleted)
4. Unregister physical container
5. Wait 3 minutes
6. Undelete AG DBs (recover RPs)
7. Verify all AG DBs recovered
                                       8. Register ALL AG nodes
                                       9. Enable AG auto-protection
```

> ⚠️ **IMPORTANT:** All nodes participating in the AG must be processed. If `sqlserver-0` and `sqlserver-1` are both nodes in AG1, both must be unregistered from the old vault and registered to the new vault.

#### Step 1–7: Unregister from Old Vault (AG Script)

Prepare CSV (`unregister-ag.csv`) — list all VM nodes you want to unregister:
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
af95aa3c-...,rg-vault,oldVault,rg-sql,sqlserver-0
af95aa3c-...,rg-vault,oldVault,rg-sql,sqlserver-1
```

Run:
```powershell
# Interactive — prompts for confirmation
.\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath ".\unregister-ag.csv"

# Or fully non-interactive
.\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath ".\unregister-ag.csv" -SkipConfirmation
```

**What the script does automatically:**
1. Verifies soft delete is enabled (enables it if not)
2. Discovers all containers (physical + AG) and classifies databases
3. Stops protection with **retain data** for standalone DBs
4. Stops protection with **delete data** for AG DBs (soft-deleted)
5. Unregisters the physical VM container(s)
6. Waits 3 minutes for propagation
7. **Undeletes** all AG DBs (multi-phase foolproof retry)
8. Verifies all AG DBs are recovered from soft-delete

**End state:** All databases are in `ProtectionStopped` with recovery points preserved.

#### ⚠️ Critical Verification Step

After the script completes, **verify that all AG databases were undeleted successfully**:

- Check the script output for `Phase 4: Final Verification` — all items should show `VERIFIED`
- If any items show as still `SoftDeleted`, immediately run the undelete failsafe:

```powershell
# Failsafe: undelete any remaining soft-deleted items
.\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-failsafe.csv" -SkipConfirmation
```

With `undelete-failsafe.csv`:
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,PolicyName
af95aa3c-...,rg-vault,oldVault,,,
```

> 🔴 **WARNING:** Once the soft-delete retention period expires (default: 14 days), any item still in `SoftDeleted` state will be **permanently lost**. Always verify the undelete completed successfully.

#### Step 8: Register ALL AG Nodes to New Vault

Prepare CSV (`register-ag-nodes.csv`) — **all nodes** that participate in the AG:
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,DatabaseName,PolicyName,EnableAutoProtection,AutoProtectAllInstances
af95aa3c-...,rg-new-vault,newVault,rg-sql,sqlserver-0,,,HourlyLogBackup,,true
af95aa3c-...,rg-new-vault,newVault,rg-sql,sqlserver-1,,,HourlyLogBackup,,true
```

Run:
```powershell
.\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath ".\register-ag-nodes.csv"
```

**What happens:** Registers each node, runs inquiry, and auto-protects all standalone SQL instances. The standalone databases will be protected immediately.

#### Step 9: Enable AG Auto-Protection

After registration completes and the backup service discovers the AG groups (may take a few minutes), enable auto-protection on the AGs:

Prepare CSV (`ag-autoprotect.csv`):
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,PolicyName
af95aa3c-...,rg-new-vault,newVault,HourlyLogBackup
```

Run:
```powershell
.\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv" -SkipConfirmation
```

**What happens:** Discovers all `SQLAvailabilityGroupContainer` protectable items in the vault and enables auto-protection on each AG group. All current and future AG databases will be automatically protected.

---

## Recovery: Undelete Soft-Deleted Items

If at any point backup items end up in a soft-deleted state (intentionally or due to errors), use the undelete script:

```powershell
.\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete.csv" -SkipConfirmation
```

The script moves items from `SoftDeleted` → `ProtectionStopped` (retain data). No data is lost.

Optionally, add `PolicyName` to the CSV to also resume protection after undelete.

---

## Restore: Recover a Database from Backup

To restore a SQL database from a recovery point:

```powershell
# ALR (Alternate Location Restore) — restore to a different DB name
.\Restore-SQLIaaSVM-FromVault.ps1 `
    -VaultSubscriptionId "af95aa3c-..." `
    -VaultResourceGroup "rg-vault" `
    -VaultName "myVault" `
    -VMResourceGroup "rg-sql" `
    -VMName "sql-vm-01" `
    -DatabaseName "SalesDB" `
    -RestoreType ALR `
    -TargetVMName "sql-vm-01" `
    -TargetVMResourceGroup "rg-sql" `
    -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored" `
    -TargetDataPath "D:\SQLData" `
    -TargetLogPath "D:\SQLLogs"
```

Supports: Full recovery, Point-in-Time (log restore), and Restore as Files.

---

## Quick Reference: CSV Formats

### Bulk Register
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,DatabaseName,PolicyName,EnableAutoProtection,AutoProtectAllInstances
```

### Bulk Unregister (Standalone)
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,DatabaseName,Unregister,StopAll
```

### Bulk Unregister (AG)
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
```

### Enable AG Auto-Protection
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,PolicyName
```

### Bulk Undelete
```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,PolicyName
```

---

## Safety Guarantees

| Guarantee | How |
|---|---|
| Recovery points are **never permanently deleted** | Standalone DBs use stop-retain; AG DBs use stop-delete + undelete |
| Soft delete is **enforced** before AG operations | Script checks, enables if needed, re-verifies, aborts if it can't |
| AG undelete is **foolproof** | 3-phase retry with escalating backoff + final verification |
| Cross-RG matching is **safe** | All container matching uses full container name pattern including resource group |
| **Audit trail** | Results CSV exported with machine name + timestamp |
| **Idempotent** | Scripts skip already-processed items (already stopped, already soft-deleted, already unregistered) |
| **Token refresh** | AG script refreshes Azure token before undelete to prevent auth expiry on long runs |

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `BMSUserErrorContainerHasDatasources` | Stop operations haven't propagated | Wait a few minutes and retry |
| `BMSUserErrorNodePartOfActiveAG` | VM is a node in an AG with active protected items | Ensure all AG DBs referencing this VM are stop-deleted |
| Container matches wrong VM | Same VM name in different resource groups | Verify `VMResourceGroup` in CSV is correct |
| `409 Conflict` on auto-protect | Auto-protection intent already exists | Already done — safe to ignore |
| Script timeout during polling | Slow backend | Re-run — scripts are idempotent |
| Items still SoftDeleted after script | Undelete failed or was skipped | Run `Bulk-UndeleteSQLItems-FromVault.ps1` as failsafe |

---

## API Version

All scripts use Azure Backup REST API version **`2025-08-01`**.

---

## Prerequisites

- **Authentication:** Azure PowerShell (`Connect-AzAccount`) or Azure CLI (`az login`)
- **Permissions:** Backup Contributor on the Recovery Services Vault + Reader on the VMs
- **SQL IaaS Agent:** Extension must be installed on the SQL VMs
- **Soft Delete:** Must be enabled on vaults with AG databases (enforced by scripts)

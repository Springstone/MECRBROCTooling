================================================================================
  Bulk-UnregisterSQLIaaSVM-FromVault.ps1 - README
================================================================================

DESCRIPTION
-----------
CSV-driven bulk wrapper for Unregister-SQLIaaSVM-FromVault.ps1. Authenticates
once to Azure, then processes multiple VMs from a CSV file, calling the
Unregister script for each row with a shared pre-fetched token.

Designed for bulk stop-protection and/or unregistration of SQL VMs from
Azure Backup. Recovery points are ALWAYS PRESERVED (retain data).


HOW IT WORKS
------------
  1. Validates the CSV file (required columns, no empty required fields).
  2. Shows an execution plan listing each VM and its operation mode.
  3. Authenticates once (Azure PowerShell or Azure CLI).
  4. Loops through each CSV row, calling Unregister-SQLIaaSVM-FromVault.ps1
     with the row's parameters, the shared -Token, and -SkipConfirmation.
  5. Captures per-VM status, exit code, and duration.
  6. Outputs a summary table and exports a results CSV.

  All confirmation prompts are automatically skipped (-SkipConfirmation)
  since bulk operations should be fully non-interactive.


PREREQUISITES
-------------
  - Unregister-SQLIaaSVM-FromVault.ps1 must be in the SAME directory.
  - Azure PowerShell (Connect-AzAccount) or Azure CLI (az login).
  - Appropriate RBAC permissions on all vaults and VMs in the CSV.


PARAMETERS
----------
  -CsvPath              [Required]  Path to the input CSV file.
  -DefaultMode          [Optional]  Default mode when CSV row doesn't specify.
                                    Valid values:
                                      Unregister (default) - stop all + unregister
                                      StopAll              - stop all, no unregister
                                      StopProtectionOnly   - interactive (not recommended)
  -ResultsPath          [Optional]  Path for the results CSV. If omitted,
                                    auto-generated next to the input CSV
                                    with a timestamp suffix.
  -StopOnFirstFailure   [Optional]  Stop processing remaining VMs if any
                                    VM fails.
  -WhatIf               [Optional]  Validate CSV and show plan without
                                    executing. No changes are made.


CSV FORMAT
----------

  Required columns:
    VaultSubscriptionId, VaultResourceGroup, VaultName,
    VMResourceGroup, VMName

  Optional columns:
    InstanceName, DatabaseName, Unregister, StopAll


EXAMPLE CSV - Unregister all VMs (minimal, 5 columns)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-02
  af95aa3c-...,rg-vault,myVault,rg-prod,sql-prod-01

  With -DefaultMode Unregister (the default), each VM will have all DBs
  stopped (retain data) and then be unregistered from the vault.


EXAMPLE CSV - Mixed modes per row
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,Unregister,StopAll,DatabaseName
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01,true,,
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-02,,true,
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-03,,,SalesDB

  Row 1: Stop all + unregister sql-vm-01
  Row 2: Stop all DBs on sql-vm-02 (no unregister)
  Row 3: Stop protection for SalesDB only on sql-vm-03


EXAMPLE CSV - With instance filtering
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,StopAll
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01,MSSQLSERVER,true
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01,SQLEXPRESS,true

  Stops protection for all DBs in MSSQLSERVER first, then SQLEXPRESS.
  Note: -InstanceName is ignored when Unregister=true.


EXAMPLES
--------

Example 1 - Unregister all VMs in the CSV (default mode)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath "C:\input\vms.csv"

  Default mode is Unregister: stops all DBs + unregisters each VM.
  No prompts (SkipConfirmation is automatic in bulk mode).


Example 2 - Stop protection only (no unregister)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 `
        -CsvPath "C:\input\vms.csv" `
        -DefaultMode StopAll

  Stops protection with retain data for all DBs, but does not
  unregister the VMs from the vault.


Example 3 - Dry run (validate CSV, show plan, don't execute)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 -CsvPath "C:\input\vms.csv" -WhatIf


Example 4 - Custom results path and stop on first failure
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLIaaSVM-FromVault.ps1 `
        -CsvPath "C:\input\vms.csv" `
        -ResultsPath "C:\output\unregister-results.csv" `
        -StopOnFirstFailure


RESULTS OUTPUT
--------------
The script outputs a summary table to the console:

    Row  VMName                Status     Duration  Mode
    -------------------------------------------------------------------
    1    sql-vm-01             Success       52.3s  Unregister
    2    sql-vm-02             Success       18.4s  StopAll
    3    sql-vm-03             Failed         5.2s  StopDB: SalesDB
    -------------------------------------------------------------------

A results CSV is automatically exported with columns:
  Row, VMName, VaultName, Mode, Status, ExitCode, DurationSeconds, Error


DEFAULT BEHAVIOR
----------------
  - Default mode is Unregister (stop all + unregister). Override with
    -DefaultMode StopAll or -DefaultMode StopProtectionOnly.
  - -SkipConfirmation is always passed to the Unregister script.
  - Authentication is performed ONCE and the token is reused for all VMs.
  - Each VM is processed independently; one failure does not affect others
    (unless -StopOnFirstFailure is specified).
  - Parallelized stop-protection is used within each VM (fire all stop
    requests, then poll all together).


SAFETY GUARANTEES
-----------------
  - Recovery points are NEVER deleted.
  - Stop protection always uses "retain data" mode.
  - No soft-delete, no delete-data, no permanent removal operations.
  - Results CSV provides audit trail of all actions taken.


ERROR HANDLING
--------------
  - CSV validation errors:  Listed with row numbers before execution starts.
  - Missing columns:        Shows required and optional column names.
  - Per-VM failures:        Captured with exit code and error message.
                            Processing continues unless -StopOnFirstFailure.
  - Auth failure:           Script exits immediately.
  - Unregister script missing: Script exits with path guidance.


API VERSION
-----------
  Uses Unregister-SQLIaaSVM-FromVault.ps1 which uses: 2025-08-01


RECENT FIXES (March 19, 2026)
-----------------------------
  - Cross-RG container matching: The inner Unregister script now matches
    protected items by full container name pattern (including resource
    group) to prevent operating on databases from VMs with the same name
    in different resource groups.
  - Results CSV: Machine name now included in default results filename.


PUBLIC DOCUMENTATION
--------------------
  Azure Backup REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/

  Manage SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api

================================================================================

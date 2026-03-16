================================================================================
  Bulk-RegisterSQLIaaSVM-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
CSV-driven bulk wrapper for Register-SQLIaaSVM-ToVault.ps1. Authenticates
once to Azure, then processes multiple VMs from a CSV file, calling the
Register script for each row with a shared pre-fetched token.

Designed for onboarding many SQL VMs to Azure Backup in a single run.


HOW IT WORKS
------------
  1. Validates the CSV file (required columns, no empty required fields).
  2. Shows an execution plan listing each VM, mode, and policy.
  3. Authenticates once (Azure PowerShell or Azure CLI).
  4. Loops through each CSV row, calling Register-SQLIaaSVM-ToVault.ps1
     with the row's parameters and the shared -Token.
  5. Captures per-VM status, exit code, and duration.
  6. Outputs a summary table and exports a results CSV.


PREREQUISITES
-------------
  - Register-SQLIaaSVM-ToVault.ps1 must be in the SAME directory.
  - Azure PowerShell (Connect-AzAccount) or Azure CLI (az login).
  - Appropriate RBAC permissions on all vaults and VMs in the CSV.


PARAMETERS
----------
  -CsvPath              [Required]  Path to the input CSV file.
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
    VMResourceGroup, VMName, PolicyName

  Optional columns:
    InstanceName, DatabaseName, EnableAutoProtection, AutoProtectAllInstances


EXAMPLE CSV - Auto-protect all instances (most common)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,PolicyName
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01,HourlyLogBackup
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-02,HourlyLogBackup
  af95aa3c-...,rg-vault,myVault,rg-prod,sql-prod-01,DailyFullBackup

  When no mode columns are specified, the script defaults to
  AutoProtectAllInstances=true for each row.


EXAMPLE CSV - Mixed scenarios
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,InstanceName,DatabaseName,PolicyName,EnableAutoProtection,AutoProtectAllInstances
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-01,,,,true,true
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-02,MSSQLSERVER,,,true,
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-03,,SalesDB,HourlyLogBackup,,
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-vm-04,SQLEXPRESS,ReportsDB,DailyFullBackup,,

  Row 1: Auto-protect ALL instances on sql-vm-01
  Row 2: Auto-protect MSSQLSERVER instance only on sql-vm-02
  Row 3: Protect individual DB "SalesDB" on sql-vm-03
  Row 4: Protect "ReportsDB" in SQLEXPRESS instance on sql-vm-04


EXAMPLES
--------

Example 1 - Process all VMs in the CSV
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath "C:\input\vms.csv"


Example 2 - Dry run (validate CSV, show plan, don't execute)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 -CsvPath "C:\input\vms.csv" -WhatIf


Example 3 - Custom results path and stop on first failure
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-RegisterSQLIaaSVM-ToVault.ps1 `
        -CsvPath "C:\input\vms.csv" `
        -ResultsPath "C:\output\registration-results.csv" `
        -StopOnFirstFailure


RESULTS OUTPUT
--------------
The script outputs a summary table to the console:

    Row  VMName                Status     Duration  Mode
    -------------------------------------------------------------------
    1    sql-vm-01             Success       45.2s  AutoProtectAllInstances
    2    sql-vm-02             Success       38.7s  EnableAutoProtection
    3    sql-vm-03             Failed        12.1s  IndividualDB
    4    sql-vm-04             Success       41.5s  IndividualDB
    -------------------------------------------------------------------

A results CSV is automatically exported with columns:
  Row, VMName, VaultName, ProtectionMode, PolicyName, Status,
  ExitCode, DurationSeconds, Error


DEFAULT BEHAVIOR
----------------
  - If a CSV row has no EnableAutoProtection, AutoProtectAllInstances,
    or DatabaseName column/value, the script defaults to
    AutoProtectAllInstances=true (the safest bulk onboarding option).
  - Authentication is performed ONCE and the token is reused for all VMs.
  - Each VM is processed independently; one failure does not affect others
    (unless -StopOnFirstFailure is specified).


ERROR HANDLING
--------------
  - CSV validation errors:  Listed with row numbers before execution starts.
  - Missing columns:        Shows required and optional column names.
  - Per-VM failures:        Captured with exit code and error message.
                            Processing continues unless -StopOnFirstFailure.
  - Auth failure:           Script exits immediately.
  - Register script missing: Script exits with path guidance.


PUBLIC DOCUMENTATION
--------------------
  Azure Backup REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/

  Back up SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sql-vm-rest-api

================================================================================

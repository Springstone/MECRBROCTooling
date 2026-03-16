================================================================================
  Restore-SQLIaaSVM-FromVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Restores SQL Server databases from Azure Backup on Azure IaaS VMs using the
Azure Backup REST API. Supports Alternate Location Restore (ALR), Restore as
Files, and Point-in-Time (Log) restore for both types.

Recovery points are selected interactively or via parameter. The script lists
available recovery points (Full, Differential, and Log time ranges) and lets
you choose one. Source database file paths are automatically fetched from the
recovery point's extended info for accurate file placement.


RESTORE TYPES
-------------

  ALR (Alternate Location Restore)
    Restores a database to a DIFFERENT database name on the same or a
    different SQL Server VM.
    - Target VM must be registered to the same vault
    - Requires: -TargetVMName, -TargetVMResourceGroup, -TargetDatabaseName,
                -TargetDataPath, -TargetLogPath
    - TargetDatabaseName format: INSTANCENAME/DatabaseName
      Example: MSSQLSERVER/SalesDB_Restored
    - TargetDataPath: directory for .mdf/.ndf files (filename auto-generated)
    - TargetLogPath: directory for .ldf files (filename auto-generated)
    - Supports Point-in-Time restore with -PointInTime parameter

  RestoreAsFiles
    Restores backup as .bak and .log files to a directory on a target VM.
    - Useful for manual restore or migration scenarios
    - Target VM must be registered to the same vault
    - Requires: -TargetVMName, -TargetVMResourceGroup, -TargetFilePath
    - TargetFilePath is the directory path on the target VM
      Example: D:\Backup1234
    - Supports Point-in-Time restore with -PointInTime parameter


FILE PATH HANDLING (ALR)
------------------------
When -TargetDataPath and -TargetLogPath are provided, the script:

  1. Fetches the recovery point's extended info to get the source database
     file layout (logical names, source paths, file extensions).
  2. Constructs target filenames using the target database name:
       Data: {TargetDBName}.mdf   (preserves original extension)
       Log:  {TargetDBName}_log.ldf

  Example with -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored":
    Source:  F:\data\SalesDB.mdf       -> Target: D:\SQLData\SalesDB_Restored.mdf
    Source:  G:\log\SalesDB_log.ldf    -> Target: D:\SQLLogs\SalesDB_Restored_log.ldf

  The source logical names and paths are included in the request body,
  matching exactly what the Azure Portal sends.

  For Point-in-Time restores, the script fetches file layout from the
  latest Full recovery point (since DefaultRangeRecoveryPoint doesn't
  have file layout info).


WORKFLOW
--------
  1. Authenticates to Azure (PowerShell or CLI).
  2. Lists protected SQL databases on the source VM.
     - Groups databases by instance when multiple SQL instances exist.
     - Filters to -InstanceName if provided.
     If -DatabaseName not specified, shows numbered list for selection.
  3. Lists recovery points (Full, Differential, Log) for the selected database.
     If -RecoveryPointId not specified, shows numbered list for selection.
     For Point-in-Time restore, shows available log time ranges.
  3B. Fetches recovery point extended info (source file paths and logical names).
  4. Resolves the target VM container (ALR and RestoreAsFiles).
     Looks up the target VM's registration in the vault.
  5. Builds the restore request body based on RestoreType.
     Constructs alternateDirectoryPaths with source file info and target paths.
  6. Triggers the restore operation (POST to /restore endpoint).
  7. Tracks the async operation and shows job status.


WHERE TO RUN
------------
- PowerShell 7+ (Windows, macOS, or Linux) or Windows PowerShell 5.1.
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A - Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B - Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Operator or Backup Contributor on the Recovery Services Vault.
- For ALR/RestoreAsFiles: target VM must be registered to the same vault.


PARAMETERS
----------
  Required for ALL restore types:
    -VaultSubscriptionId    Subscription ID of the vault.
    -VaultResourceGroup     Resource group of the vault.
    -VaultName              Name of the Recovery Services Vault.
    -VMResourceGroup        Resource group of the source SQL Server VM.
    -VMName                 Name of the source VM (where backup was taken).
    -RestoreType            Type of restore: ALR or RestoreAsFiles.

  Required for ALR:
    -TargetVMName           Name of the target VM.
    -TargetVMResourceGroup  Resource group of the target VM.
    -TargetDatabaseName     Target DB name: INSTANCENAME/DatabaseName
    -TargetDataPath         Directory for data files (.mdf/.ndf). Example: D:\SQLData
    -TargetLogPath          Directory for log files (.ldf). Example: D:\SQLLogs

  Required for RestoreAsFiles:
    -TargetVMName           Name of the target VM.
    -TargetVMResourceGroup  Resource group of the target VM.
    -TargetFilePath         Directory for .bak/.log files. Example: D:\Backup1234

  Optional:
    -InstanceName           SQL instance name (e.g. MSSQLSERVER, SQLEXPRESS).
                            Filters source databases to this instance.
                            Useful when same DB name exists in multiple instances.
    -DatabaseName           SQL database to restore. If omitted, lists DBs
                            for selection.
    -RecoveryPointId        Recovery point ID. If omitted, lists RPs for
                            selection.
    -PointInTime            ISO 8601 datetime for log restore.
                            Example: "2026-03-12T18:30:00Z"
    -OverwriteExisting      Switch to overwrite existing DB/files.
                            Default: FailOnConflict.


SCENARIOS
---------

  1. Source Database Selection
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  (no -DatabaseName)                              Yes - lists DBs for selection
  -DatabaseName "X"                               NO (prompts if ambiguous)
  -DatabaseName "X" -InstanceName "I"             NO - exact match
  -DatabaseName "X" (exists in 2+ instances)      Prompts to pick instance


API VERSION
-----------
  - 2025-08-01   All operations (list items, recovery points, restore trigger)


RECOVERY POINT TYPES
---------------------
  Full          A complete backup of the database.
  Differential  Changes since the last full backup.
  Log           Transaction log backup. Used for Point-in-Time restore.
                Shows as "DefaultRangeRecoveryPoint" with time ranges.

  The interactive selection shows:
    Full / Differential Recovery Points:
    ------------------------------------
    [1] ID: 153931404499070
         Time (UTC): 2026-03-12T18:13:22Z
         Type:       Full
    [2] ID: 147803510384029
         Time (UTC): 2026-03-12T18:23:08Z
         Type:       Differential

    Log Restore Time Ranges (for Point-in-Time restore):
    ----------------------------------------------------
      From: 2026-03-12T18:13:22Z  To: 2026-03-12T18:46:25Z

  For Point-in-Time restore, the -PointInTime value must fall within
  the displayed log time range.


TARGET DATABASE NAME FORMAT
---------------------------
  Format: INSTANCENAME/DatabaseName

  Examples:
    MSSQLSERVER/SalesDB_Restored     (default instance)
    SQLEXPRESS/SalesDB_Copy          (named instance)
    MSSQLSERVER/TestDB_PIT_Restore   (point-in-time restore)

  The instance name must match a SQL instance on the target VM.
  Common instance names:
    MSSQLSERVER    (default instance)
    SQLEXPRESS     (SQL Express edition)


EXAMPLES
--------

Example 1 - Full ALR: Restore to a different database name (interactive)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -RestoreType ALR `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored" `
        -TargetDataPath "D:\SQLData" `
        -TargetLogPath "D:\SQLLogs"

  The script will:
    1. List protected databases - you pick one
    2. List recovery points (Full/Differential) - you pick one
    3. Fetch source file paths from the recovery point
    4. Restore as SalesDB_Restored with:
         Data: D:\SQLData\SalesDB_Restored.mdf
         Log:  D:\SQLLogs\SalesDB_Restored_log.ldf


Example 2 - Full ALR: With all parameters (non-interactive)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -RestoreType ALR `
        -RecoveryPointId "153931404499070" `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored" `
        -TargetDataPath "D:\SQLData" `
        -TargetLogPath "D:\SQLLogs"


Example 3 - Restore from a specific instance (multi-instance VM)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -InstanceName "SQLEXPRESS" `
        -DatabaseName "SalesDB" `
        -RestoreType ALR `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_Restored" `
        -TargetDataPath "D:\SQLData" `
        -TargetLogPath "D:\SQLLogs"

  Restores SalesDB specifically from the SQLEXPRESS instance.


Example 4 - Point-in-Time ALR
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -RestoreType ALR `
        -PointInTime "2026-03-12T18:30:00Z" `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_PIT" `
        -TargetDataPath "D:\SQLData" `
        -TargetLogPath "D:\SQLLogs"

  Uses DefaultRangeRecoveryPoint automatically. No recovery point selection.
  Source file layout is fetched from the latest Full recovery point.


Example 5 - Restore as Files (Full)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -RestoreType RestoreAsFiles `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetFilePath "D:\Backup1234"


Example 6 - Restore as Files (Point-in-Time)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -RestoreType RestoreAsFiles `
        -PointInTime "2026-03-12T18:30:00Z" `
        -TargetVMName "sql-vm-01" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetFilePath "D:\Backup1234"


Example 7 - ALR to a different VM
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -RestoreType ALR `
        -TargetVMName "sql-vm-02" `
        -TargetVMResourceGroup "rg-sql" `
        -TargetDatabaseName "MSSQLSERVER/SalesDB_Copy" `
        -TargetDataPath "F:\Data" `
        -TargetLogPath "G:\Log"

  Target VM must be registered to the same vault.


ALL RESTORE COMBINATIONS
-------------------------
  RestoreType     PointInTime     Result
  -----------     -----------     ------
  ALR             Not specified   Full/Differential recovery ALR
  ALR             Specified       Point-in-Time ALR (log restore)
  RestoreAsFiles  Not specified   Full restore as .bak files
  RestoreAsFiles  Specified       Point-in-Time restore as .bak files


SMART BEHAVIORS
---------------
  - Multiple instances:     Groups databases by instance in the display.
  - -DatabaseName in 2+ instances: Prompts to pick, suggests -InstanceName.
  - -InstanceName not found: Lists available instances, exits with error.
  - Single database:        Auto-selects it without prompting.
  - ARM IDs lowercased:     All ARM resource IDs in the request body are
                            automatically lowercased (API requirement).
  - Source file info:       Fetched from recovery point extended info for
                            accurate file placement in ALR.
  - PIT file layout:        For Point-in-Time restores, fetches file layout
                            from the latest Full recovery point.


IMPORTANT NOTES
---------------
  - ARM Resource IDs: The Azure Backup restore API requires LOWERCASE ARM
    resource IDs in the request body. The script handles this automatically.
  - Source File Info: The script fetches source file paths and logical names
    from the recovery point's extended info. This is required for custom
    data/log paths to work correctly.
  - For PIT restores with custom paths, the script uses the latest Full
    recovery point to get the file layout (DefaultRangeRecoveryPoint doesn't
    contain file layout info).
  - Default overwrite behavior is FailOnConflict. Use -OverwriteExisting
    to overwrite an existing target database.


ERROR HANDLING
--------------
Common issues:

  - BMSUserErrorInvalidInput (400):
      Check that all ARM resource IDs are lowercase.
      Verify alternateDirectoryPaths have sourceLogicalName and sourcePath.
      Ensure PointInTime is within the available log time range.

  - Target VM not registered:
      The target VM must be registered to the same vault.
      Use Register-SQLIaaSVM-ToVault.ps1 to register it first.

  - Recovery point not found:
      Check the recovery point ID. Use the interactive selection to see
      available recovery points.

  - Point-in-Time out of range:
      The PointInTime value must fall within the available log time range
      shown by the script.

  - Restore fails with conflict:
      Target database already exists. Use -OverwriteExisting or choose
      a different target database name.

  - SecureString token:
      Newer Az.Accounts modules return SecureString tokens.
      The script handles both formats automatically
      (uses NetworkCredential method for cross-platform).


PUBLIC DOCUMENTATION
--------------------
  Restore SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/restore-azure-sql-vm-rest-api

  Restores - Trigger:
    https://learn.microsoft.com/en-us/rest/api/backup/restores/trigger

  Recovery Points - List:
    https://learn.microsoft.com/en-us/rest/api/backup/recovery-points/list

  Azure Backup REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/

================================================================================

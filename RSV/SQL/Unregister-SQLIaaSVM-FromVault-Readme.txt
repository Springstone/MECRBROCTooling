================================================================================
  Unregister-SQLIaaSVM-FromVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Stops backup protection for SQL Server databases on Azure IaaS VMs and
optionally unregisters the VM container from a Recovery Services Vault using
the Azure Backup REST API. Recovery points are ALWAYS PRESERVED (retain data).
No backup data is ever deleted by this script.


TWO OPERATIONAL MODES
---------------------

  MODE 1: Stop Protection with Retain Data (default, no -Unregister)
    - Lists all protected SQL databases on the VM
    - Stops protection while retaining existing recovery points
    - Databases remain associated with the vault container
    - No new backups are triggered; existing recovery points remain accessible
    - Optionally prompts to unregister after all DBs are stopped

  MODE 2: Stop Protection + Unregister (-Unregister)
    - Stops protection with retain data for ALL databases on the VM
    - Waits 30 seconds for operations to propagate
    - Unregisters the VM container from the vault
    - Recovery points are preserved in the vault
    - All databases on the VM are processed (cannot target individual DBs)
    - -DatabaseName and -InstanceName are ignored; -StopAll is implied


WORKFLOW (with -Unregister)
---------------------------
  1. Lists all protected SQL databases on the VM.
  2. Shows confirmation prompt listing all DBs that will be stopped.
     (Skipped if -SkipConfirmation is specified.)
  3. Stops protection with retain data for all active databases.
     (Skips databases already in ProtectionStopped state.)
  4. Shows confirmation prompt before unregistering.
     (Skipped if -SkipConfirmation is specified.)
  5. Waits 30 seconds for the stop operations to propagate.
  6. Unregisters the VM container via DELETE on protectionContainers.
  7. Displays final summary.


WORKFLOW (without -Unregister)
-------------------------------
  1. Lists all protected SQL databases on the VM.
     - Groups databases by instance when multiple SQL instances exist.
     - Filters to -InstanceName if provided.
  2. Stops protection with retain data for selected database(s):
     - Specific DB if -DatabaseName provided
       (filtered by -InstanceName if also provided)
     - All DBs (or all in selected instance) if -StopAll specified
     - Interactive selection if neither specified (numbered list with [A] for All)
  3. If all DBs are now stopped, prompts: "Unregister VM? [Y/N, default: N]"
     - If Y: re-runs the script with -Unregister flag
     - If N: exits with summary


CONFIRMATION PROMPTS
--------------------
When -Unregister is specified (without -SkipConfirmation), two prompts appear:

  Prompt 1 - Before stopping protection:
    "The following 3 database(s) will have protection STOPPED (data retained):
       - master (State: Protected)
       - SalesDB (State: Protected)
       - msdb (State: Protected)
     Proceed with stop protection? [Y/N, default: Y]"

    This prompt is SKIPPED if all DBs are already in ProtectionStopped state.

  Prompt 2 - Before unregistering:
    "Container '...' will be UNREGISTERED from vault '...'.
     Recovery points will be retained in the vault.
     Proceed with unregistration? [Y/N, default: Y]"

    This prompt ALWAYS appears before unregistration (unless -SkipConfirmation).

  To skip both prompts (for automation): add -SkipConfirmation


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
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the target Virtual Machine.


PARAMETERS
----------
  -VaultSubscriptionId    [Required]  Subscription ID of the vault.
  -VaultResourceGroup     [Required]  Resource group of the vault.
  -VaultName              [Required]  Name of the Recovery Services Vault.
  -VMResourceGroup        [Required]  Resource group of the SQL Server VM.
  -VMName                 [Required]  Name of the Azure VM hosting SQL Server.
  -InstanceName           [Optional]  SQL instance name (e.g. MSSQLSERVER,
                                      SQLEXPRESS). Filters databases to only
                                      those in this instance.
                                      Ignored when -Unregister is specified.
  -DatabaseName           [Optional]  Specific DB to stop protection for.
                                      Ignored when -Unregister is specified.
  -Unregister             [Optional]  Stop all DBs + unregister the VM
                                      container. Processes ALL instances/DBs.
                                      -InstanceName and -DatabaseName ignored.
  -StopAll                [Optional]  Stop protection for ALL DBs without
                                      prompting. Respects -InstanceName filter.
                                      Implied when -Unregister is used.
  -SkipConfirmation       [Optional]  Skip all confirmation prompts (Y/N).
                                      Use for automation/scripting.
  -Token                  [Optional]  Pre-fetched bearer token. When provided,
                                      skips authentication. Used by the bulk
                                      wrapper script to avoid re-authenticating
                                      per VM. Not needed for standalone use.


API VERSION
-----------
  - 2025-08-01   All operations (list items, stop protection, unregister)


SCENARIOS
---------

  1. Stop Protection - Specific Database
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  -DatabaseName "X"                               NO (prompts if ambiguous)
  -DatabaseName "X" -InstanceName "I"             NO - exact match
  -DatabaseName "X" (exists in 2+ instances)      Prompts to pick instance

  2. Stop Protection - All Databases
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  -StopAll                                        NO - stops all DBs
  -StopAll -InstanceName "I"                      NO - stops all DBs in instance I
  (no params)                                     Yes - interactive selection

  3. Unregister
  ~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  -Unregister                                     Prompts for confirmation (x2)
  -Unregister -SkipConfirmation                   NO - fully unattended


PROTECTION STATES
-----------------
The script handles the following protection states:

  Protected           Actively protected, backups running per schedule.
                      Will be STOPPED by this script.

  IRPending           Initial replication pending, first backup not yet done.
                      Will be STOPPED by this script.

  ProtectionError     Protection configured but in error state.
                      Will be STOPPED by this script.

  ProtectionPaused    Protection temporarily paused.
                      Will be STOPPED by this script.

  BackupsSuspended    Backups suspended at vault level.
                      Will be STOPPED by this script.

  ProtectionStopped   Protection already stopped.
                      SKIPPED (no action needed).


EXAMPLES
--------

Example 1 - Stop protection for a specific database (retain data)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB"


Example 2 - Stop protection for a database in a specific instance
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -InstanceName "SQLEXPRESS" `
        -DatabaseName "SalesDB"

  Targets SalesDB specifically in the SQLEXPRESS instance.


Example 3 - Stop ALL databases in a specific instance
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -StopAll `
        -InstanceName "MSSQLSERVER"

  Stops protection for all DBs under MSSQLSERVER only.
  Databases under other instances are not affected.


Example 4 - Stop ALL databases + unregister the VM (with confirmations)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -Unregister

  You will be prompted twice:
    1. "Proceed with stop protection? [Y/N, default: Y]"
    2. "Proceed with unregistration? [Y/N, default: Y]"
  -InstanceName is ignored; ALL instances/DBs are processed.


Example 5 - Stop ALL + unregister (no prompts, for automation)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -Unregister -SkipConfirmation


Example 6 - Interactive mode (lists DBs, prompts for selection)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-SQLIaaSVM-FromVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01"

  Shows a numbered list (grouped by instance if multiple exist):
    [MSSQLSERVER]
      [1] master (State: Protected)
      [2] SalesDB (State: Protected)

    [SQLEXPRESS]
      [3] ReportsDB (State: Protected)

  After stopping, prompts: "Unregister VM? [Y/N, default: N]"


SMART BEHAVIORS
---------------
  - Already stopped:      Skips DBs already in ProtectionStopped state.
  - All DBs stopped:      Prompts to unregister (interactive mode).
  - No protected DBs:     Prompts to unregister (VM may be registered
                          but all DBs already unprotected).
  - Multiple instances:   Groups databases by instance in the display.
  - -DatabaseName in 2+ instances: Prompts to pick, suggests -InstanceName.
  - -InstanceName not found: Lists available instances, exits with error.
  - 30-second wait:       Waits after stop operations before unregistering
                          to allow API propagation.
  - Container name:       Extracted from protected items API response.
                          Falls back to container lookup if initial query
                          misses items due to VM name case mismatch.
  - Case-insensitive:     VM name matching uses exact container name pattern
                          (;vmName suffix) to avoid matching VMs with
                          similar names (e.g., sql-vm vs sql-vm-01).
  - Re-query on mismatch: If initial item query finds 0 results but container
                          exists, re-queries using the discovered container
                          name for exact matching.


OUTPUT
------
Color-coded console output:
  - Cyan:    Section headers, prompts, progress
  - Magenta: Important warnings about what will happen
  - Yellow:  Warnings, skipped items (already stopped), instance headers
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - Red:     Errors


ERROR HANDLING
--------------
Common issues:

  - BMSUserErrorContainerHasDatasources:
      Some databases still have active protection or the stop operations
      haven't propagated yet. Wait a few minutes and retry.

  - 401 Unauthorized:
      Wrong subscription/tenant. Run Connect-AzAccount with correct params.

  - No protected items found:
      VM may not be registered, or all DBs are already unprotected.
      Script will attempt container lookup and re-query.

  - Stop protection fails:
      Check VM is running, RBAC permissions, active backup/restore jobs.

  - SecureString token:
      Newer Az.Accounts modules return SecureString tokens.
      The script handles both formats automatically
      (uses NetworkCredential method for cross-platform).


SAFETY GUARANTEES
-----------------
  - Recovery points are NEVER deleted by this script.
  - Stop protection always uses "retain data" mode (empty policyId).
  - No soft-delete, no delete-data, no permanent removal operations.
  - Confirmation prompts before destructive actions (unless -SkipConfirmation).
  - Already-stopped databases are automatically skipped.


RECENT FIXES (March 19, 2026)
-----------------------------
  - Cross-RG container matching: Protected item filtering now uses full
    container name pattern (VMAppContainer;Compute;{RG};{VM}) as primary
    match instead of last-segment-only matching. Prevents operating on
    databases from a VM with the same name in a different resource group.
  - Fallback with warning: If no items match by full container name,
    falls back to name-only matching with a WARNING message so users
    know the match is not RG-verified.


PUBLIC DOCUMENTATION
--------------------
  Manage SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api

  Protected Items - Create or Update (Stop Protection):
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update

  Protection Containers - Unregister:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister

  Azure Backup REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/

================================================================================

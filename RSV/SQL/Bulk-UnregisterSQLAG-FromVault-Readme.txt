================================================================================
  Bulk-UnregisterSQLAG-FromVault.ps1 - README
================================================================================

VERSION
-------
  v1.1 - March 19, 2026


DESCRIPTION
-----------
Self-contained bulk script for unregistering physical SQL IaaS VM containers
that participate in SQL Always On Availability Groups from a Recovery Services
Vault.

Handles the complex AG workflow where:
  - Standalone databases on the physical container are stopped with RETAIN DATA.
  - AG databases on AG containers are stopped with DELETE DATA (soft-deleted),
    then UNDELETED after the physical container is unregistered.

End state: all recovery points are preserved, and the physical VM container
is unregistered.


API VERSION
-----------
  Uses REST API version: 2025-08-01
  (Same as Unregister-SQLIaaSVM-FromVault.ps1)


HOW IT WORKS
------------
  Step 1:   Validates the CSV file (required columns, no empty fields).
  Step 2:   Authenticates once (Azure PowerShell or Azure CLI).
  Step 3:   Checks vault soft-delete setting; enables if disabled (CRITICAL).
  Step 4:   Discovers all containers in the vault (physical + AG).
            - Physical containers via backupProtectionContainers API.
            - AG containers discovered from protected items, then queried
              individually for node details.
            - AG container matching uses sourceResourceId (VM name + RG)
              to prevent cross-RG false matches.
  Step 5:   Lists and classifies all protected SQL databases:
              - Standalone DBs (on physical container) -> stop-retain
              - AG DBs (on AG container) -> stop-delete
  Step 6:   Displays execution plan and prompts for confirmation.
  Step 7:   Stops protection with RETAIN DATA for standalone databases.
  Step 8:   Stops protection with DELETE DATA for AG databases (soft-deleted).
  Step 9:   Unregisters the physical container(s) from the vault.
  Step 10:  Waits 3 minutes for propagation + refreshes auth token.
  Step 11:  Undeletes soft-deleted AG databases (foolproof multi-phase retry).
  Step 12:  Exports results CSV and displays final summary.


WHY STOP-DELETE + UNDELETE FOR AG DATABASES?
---------------------------------------------
AG databases belong to the AG container, not the physical VM container.
To unregister a physical VM that is a node in an AG container, the AG
database protection must be fully removed (not just stopped). The
stop-delete operation removes the protection reference, allowing the
physical container to be unregistered. The subsequent undelete restores
the recovery points back to a ProtectionStopped state, preserving all data.

This is why soft delete MUST be enabled on the vault before any operations.


PREREQUISITES
-------------
  - Azure PowerShell (Connect-AzAccount) or Azure CLI (az login).
  - Appropriate RBAC permissions on all vaults and VMs in the CSV.
  - SQL VMs must be registered with the vault.
  - SQL databases must be in Protected/IRPending/ProtectionStopped state.


PARAMETERS
----------
  -CsvPath              [Required]  Path to the input CSV file.
  -SkipConfirmation     [Optional]  Skip all prompts. Auto-enables soft
                                    delete if disabled. Use for automation.
  -ResultsPath          [Optional]  Path for the results CSV. If omitted,
                                    auto-generated next to the input CSV.
                                    Default naming convention:
                                      {CsvBaseName}_results_{MachineName}_{yyyyMMdd_HHmmss}.csv
  -StopOnFirstFailure   [Optional]  Stop processing remaining VMs if any
                                    VM fails.
  -Token                [Optional]  Pre-fetched bearer token. Skips
                                    authentication when provided.
  -WhatIf               [Optional]  Discover containers and databases,
                                    display the execution plan, but do
                                    NOT execute any changes.


CSV FORMAT
----------

  Required columns:
    VaultSubscriptionId, VaultResourceGroup, VaultName,
    VMResourceGroup, VMName


EXAMPLE CSV
~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-ag-node-01
  af95aa3c-...,rg-vault,myVault,rg-sql,sql-ag-node-02
  af95aa3c-...,rg-vault,myVault,rg-prod,sql-ag-node-03

  The script automatically discovers AG containers where these VMs
  appear as nodes, and classifies databases accordingly.


EXAMPLES
--------

Example 1 - Interactive run (prompts for confirmation)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath "C:\input\ag-vms.csv"

  The script will:
    - Discover containers and databases
    - Check/prompt to enable soft delete if disabled
    - Display the execution plan (standalone vs AG databases)
    - Prompt for confirmation before proceeding
    - Execute the full workflow
  Results saved to: ag-vms_results_MYPC_20260319_143522.csv


Example 2 - Fully non-interactive (automation)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLAG-FromVault.ps1 `
        -CsvPath "C:\input\ag-vms.csv" `
        -SkipConfirmation

  Skips all prompts. If soft delete is disabled, it is automatically
  enabled. All operations proceed without user interaction.


Example 3 - Dry run (discover only, no changes)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLAG-FromVault.ps1 -CsvPath "C:\input\ag-vms.csv" -WhatIf

  Validates the CSV, discovers containers and databases, classifies
  them, and displays the execution plan. No changes are made.


Example 4 - Custom results path
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-UnregisterSQLAG-FromVault.ps1 `
        -CsvPath "C:\input\ag-vms.csv" `
        -ResultsPath "C:\output\ag-unregister-results.csv" `
        -SkipConfirmation


RESULTS OUTPUT
--------------
  Default results file naming convention:
    {CsvBaseName}_results_{MachineName}_{yyyyMMdd_HHmmss}.csv

  Example:
    Input:  Sample-BulkUnregisterAG-Pass1.csv
    Output: Sample-BulkUnregisterAG-Pass1_results_YOURPC_20260319_143522.csv

  The results file is saved in the same folder as the input CSV.

  The script outputs a summary table grouped by vault and phase:

    Vault          Phase                     Status     Details
    -------------------------------------------------------------------
    myVault        Stop-Retain Standalone    Success    Succeeded: 3, ...
    myVault        Stop-Delete AG DBs        Success    Succeeded: 5, ...
    myVault        Unregister Containers     Success    Succeeded: 2, ...
    myVault        Undelete AG DBs           Success    Succeeded: 5, ...
    -------------------------------------------------------------------


SOFT DELETE BEHAVIOR
--------------------
  Soft delete is MANDATORY for this script because it performs
  stop-protection with DELETE DATA for AG databases.

  The vault config API (backupconfig/vaultconfig) supports:
    - softDeleteFeatureState:          Enabled | Disabled | AlwaysON
    - enhancedSecurityState:           Enabled | Disabled | AlwaysON
    - softDeleteRetentionPeriodInDays: integer (default: 14)
    - isSoftDeleteFeatureStateEditable: boolean (read-only)

  The script only requires softDeleteFeatureState. It does NOT modify
  enhancedSecurityState or softDeleteRetentionPeriodInDays.

  Behavior with -SkipConfirmation:
    - Soft delete Enabled/AlwaysON: Proceed immediately.
    - Soft delete Disabled: Auto-enable and wait 2 minutes.

  Behavior without -SkipConfirmation:
    - Soft delete Enabled/AlwaysON: Proceed immediately.
    - Soft delete Disabled: Prompt user to enable.
      - Yes: Enable and wait 2 minutes.
      - No:  Script fails immediately (data safety).


FOOLPROOF UNDELETE MECHANISM
------------------------------
  The undelete phase uses a multi-phase approach to ensure data recovery:

  Phase 1: Direct undelete using stored item IDs (3 retries each).
  Phase 2: Re-query the vault, match failed items by friendlyName AND
           containerName, retry with correct IDs (handles ID changes
           after container unregistration).
  Phase 3: Extended retry with exponential backoff (5 attempts,
           30s-150s delays) for persistent failures.
  Phase 4: Final verification - re-queries the vault and confirms each
           AG database is no longer in SoftDeleted state.

  All phases match items by both friendlyName AND containerName to
  prevent cross-container false matches when multiple AG containers
  have databases with the same name.

  If any items remain undeleted after all phases, the script reports
  them with action-required instructions for manual recovery.


TOKEN REFRESH
-------------
  The script refreshes the Azure bearer token after the 3-minute
  propagation wait (Step 10), before starting undelete operations.
  This prevents 401 authentication failures on long-running executions.

  Token refresh is skipped when a pre-fetched token is provided via
  the -Token parameter (for external automation scenarios).


EXECUTION FLOW DIAGRAM
-----------------------

  CSV Input
    |
    v
  Validate CSV --> Authenticate --> Check Soft Delete
                                        |
                               [Disabled?] --> [Prompt/Auto-Enable]
                                        |                |
                                [Enabled] <----- [Wait 2 min]
                                        |
                                        v
                              Discover Containers
                              (Physical + AG)
                                        |
                                        v
                              Discover Protected Items
                              (Classify: Standalone vs AG)
                                        |
                                        v
                              Display Plan & Confirm
                                        |
                                        v
                    +-------------------+-------------------+
                    |                                       |
            Stop-Retain                              Stop-Delete
            (Standalone DBs)                         (AG DBs)
                    |                                       |
                    +-------------------+-------------------+
                                        |
                                        v
                              Unregister Physical Container(s)
                                        |
                                        v
                              Wait 3 Minutes + Refresh Token
                                        |
                                        v
                              Undelete AG DBs (Foolproof)
                              Phase 1: Direct retry
                              Phase 2: Re-query + retry (name+container)
                              Phase 3: Extended backoff
                              Phase 4: Verification (name+container)
                                        |
                                        v
                              Summary & Results Export


SAFETY GUARANTEES
-----------------
  - Soft delete is enforced BEFORE any delete operations.
  - If soft delete cannot be enabled, the script fails immediately.
  - Standalone DB recovery points are directly preserved (stop-retain).
  - AG DB recovery points are preserved via soft-delete + undelete.
  - Multi-phase undelete ensures maximum recoverability.
  - Undelete matching uses both friendlyName AND containerName to
    prevent cross-container false matches.
  - Token is refreshed before undelete to prevent auth expiry.
  - Results CSV provides an audit trail of all actions taken.
  - WhatIf mode allows safe preview before execution.
  - Script is idempotent - safe to re-run on partial failures.


ERROR HANDLING
--------------
  - CSV validation errors:        Listed with row numbers before execution.
  - Soft delete failure:          Script aborts immediately (data safety).
  - Container not found:          Warning issued, VM skipped.
  - Stop-retain failures:         Logged per-DB, processing continues.
  - Stop-delete failures:         If ALL fail, script aborts (cannot safely
                                  proceed to unregister). Partial failures
                                  are logged and processing continues.
  - Unregister failures:          Logged per-container, undelete still
                                  attempted for any soft-deleted items.
    - BMSUserErrorContainerHasDatasources:
                                  Stop operations have not propagated.
                                  Wait and retry.
    - BMSUserErrorNodePartOfActiveAG:
                                  VM is a node in an AG container that
                                  still has protected/active items.
                                  Check AG containers from other RGs
                                  that also reference this VM.
  - Undelete failures:            Multi-phase retry. Final failures are
                                  reported with manual recovery instructions.
  - Auth failure:                 Script exits immediately.
  - Token expiry during long run: Token auto-refreshed before undelete.


KNOWN LIMITATIONS
-----------------
  - The script cannot unregister a VM container if it is a node in an
    AG container that still has protected items from a DIFFERENT set of
    VMs (not in the CSV). All AG databases referencing the VM must be
    stop-deleted first.
  - If the vault has enhancedSecurityState = AlwaysON, soft delete
    cannot be disabled even by an admin. The script does not modify
    enhancedSecurityState.
  - When using -Token, the token is not refreshed. Ensure the token
    has sufficient remaining lifetime (>20 minutes recommended).


PUBLIC DOCUMENTATION
--------------------
  Azure Backup REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/

  Manage SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/manage-azure-sql-vm-rest-api

  Soft Delete for Azure Backup:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-security-feature-cloud

  Backup Resource Vault Configs:
    https://learn.microsoft.com/en-us/rest/api/backup/backup-resource-vault-configs

================================================================================

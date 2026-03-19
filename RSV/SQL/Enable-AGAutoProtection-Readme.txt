================================================================================
  Enable-AGAutoProtection.ps1 - README
================================================================================

VERSION
-------
  v1.0 - March 19, 2026


DESCRIPTION
-----------
Discovers all SQL AG availability groups in a Recovery Services Vault and
enables auto-protection on them with a specified backup policy.

This ensures all current and future databases in AG groups are automatically
protected without needing to specify individual VMs or databases.


API VERSION
-----------
  2025-08-01


HOW IT WORKS
------------
  Step 1:  Validates the CSV file.
  Step 2:  Authenticates once (Azure PowerShell or Azure CLI).
  Step 3:  Resolves the backup policy by name.
  Step 4:  Discovers auto-protectable AG availability groups via the
           backupProtectableItems API (type: SQLAvailabilityGroupContainer).
  Step 5:  Displays execution plan and prompts for confirmation.
  Step 6:  Enables auto-protection on each AG via the
           backupProtectionIntent API (PUT with random GUID intent name).
  Step 7:  Exports results CSV and displays summary.


KEY CONCEPT
-----------
  AG availability groups appear as SQLAvailabilityGroupContainer protectable
  items in the vault. They are NOT listed by the backupProtectionContainers
  API (which only returns physical VMAppContainer containers).

  The script discovers them from backupProtectableItems where:
    - protectableItemType = "SQLAvailabilityGroupContainer"
    - isAutoProtectable = true

  Each AG group lives inside an sqlagworkloadcontainer;{guid} path and
  can be auto-protected independently from the physical VM instances.


PREREQUISITES
-------------
  - Azure PowerShell (Connect-AzAccount) or Azure CLI (az login).
  - SQL VMs must already be registered with the vault.
  - Inquiry must have been run on the VMs (so AGs are discovered).
  - Appropriate RBAC permissions on the vault.


PARAMETERS
----------
  -CsvPath              [Required]  Path to the input CSV file.
  -SkipConfirmation     [Optional]  Skip all prompts. Use for automation.
  -ResultsPath          [Optional]  Path for the results CSV. If omitted,
                                    auto-generated:
                                      {CsvBaseName}_results_{MachineName}_{yyyyMMdd_HHmmss}.csv
  -Token                [Optional]  Pre-fetched bearer token.
  -WhatIf               [Optional]  Discover only, no changes.


CSV FORMAT
----------

  Required columns:
    VaultSubscriptionId, VaultResourceGroup, VaultName, PolicyName


EXAMPLE CSV
~~~~~~~~~~~
  VaultSubscriptionId,VaultResourceGroup,VaultName,PolicyName
  af95aa3c-...,AzureBackupRG_kajai2025,myVault,HourlyLogBackup


EXAMPLES
--------

Example 1 - Auto-protect all AG groups (interactive)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv"

  Discovers AG1, AG2, etc. and prompts before enabling auto-protection.


Example 2 - Fully non-interactive
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv" -SkipConfirmation


Example 3 - Dry run (discover only)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Enable-AGAutoProtection.ps1 -CsvPath ".\ag-autoprotect.csv" -WhatIf

  Shows which AG groups would be auto-protected, without making changes.


RESULTS OUTPUT
--------------
  Default results file naming convention:
    {CsvBaseName}_results_{MachineName}_{yyyyMMdd_HHmmss}.csv

  Console summary table:
    Vault          Phase          Status     Details
    -------------------------------------------------------------------
    myVault        Auto-Protect   Success    Succeeded: 2, Failed: 0
    -------------------------------------------------------------------


ERROR HANDLING
--------------
  - Policy not found:     Lists available policies, skips vault.
  - No AG groups found:   Informational message, no error.
  - 409 Conflict:         Auto-protection intent already exists for
                          this AG group. Shows hint message.
  - Auth failure:         Script exits immediately.


SAFETY
------
  - Auto-protection is a non-destructive operation.
  - Only affects future backup scheduling, not existing data.
  - WhatIf mode allows safe preview before execution.
  - Results CSV provides audit trail.


PUBLIC DOCUMENTATION
--------------------
  Protection Intent - Create or Update (Auto-Protection):
    https://learn.microsoft.com/en-us/rest/api/backup/protection-intent/create-or-update

  Azure Backup REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/

================================================================================

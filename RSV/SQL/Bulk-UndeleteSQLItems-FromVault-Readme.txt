================================================================================
  Bulk-UndeleteSQLItems-FromVault.ps1 - README
================================================================================

VERSION
-------
  v1.0 - March 19, 2026


DESCRIPTION
-----------
Bulk CSV-driven script to undelete (rehydrate) soft-deleted SQL backup items
in a Recovery Services Vault. Recovers items from SoftDeleted state back to
ProtectionStopped with all recovery points preserved.

Optionally resumes protection by re-applying a backup policy after undelete.

API Version: 2025-08-01


USE CASES
---------
  - Recover accidentally soft-deleted backup items
  - Clean up vault state after failed AG unregistration
  - Resume protection on items that were stop-deleted
  - Bulk recovery across multiple vaults


HOW IT WORKS
------------
  Step 1:  Validates the CSV file.
  Step 2:  Authenticates once (Azure PowerShell or Azure CLI).
  Step 3:  Discovers all soft-deleted SQL items in the vault.
           Optionally filters by VM name + resource group.
  Step 4:  Displays execution plan and prompts for confirmation.
  Step 5:  Undeletes each item (PUT with isRehydrate=true, 3 retries).
  Step 6:  Optionally resumes protection with specified policy.
  Step 7:  Verifies all items are recovered (no longer SoftDeleted).
  Step 8:  Exports results CSV and displays summary.


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
    VaultSubscriptionId, VaultResourceGroup, VaultName

  Optional columns:
    VMResourceGroup, VMName   - Filter to specific VM(s)
    PolicyName                - Resume protection after undelete


EXAMPLE CSVs
~~~~~~~~~~~~

  Undelete all soft-deleted items in a vault:
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VaultSubscriptionId,VaultResourceGroup,VaultName
    af95aa3c-...,AzureBackupRG_kajai2025,kajai-ag-test-vault-v2

  Undelete items for specific VMs only:
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName
    af95aa3c-...,AzureBackupRG_kajai2025,kajai-ag-test-vault-v2,kajaiccy,sqlserver-0
    af95aa3c-...,AzureBackupRG_kajai2025,kajai-ag-test-vault-v2,kajaiccy,sqlserver-1

  Undelete + resume protection with a policy:
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VaultSubscriptionId,VaultResourceGroup,VaultName,VMResourceGroup,VMName,PolicyName
    af95aa3c-...,AzureBackupRG_kajai2025,kajai-ag-test-vault-v2,kajaiccy,sqlserver-0,HourlyLogBackup
    af95aa3c-...,AzureBackupRG_kajai2025,kajai-ag-test-vault-v2,kajaiccy,sqlserver-1,HourlyLogBackup


EXAMPLES
--------

  # Undelete all soft-deleted items (interactive)
  PS> .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv"

  # Fully non-interactive
  PS> .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv" -SkipConfirmation

  # Dry run
  PS> .\Bulk-UndeleteSQLItems-FromVault.ps1 -CsvPath ".\undelete-input.csv" -WhatIf


SAFETY
------
  - Undelete is a non-destructive operation (recovers data).
  - Items move from SoftDeleted → ProtectionStopped (data retained).
  - Resume protection is optional (only when PolicyName is specified).
  - WhatIf mode allows safe preview before execution.
  - Verification step confirms recovery after undelete.
  - Results CSV provides audit trail.

================================================================================

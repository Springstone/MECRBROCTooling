================================================================================
  Bulk-Stop-FileShare-Protection.ps1 - README
================================================================================

DESCRIPTION
-----------
Bulk stops backup protection (retain data) for multiple Azure File Shares from
a CSV file using the Azure Backup REST API. Uses the same per-item flow as
Stop-FileShare-Protection.ps1.

Per-item steps:
  1. Verifies the file share is currently protected in the vault.
  2. Checks if protection is already stopped (skips if so).
  3. Submits stop-protection PUT (policyId empty, protectionState =
     ProtectionStopped).
  4. Polls/verifies protection state changes to ProtectionStopped.

After stop-protection-with-retain-data:
  - No new backups will be taken for these file shares.
  - All existing recovery points are preserved and available for restore.
  - Protection can be resumed later by re-associating a backup policy.

Additional features:
  - Preview table of all items before execution.
  - Per-item duration tracking.
  - Summary table with SUCCESS / FAILED / PENDING / SKIPPED counts.
  - Results exported to a _Results.csv file.
  - Already-stopped items are auto-detected and skipped.


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script prompts for confirmation before executing.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A — Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B — Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.


CSV FORMAT
----------
File: Bulk-Stop-FileShare-Protection_Input.csv

  Header row required. Columns:
    VaultSubscriptionId              Subscription ID of the Recovery Services Vault
    VaultResourceGroup               Resource group of the vault
    VaultName                        Name of the vault
    StorageAccountSubscriptionId     Subscription ID of the storage account
                                     (leave empty to use vault subscription)
    StorageAccountResourceGroup      Resource group of the storage account
    StorageAccountName               Name of the storage account
    FileShareName                    Name of the file share to stop protection for

  Example:
    VaultSubscriptionId,VaultResourceGroup,VaultName,StorageAccountSubscriptionId,StorageAccountResourceGroup,StorageAccountName,FileShareName
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare01,data-share
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare01,logs-share


HOW TO RUN
----------
  With parameter:
    .\Bulk-Stop-FileShare-Protection.ps1 -CsvPath "C:\inputs\stop-shares.csv"

  Without parameter (prompts or uses default):
    .\Bulk-Stop-FileShare-Protection.ps1

  The default CSV path is Bulk-Stop-FileShare-Protection_Input.csv in the
  same directory as the script.


API VERSION USED
----------------
  - 2025-08-01   All operations (protected items query, stop-protection PUT)


RESULT STATUSES
---------------
  SUCCESS  — Stop-protection PUT accepted and verification confirmed
             protectionState = ProtectionStopped.
  PENDING  — Stop-protection PUT accepted but verification timed out. The
             operation is likely completed; verify on Azure Portal.
  FAILED   — An error occurred (file share not found in vault, insufficient
             permissions, PUT failed, etc.). Detail column shows the error.
  SKIPPED  — Missing required fields in CSV row, or protection was already
             stopped for this file share.


EXAMPLES
--------

Example 1 — Bulk stop protection (same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Stop-FileShare-Protection.ps1 -CsvPath ".\stop-shares.csv"

  The script loads the CSV, previews all items in a table, warns about
  stopping protection, asks for confirmation, then processes each item.


Example 2 — Use default CSV file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Stop-FileShare-Protection.ps1

  Prompts for CSV path. Press Enter to use the default
  Bulk-Stop-FileShare-Protection_Input.csv in the script directory.


Example 3 — Cross-region (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  CSV rows can reference storage accounts in different regions than the vault.

  Example CSV row:
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-swedencentral,rsv-dr-swedencentral,,rg-storage-uaenorth,stgfilesuaenorth01,finance-data

  The storage account is in UAE North (uaenorth) while the vault is in
  Sweden Central (swedencentral).


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Bulk-Stop-FileShare-Protection.ps1 -CsvPath ".\stop-shares.csv"

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
Console output:
  - Preview table of all items
  - Per-item step-by-step progress (Steps A through D)
  - Color-coded results: Green (SUCCESS), Red (FAILED), Yellow (PENDING/SKIPPED)
  - Summary metrics: total, succeeded, failed, pending, skipped, total duration
  - Results table
  - Next steps for items that succeeded

Results CSV:
  - Exported to {InputFileName}_Results.csv
  - Columns: Item, Vault, Status, ProtectionState, Detail, Duration


ERROR HANDLING
--------------
Per-item errors are caught and logged — they do not stop the script.

Common per-item failures:
  - File share not found in vault protection
  - Insufficient RBAC permissions on the vault
  - Vault soft-delete preventing changes
  - PUT returns non-200/202 error

The script continues to the next CSV row after any failure.


PUBLIC DOCUMENTATION
--------------------
  Stop protection but retain existing data (AFS REST API):
    https://learn.microsoft.com/en-us/azure/backup/manage-azure-file-share-rest-api#stop-protection-but-retain-existing-data

  Protected Items - Create or Update (REST API reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update?view=rest-backup-2025-08-01

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

================================================================================

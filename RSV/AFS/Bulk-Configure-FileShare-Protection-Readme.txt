================================================================================
  Bulk-Configure-FileShare-Protection.ps1 - README
================================================================================

DESCRIPTION
-----------
Bulk enables backup protection for multiple Azure File Shares from a CSV file
using the Azure Backup REST API. Uses the same per-item flow as
Configure-FileShare-Protection.ps1.

Per-item steps:
  1. Verifies storage account is registered to the vault.
  2. Triggers inquire to discover file shares in the storage account.
  3. Lists protectable items and verifies the target file share exists.
  4. Finds the backup policy by name in the vault.
  5. Enables protection (PUT).
  6. Polls/verifies protection state (SUCCESS, PENDING, or FAILED).

Additional features:
  - Preview table of all items before execution.
  - Policy tier caution (Snapshot vs Vault-Standard) displayed before confirm.
  - Per-item duration tracking.
  - Summary table with SUCCESS / FAILED / PENDING / SKIPPED counts.
  - Results exported to a _Results.csv file.

CAUTION — Policy Tier Behavior:
  - 'Snapshot' policy       : Backups are stored as snapshots in the Storage
                              Account only, in the Storage Account region.
  - 'Vault-Standard' policy : Backups are stored as snapshots in the Storage
                              Account (Storage Account region) and transferred
                              to the Recovery Services Vault (Vault region).
  Verify your policy tier in Azure Portal (Recovery Services Vault -> Backup
  Policies -> Select Policy -> look for 'Backup tier') before running.


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
- Reader (or equivalent) on the Storage Account(s).


CSV FORMAT
----------
File: Bulk-Configure-FileShare-Protection_Input.csv

  Header row required. Columns:
    VaultSubscriptionId              Subscription ID of the Recovery Services Vault
    VaultResourceGroup               Resource group of the vault
    VaultName                        Name of the vault
    StorageAccountSubscriptionId     Subscription ID of the storage account
                                     (leave empty to use vault subscription)
    StorageAccountResourceGroup      Resource group of the storage account
    StorageAccountName               Name of the storage account
    FileShareName                    Name of the file share to protect
    PolicyName                       Name of the backup policy to assign

  Example:
    VaultSubscriptionId,VaultResourceGroup,VaultName,StorageAccountSubscriptionId,StorageAccountResourceGroup,StorageAccountName,FileShareName,PolicyName
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare01,data-share,DailyPolicy-30d
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare01,logs-share,DailyPolicy-30d


HOW TO RUN
----------
  With parameter:
    .\Bulk-Configure-FileShare-Protection.ps1 -CsvPath "C:\inputs\fileshares.csv"

  Without parameter (prompts or uses default):
    .\Bulk-Configure-FileShare-Protection.ps1

  The default CSV path is Bulk-Configure-FileShare-Protection_Input.csv in the
  same directory as the script.


API VERSION USED
----------------
  - 2025-08-01   All operations (container verification, inquire, protectable
                 items, policies, enable protection)


RESULT STATUSES
---------------
  SUCCESS  — Protection PUT accepted and verification confirmed a valid state
             (Protected or IRPending).
  PENDING  — Protection PUT accepted but verification timed out. The protection
             is likely configured; verify on Azure Portal.
  FAILED   — An error occurred (registration missing, policy not found, PUT
             failed, etc.). Detail column shows the specific error.
  SKIPPED  — Missing required fields in the CSV row.

  Note: 'IRPending' (Initial Recovery Pending) means protection is configured
  and the first backup is pending.

EXAMPLES
--------

Example 1 — Bulk protect multiple file shares (same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Configure-FileShare-Protection.ps1 -CsvPath ".\my-fileshares.csv"

  The script loads the CSV, previews all items in a table, shows the policy
  tier caution, asks for confirmation, then processes each item sequentially.


Example 2 — Use default CSV file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Configure-FileShare-Protection.ps1

  Prompts for CSV path. Press Enter to use the default
  Bulk-Configure-FileShare-Protection_Input.csv in the script directory.


Example 3 — Cross-region (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  CSV rows can reference storage accounts in different regions than the vault.

  Example CSV row:
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-swedencentral,rsv-dr-swedencentral,,rg-storage-uaenorth,stgfilesuaenorth01,finance-data,DailyPolicy-30d

  The storage account is in UAE North (uaenorth) while the vault is in
  Sweden Central (swedencentral).


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Bulk-Configure-FileShare-Protection.ps1 -CsvPath ".\my-fileshares.csv"

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
Console output:
  - Preview table of all items
  - Per-item step-by-step progress (Steps A through F)
  - Color-coded results: Green (SUCCESS), Red (FAILED), Yellow (PENDING/SKIPPED)
  - Summary metrics: total, succeeded, failed, pending, skipped, total duration
  - Results table

Results CSV:
  - Exported to {InputFileName}_Results.csv
  - Columns: Item, Vault, Policy, Status, ProtectionState, Detail, Duration


ERROR HANDLING
--------------
Per-item errors are caught and logged — they do not stop the script.

Common per-item failures:
  - Storage account not registered to vault
  - File share not found in protectable items
  - Policy name not found in vault
  - PUT returns non-200/202 error (insufficient permissions, policy
    incompatible with file share type)

The script continues to the next CSV row after any failure.


PUBLIC DOCUMENTATION
--------------------
  Protected Items - Create or Update (REST API reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update?view=rest-backup-2025-08-01

  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

================================================================================

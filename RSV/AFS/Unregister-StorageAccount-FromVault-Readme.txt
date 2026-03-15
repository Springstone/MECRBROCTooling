================================================================================
  Unregister-StorageAccount-FromVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Unregisters (removes) an Azure Storage Account from a Recovery Services Vault
using the Azure Backup REST API. This is the reverse of registration and
dissociates the storage account from the vault entirely.

Before unregistering:
  - All file shares in the storage account should have their protection stopped
    with retain data (use Stop-FileShare-Protection.ps1).
  - With api-version 2025-08-01, the vault allows unregistering even when file
    shares are in stop-protection-with-retain-data state.

After unregistering:
  - The storage account is no longer associated with the vault.
  - No backup operations can be performed for file shares in this account.
  - To re-enable backup, register the storage account again using
    Register-StorageAccount-ToVault.ps1.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Verifies the storage account is currently registered to the vault.
  3. Checks for any remaining protected items in the container.
  4. Displays registration details and confirms the unregister operation.
  5. Submits the DELETE request to unregister the container.
  6. Polls for operation completion.
  7. Verifies the container is removed.


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script is interactive (uses Read-Host prompts), so it must be run in a
  foreground terminal session — not as part of an automated pipeline.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A — Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B — Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required. The script uses only built-in
PowerShell cmdlets (Invoke-RestMethod, Invoke-WebRequest, ConvertTo-Json)
alongside the Azure REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the Storage Account (for verification).


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — Storage Account Information:
    - Storage Account Resource Group Name
    - Storage Account Name

  Step 3 — Confirmation:
    - User must type "yes" or "y" to proceed


API VERSION USED
----------------
  - 2025-08-01   All operations (container GET, container DELETE, protected items query)


EXAMPLES
--------

Example 1 — Unregister storage account (same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-StorageAccount-FromVault.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-prod
    Vault Name:                    rsv-prod-eastus
    Storage Account RG:            rg-storage-prod
    Storage Account Name:          stgfileshare01

  The script verifies stgfileshare01 is registered, checks for remaining
  protected file shares, asks for confirmation, unregisters the container,
  and verifies removal.


Example 2 — Storage account with stopped protection items
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-StorageAccount-FromVault.ps1

  If file shares still have stopped protection (retain data), the script
  lists them with their protection state and proceeds with unregistration
  since api-version 2025-08-01 allows this.


Example 3 — Storage account with active protection (blocked)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-StorageAccount-FromVault.ps1

  If file shares still have active protection (not stopped), the script
  displays the active items, shows an error, and exits. The user must
  first run Stop-FileShare-Protection.ps1 for each active file share.


Example 4 — Storage account not registered
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-StorageAccount-FromVault.ps1

  If the storage account is not registered to the vault, the script
  detects this (404 response) and exits — nothing to unregister.


Example 5 — Cross-region (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Unregister-StorageAccount-FromVault.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-swedencentral
    Vault Name:                    rsv-dr-swedencentral
    Storage Account RG:            rg-storage-uaenorth
    Storage Account Name:          stgfilesuaenorth01

  The storage account is in UAE North (uaenorth) while the vault is
  in Sweden Central (swedencentral).


Example 6 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Unregister-StorageAccount-FromVault.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings, confirmations, and action descriptions
  - Green:   Success confirmations
  - Gray:    Detail values (container names, constructed identifiers)
  - White:   Container details and next-step instructions
  - Red:     Errors

On success, displays:
  - STORAGE ACCOUNT UNREGISTERED!
  - Confirmation that the storage account has been removed from the vault
  - Verification that the container returns 404 (not found)
  - Next steps for re-registration or portal verification


ERROR HANDLING
--------------
Common issues and what the script reports:

  - Storage account not registered:
      Detects 404 and exits cleanly — nothing to unregister.

  - Active protection still exists:
      Lists all protected file shares with their states. Blocks unregister
      if any file share has active (non-stopped) protection. Directs user
      to run Stop-FileShare-Protection.ps1 first.

  - Unregister request fails:
      Shows HTTP status code, error code, and message. Lists possible causes
      (active protection, insufficient RBAC, incorrect container name,
      vault soft-delete retaining items).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Operation timeout:
      After 20 polling attempts (≈2 minutes), directs user to check Azure
      Portal for final status.


SECURITY CONSIDERATIONS
-----------------------
  Token handling:
    - The Bearer token is obtained at runtime and held only in memory for
      the duration of the script. It is never written to disk, logged, or
      displayed in console output.
    - Tokens are short-lived (typically 1 hour) and scoped to the Azure
      Management plane (https://management.azure.com).

  Input validation:
    - All user-supplied inputs (subscription ID, resource group, vault name,
      storage account name) are validated for empty/whitespace values before
      any API call is made.
    - The container name is constructed from user inputs using the documented
      format: StorageContainer;storage;<resourceGroup>;<storageAccountName>.
      No arbitrary shell expansion or command injection is possible because
      values are passed as URI segments to Invoke-RestMethod, not evaluated
      as commands.

  Confirmation gate:
    - The script requires explicit user confirmation ("yes" / "y") before
      submitting the DELETE request. Accidental execution without confirmation
      will not unregister the container.

  Active protection safeguard:
    - Before attempting unregister, the script queries for protected items in
      the container. If any file share has active (non-stopped) protection,
      the script blocks the operation and exits with an error — preventing
      accidental data-path disruption.

  Least-privilege RBAC:
    - The script requires only Backup Contributor on the vault and Reader on
      the storage account. Avoid granting broader roles (Owner, Contributor)
      solely for this operation.
    - Consider using a service principal or managed identity with scoped RBAC
      in automated or production environments.

  Network security:
    - All API calls use HTTPS (TLS) to the Azure Resource Manager endpoint.
    - For additional network isolation, run the script from a virtual machine
      or jumpbox with Private Endpoint access to the Recovery Services Vault.

  Audit trail:
    - The unregister operation is recorded in the vault's Activity Log
      (Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/
      delete). Enable Azure Monitor diagnostic settings on the vault to
      forward these logs to a Log Analytics workspace or storage account
      for long-term retention.
    - Review Activity Log entries to confirm who performed the unregister
      and when.

  Soft delete / immutability:
    - If the vault has soft delete enabled, recovery points are retained
      for the soft-delete retention period even after unregistration.
    - If the vault has immutability enabled, unregister may be blocked
      depending on the immutability state. Check vault properties before
      running the script.

  Re-registration:
    - After unregistering, the storage account can be re-registered to the
      same or a different vault. Ensure organizational policies allow this
      before proceeding with unregistration.


PUBLIC DOCUMENTATION
--------------------
  Protection Containers - Unregister (REST API reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/unregister

  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services - Protection Containers REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers

================================================================================

================================================================================
  Stop-FileShare-Protection.ps1 - README
================================================================================

DESCRIPTION
-----------
Stops backup protection for an Azure File Share in a Recovery Services Vault
while retaining all existing backup data (recovery points).

After stop-protection-with-retain-data:
  - No new backups will be taken for this file share.
  - All existing recovery points are preserved and available for restore.
  - The file share remains listed in the vault as a stopped-protection item.
  - Protection can be resumed later by re-associating a backup policy.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Verifies the file share is currently protected in the vault.
  3. Displays current protection details (policy, last backup, health).
  4. Checks if protection is already stopped — exits early if so.
  5. Confirms the stop-protection operation with the user.
  6. Submits the stop-protection request (PUT with empty policyId and
     protectionState = ProtectionStopped).
  7. Verifies the updated protection state.


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
PowerShell cmdlets (Invoke-RestMethod, ConvertTo-Json) alongside the Azure
REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — File Share Information:
    - Storage Account Name
    - Storage Account Resource Group Name
    - Storage Account Subscription ID  (press Enter to reuse vault subscription)
    - File Share Name

  Step 2 — Confirmation:
    - User must type "yes" or "y" to proceed


API VERSION USED
----------------
  - 2025-08-01   All operations (protected item query, stop-protection PUT)


EXAMPLES
--------

Example 1 — Stop protection (same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Stop-FileShare-Protection.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-prod
    Vault Name:                    rsv-prod-eastus
    Storage Account Name:          stgfileshare01
    Storage Account RG:            rg-storage-prod
    Storage Account Subscription:  (press Enter — same as vault)
    File Share Name:               data-share

  The storage account and vault are both in East US (eastus). The script
  verifies data-share is currently protected, displays the current policy
  and backup details, asks for confirmation, then stops protection while
  retaining all recovery points.


Example 2 — Protection already stopped
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Stop-FileShare-Protection.ps1

  If the file share's protection is already stopped, the script
  displays the current state and exits without making changes.


Example 3 — Stop protection (cross-region, storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Stop-FileShare-Protection.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-swedencentral
    Vault Name:                    rsv-dr-swedencentral
    Storage Account Name:          stgfilesuaenorth01
    Storage Account RG:            rg-storage-uaenorth
    Storage Account Subscription:  (press Enter — same as vault)
    File Share Name:               finance-data

  The storage account is in UAE North (uaenorth) while the vault is
  in Sweden Central (swedencentral).


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Stop-FileShare-Protection.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings, confirmations, and action descriptions
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names)
  - White:   Protection details and next-step instructions
  - Red:     Errors

On success, displays:
  - PROTECTION STOPPED SUCCESSFULLY
  - Updated File Share, Protection State, Health Status
  - Confirmation that backup data has been retained
  - Next steps for resuming protection, deleting data, or restoring


ERROR HANDLING
--------------
Common issues and what the script reports:

  - File share not found in vault protection:
      Lists all protected file shares and suggests verification steps.

  - Protection already stopped:
      Detects and exits early — no unnecessary API call.

  - Stop-protection request fails:
      Shows HTTP status code, error code, and message. Lists possible causes
      (not currently protected, insufficient RBAC, incorrect names, vault
      locked or soft-delete preventing changes).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Operation timeout:
      Directs user to check Azure Portal for final status.


PUBLIC DOCUMENTATION
--------------------
  Stop protection but retain existing data (AFS REST API):
    https://learn.microsoft.com/en-us/azure/backup/manage-azure-file-share-rest-api#stop-protection-but-retain-existing-data

  Protected Items - Create or Update (REST API reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items/create-or-update

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

================================================================================

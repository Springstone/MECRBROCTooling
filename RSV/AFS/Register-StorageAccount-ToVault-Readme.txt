================================================================================
  Register-StorageAccount-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Registers an Azure Storage Account (containing Azure File Shares) to a
Recovery Services Vault using the Azure Backup REST API. This is the first
step before configuring file share backup protection.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Triggers a container refresh to discover storage accounts with file shares.
  3. Lists protectable containers (storage accounts available for backup).
  4. Registers the target storage account to the vault.
  5. Verifies the registration status.

Once registered, file shares in the storage account can be protected using
Configure-FileShare-Protection.ps1.


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
- Reader (or equivalent) on the Storage Account.


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — Storage Account Information:
    - Storage Account Subscription ID  (press Enter to reuse vault subscription)
    - Storage Account Resource Group Name
    - Storage Account Name


API VERSION USED
----------------
  - 2025-08-01   All operations (container discovery, protectable containers, registration)


EXAMPLES
--------

Example 1 — Register storage account (same subscription as vault)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-StorageAccount-ToVault.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-prod
    Vault Name:                    rsv-prod-eastus
    Storage Account Subscription:  (press Enter — same as vault)
    Storage Account RG:            rg-storage-prod
    Storage Account Name:          stgfileshare01

  The script discovers stgfileshare01, registers it to the vault, and
  confirms registration status. Next step: run Configure-FileShare-
  Protection.ps1 to enable backup for specific file shares.


Example 2 — Storage account and vault in different regions (cross-region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-StorageAccount-ToVault.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-swedencentral
    Vault Name:                    rsv-dr-swedencentral
    Storage Account Subscription:  (press Enter — same as vault)
    Storage Account RG:            rg-storage-uaenorth
    Storage Account Name:          stgfilesuaenorth01

  In this scenario the storage account is in UAE North (uaenorth) while
  the Recovery Services Vault is in Sweden Central (swedencentral).


Example 3 — Storage account already registered
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-StorageAccount-ToVault.ps1

  If the storage account is already registered, the script detects this
  and confirms the existing registration status.


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Register-StorageAccount-ToVault.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - Red:     Errors

On success, displays:
  - REGISTRATION SUCCESSFUL
  - Friendly Name, Registration Status, Health Status, Container Type,
    Source Resource ID
  - Next steps for configuring file share protection


ERROR HANDLING
--------------
Common issues and what the script reports:

  - Storage account not found in discoverable list:
      Lists all available storage accounts and suggests causes.

  - Registration fails:
      Shows HTTP status code and error message. Lists possible causes
      (already registered to another vault, insufficient permissions,
      incorrect resource ID, cross-subscription policy restrictions).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.


PUBLIC DOCUMENTATION
--------------------
  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Recovery Services - Protection Containers REST API:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers

================================================================================

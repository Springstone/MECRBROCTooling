================================================================================
  Configure-FileShare-Protection.ps1 - README
================================================================================

DESCRIPTION
-----------
Enables backup protection for an Azure File Share by assigning a backup policy
in a Recovery Services Vault using the Azure Backup REST API.

Prerequisites: The storage account must already be registered to the vault.
Use Register-StorageAccount-ToVault.ps1 first if not yet registered.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Verifies the storage account is registered to the vault.
  3. Triggers an inquire operation to discover file shares.
  4. Lists protectable (unprotected) file shares in the storage account.
  5. Lists available Azure File Share backup policies in the vault.
  6. Enables backup protection with the selected policy.
  7. Verifies the final protection status.


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

  Section 2 — Storage Account & File Share:
    - Storage Account Subscription ID  (press Enter to reuse vault subscription)
    - Storage Account Resource Group Name
    - Storage Account Name
    - File Share Name

  Step 4 — Policy Selection:
    - Choose from discovered Azure File Share backup policies by number

  CAUTION — Policy Tier Behavior:
    - 'Snapshot' policy       : Backups are stored as snapshots in the Storage
                                Account only, in the Storage Account region.
    - 'Vault-Standard' policy : Backups are stored as snapshots in the Storage
                                Account (Storage Account region) and transferred
                                to the Recovery Services Vault (Vault region).
    Verify your policy tier in the Azure Portal before selecting:
      Recovery Services Vault > Backup Policies > Select Policy > Backup tier


API VERSION USED
----------------
  - 2025-08-01   All operations (container verification, inquire, protectable items,
                 backup policies, enable protection)


EXAMPLES
--------

Example 1 — Configure protection for a file share
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Configure-FileShare-Protection.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-prod
    Vault Name:                    rsv-prod-eastus
    Storage Account Subscription:  (press Enter — same as vault)
    Storage Account RG:            rg-storage-prod
    Storage Account Name:          stgfileshare01
    File Share Name:               data-share
    Backup Policy:                 [1] DailyPolicy-30d

  The script verifies stgfileshare01 is registered, discovers the
  data-share file share, assigns DailyPolicy-30d, and confirms
  protection is enabled.


Example 2 — Cross-region protection (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Configure-FileShare-Protection.ps1

  Prompts:
    Vault Subscription ID:         aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:          rg-backup-swedencentral
    Vault Name:                    rsv-dr-swedencentral
    Storage Account Subscription:  (press Enter — same as vault)
    Storage Account RG:            rg-storage-uaenorth
    Storage Account Name:          stgfilesuaenorth01
    File Share Name:               finance-data
    Backup Policy:                 [1] DailyPolicy-30d

  The storage account is in UAE North (uaenorth) while the vault is in
  Sweden Central (swedencentral). The workflow is the same — verify
  registration, discover file shares, and assign the backup policy.


Example 3 — File share already protected
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Configure-FileShare-Protection.ps1

  If the file share is already protected, the script shows the current
  state and asks whether to continue and update the protection policy.


Example 4 — Storage account not registered
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Configure-FileShare-Protection.ps1

  If the storage account is not registered to the vault, the script
  exits with an error instructing you to run Register-StorageAccount-
  ToVault.ps1 first.


Example 5 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Configure-FileShare-Protection.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - White:   File share listings and policy details
  - Red:     Errors

On success, displays:
  - PROTECTION CONFIGURED SUCCESSFULLY
  - File Share name, Protection State, Health Status, Policy Name
  - Next steps for triggering backups and monitoring

Additionally, the script displays:
  - DarkYellow: Caution messages (policy tier behavior and portal verification)


ERROR HANDLING
--------------
Common issues and what the script reports:

  - Storage account not registered:
      Directs user to run Register-StorageAccount-ToVault.ps1.

  - File share not found in storage account:
      Lists all available file shares and suggests verification steps.

  - No backup policies found:
      Advises creating a policy via Azure Portal, PowerShell, or CLI.

  - Protection enablement fails:
      Shows HTTP status code and error. Lists possible causes
      (unregistered storage account, non-existent file share,
      insufficient permissions, incompatible policy).

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.


PUBLIC DOCUMENTATION
--------------------
  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Backup Protected Items REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/protected-items

  Backup Policies REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/backup-policies

================================================================================

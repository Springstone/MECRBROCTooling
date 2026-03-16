================================================================================
  Restore-AzureFileShare-RestAPI.ps1 - README
================================================================================

DESCRIPTION
-----------
Restores a backed-up Azure File Share from a Recovery Services Vault using
the Azure Backup REST API. Supports full share and item-level restores to
original or alternate locations.

Restore Types:
  - Full Share Restore — Restores the entire file share.
  - Item Level Restore — Restores specific files or folders.

Important Support Notes : 
1. For AFS Vaulted Policy, Only ALR restore is released in production. ILR and OLR are not released yet.
2. For AFS Vaulted Policy, The Target folder name during Restore has to be empty.
3. For AFS Vaulted Policy, The Copy Options have to be Overwrite only.
4. Check https://learn.microsoft.com/en-us/azure/backup/azure-file-share-support-matrix?tabs=vault-tier#supported-restore-methods

Recovery Types:
  - Original Location — Restores to the same storage account and file share.
  - Alternate Location — Restores to a different storage account/file share.

Copy Options:
  - Overwrite — Replaces existing files at the destination.
  - Skip — Keeps existing files, skips conflicts.
  - FailOnConflict — Fails the restore if any file conflicts exist.

Workflow:
  1. Authenticates via Bearer token (Azure PowerShell or CLI).
  2. Verifies the file share is a protected backup item in the vault.
  3. User selects restore type (Full Share or Item Level).
  4. User selects recovery type (Original or Alternate Location).
  5. Collects target location details (for Alternate Location).
  6. Collects item specifications (for Item Level Restore).
  7. User selects conflict resolution policy (Overwrite/Skip/FailOnConflict).
  8. Lists available recovery points and lets user select one.
  9. Constructs the AzureFileShareRestoreRequest body.
  10. Triggers the restore operation and polls for completion.



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
- Backup Operator (or equivalent) on the Recovery Services Vault.
- Contributor on the target Storage Account (Alternate Location scenario).
- Reader on the source Storage Account.


INPUTS (PROMPTED AT RUNTIME)
-----------------------------
  Section 1 — Vault Information:
    - Vault Subscription ID
    - Vault Resource Group Name
    - Recovery Services Vault Name

  Section 2 — Source (Backed Up) File Share:
    - Source Storage Account Name
    - Source Resource Group Name
    - Source Subscription ID     (press Enter to reuse vault subscription)
    - Source File Share Name

  Section 3 — Restore Type:
    - 1 = Full Share Restore
    - 2 = Item Level Restore

  Section 4 — Recovery Type:
    - 1 = Original Location
    - 2 = Alternate Location

  Section 5 — Target Location (Alternate Location only):
    - Target Subscription ID
    - Target Resource Group Name
    - Target Storage Account Name
    - Target File Share Name
    - Target Folder Path (optional)

  Section 6 — Item Specification (Item Level Restore only):
    - For each item: File or Folder type, and path
    - Can add multiple items

  Section 7 — Conflict Resolution:
    - 1 = Overwrite, 2 = Skip, 3 = FailOnConflict

  Section 8 — Recovery Point Selection:
    - Lists recovery points with Time, Type, and Size.
    - User picks by number.


API VERSION USED
----------------
  - 2025-08-01   All operations (protected items, recovery points, restore)


EXAMPLES
--------

Example 1 — Full Share Restore to Original Location
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-AzureFileShare-RestAPI.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-prod
    Vault Name:               rsv-prod-eastus
    Source Storage Account:   stgfileshare01
    Source Resource Group:    rg-storage-prod
    Source Subscription:      (press Enter — same as vault)
    Source File Share:        data-share
    Restore Type:             1 (Full Share Restore)
    Recovery Type:            1 (Original Location)
    Copy Options:             1 (Overwrite)
    Recovery Point:           [1] (select from list)

  Restores the entire data-share file share in-place, overwriting
  current contents with the selected recovery point.


Example 2 — Full Share Restore to Alternate Location
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-AzureFileShare-RestAPI.ps1

  Prompts:
    (vault + source details as above)
    Restore Type:             1 (Full Share Restore)
    Recovery Type:            2 (Alternate Location)
    Target Subscription:      (press Enter — same as source)
    Target Resource Group:    rg-storage-dr
    Target Storage Account:   stgrestoretarget01
    Target File Share:        data-share-restored
    Target Folder Path:       (press Enter — root)
    Copy Options:             1 (Overwrite)
    Recovery Point:           [1] (select from list)

  Restores the full share to a different storage account and file share.


Example 3 — Item Level Restore (specific files/folders)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-AzureFileShare-RestAPI.ps1

  Prompts:
    (vault + source details as above)
    Restore Type:             2 (Item Level Restore)
    Recovery Type:            2 (Alternate Location)
    (target details as in Example 2)
    Item #1 Type:             1 (File)
    Item #1 Path:             reports/Q4-2025.xlsx
    Add another?              y
    Item #2 Type:             2 (Folder)
    Item #2 Path:             logs/
    Add another?              n
    Copy Options:             2 (Skip)
    Recovery Point:           [2] (select from list)

  Restores two specific items (one file, one folder) to the alternate
  location, skipping any conflicts.


Example 4 — Cross-region restore (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Restore-AzureFileShare-RestAPI.ps1

  Prompts:
    Vault Subscription ID:    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
    Vault Resource Group:     rg-backup-swedencentral
    Vault Name:               rsv-dr-swedencentral
    Source Storage Account:   stgfilesuaenorth01
    Source Resource Group:    rg-storage-uaenorth
    Source Subscription:      (press Enter — same as vault)
    Source File Share:        finance-data
    Restore Type:             1 (Full Share Restore)
    Recovery Type:            2 (Alternate Location)
    Target Subscription:      (press Enter — same as vault)
    Target Resource Group:    rg-storage-swedencentral
    Target Storage Account:   stgrestoreswe01
    Target File Share:        finance-data-restored
    Target Folder Path:       (press Enter — root)
    Copy Options:             1 (Overwrite)
    Recovery Point:           [1] (select from list)

  The source file share is in UAE North (uaenorth) while the vault and
  target storage account are in Sweden Central (swedencentral).


Example 5 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Restore-AzureFileShare-RestAPI.ps1

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
The script prints color-coded output to the console:
  - Cyan:    Section headers and prompts
  - Yellow:  Warnings, status updates, and operation polling
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, recovery point properties)
  - White:   Recovery point listings and item specifications
  - Red:     Errors

Recovery point listing shows for each point:
  - Recovery Point ID, Time, Type, Size (GB)

On success, the script displays:
  - Operation completed successfully
  - Restore Job ID
  - Vault name for portal tracking


ERROR HANDLING
--------------
Common issues and what the script reports:

  - File share not found in vault protection:
      Lists all protected file shares and suggests verification steps.

  - No recovery points found:
      Advises to ensure the file share is backed up with available points.

  - Restore operation fails:
      Shows HTTP status code, error code, and message.

  - Authentication failure:
      Prompts to run Connect-AzAccount or az login.

  - Operation timeout:
      Directs user to check Azure Portal for final status.


PUBLIC DOCUMENTATION
--------------------
  Restore Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/restore-azure-file-share-rest-api

  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

  Backup Restores REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/restores

================================================================================

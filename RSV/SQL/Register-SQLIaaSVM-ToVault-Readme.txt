================================================================================
  Register-SQLIaaSVM-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Discovers, registers, and protects SQL Server databases running on Azure IaaS
VMs to a Recovery Services Vault using the Azure Backup REST API. The script
performs end-to-end container discovery, VM registration, SQL workload inquiry,
database protection, and optional auto-protection of SQL instances.


WORKFLOW
--------
  1. Triggers a container refresh to discover VMs with SQL workloads.
  2. Lists protectable containers and locates the target VM.
  3. Registers the VM as a VMAppContainer (skips if already registered).
  4. Inquires SQL workloads inside the VM (discovers instances and databases).
  5. Lists protectable SQL databases and instances.
     - Groups databases by instance when multiple SQL instances exist.
     - Filters to -InstanceName if provided.
  6. Checks if the target database is already protected.
  7. Lists available AzureWorkload backup policies.
  8. Enables protection on the selected database OR enables auto-protection
     on one or all SQL instances.
  9. Verifies the final protection status.


WHERE TO RUN
------------
- PowerShell 7+ (Windows, macOS, or Linux) or Windows PowerShell 5.1.
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- Supports both non-interactive (all parameters on command line) and interactive
  modes (PowerShell prompts for mandatory parameters).


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A - Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B - Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required. The script uses only built-in
PowerShell cmdlets (Invoke-RestMethod, Invoke-WebRequest, ConvertTo-Json)
alongside the Azure Backup REST API.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the target Virtual Machine and its Resource Group.
- SQL Server IaaS Agent extension must be installed on the VM.


PARAMETERS
----------
  -VaultSubscriptionId      [Required]  Subscription ID of the vault.
  -VaultResourceGroup       [Required]  Resource group of the vault.
  -VaultName                [Required]  Name of the Recovery Services Vault.
  -VMResourceGroup          [Required]  Resource group of the SQL Server VM.
  -VMName                   [Required]  Name of the Azure VM hosting SQL Server.
  -InstanceName             [Optional]  SQL instance name (e.g. MSSQLSERVER,
                                        SQLEXPRESS). Filters databases and
                                        instances to this instance only.
                                        Disambiguates when same DB name exists
                                        in multiple instances.
  -DatabaseName             [Optional]  SQL database name to protect.
                                        If omitted, discovered DBs are listed
                                        for interactive selection.
  -PolicyName               [Optional]  Backup policy name. If omitted,
                                        available policies are listed.
  -EnableAutoProtection     [Optional]  Enable auto-protection on a SQL
                                        instance instead of a single DB.
  -AutoProtectAllInstances  [Optional]  Auto-protect ALL SQL instances on the
                                        VM. Implies -EnableAutoProtection.
                                        Fully non-interactive with -PolicyName.
  -Token                    [Optional]  Pre-fetched bearer token. When provided,
                                        skips authentication. Used by the bulk
                                        wrapper script to avoid re-authenticating
                                        per VM. Not needed for standalone use.


API VERSION
-----------
  - 2025-08-01   All operations (discovery, registration, protection, policies)


SCENARIOS
---------

  1. Individual Database Protection
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  (mandatory only)                                Yes - prompts for DB + policy
  -DatabaseName "X"                               Prompts for policy
  -DatabaseName "X" -PolicyName "P"               NO - fully unattended
  -DatabaseName "X" -InstanceName "I" -Policy "P" NO - exact DB in exact instance

  2. Auto-Protection (Single Instance)
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  -EnableAutoProtection                           Prompts for policy + instance
  -EnableAutoProtection -PolicyName "P"           Prompts for instance if >1
  -EnableAutoProtection -InstanceName "I" -Pol "P"  NO - targets specific instance

  3. Auto-Protection (All Instances)
  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Params                                          Interactive?
  ------                                          ------------
  -AutoProtectAllInstances -PolicyName "P"        NO - loops through ALL instances

  Note: -AutoProtectAllInstances implies -EnableAutoProtection automatically.


EXAMPLES
--------

Example 1 - Protect a single database (interactive policy selection)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB"

  The script discovers sql-vm-01, registers it, inquires SQL workloads,
  finds SalesDB, lists available policies for selection, and enables
  protection with the chosen policy.


Example 2 - Protect a single database with a specific policy (non-interactive)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" `
        -PolicyName "HourlyLogBackup"

  Fully non-interactive. Policy is verified via API before use.


Example 3 - Protect a database in a specific instance (multi-instance VM)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -InstanceName "SQLEXPRESS" `
        -DatabaseName "SalesDB" `
        -PolicyName "HourlyLogBackup"

  Targets SalesDB specifically in the SQLEXPRESS instance. If the same DB
  name exists in MSSQLSERVER, it will not be matched.


Example 4 - Enable auto-protection on a specific instance
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -EnableAutoProtection `
        -InstanceName "MSSQLSERVER" `
        -PolicyName "HourlyLogBackup"

  Fully non-interactive. Targets the MSSQLSERVER instance.


Example 5 - Auto-protect ALL instances on the VM
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01" `
        -AutoProtectAllInstances `
        -PolicyName "HourlyLogBackup"

  Loops through every SQL instance on the VM and enables auto-protection
  on each. Shows per-instance success/failure and a final summary.
  No -EnableAutoProtection needed (implied).


Example 6 - Interactive mode (no DatabaseName, no PolicyName)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Register-SQLIaaSVM-ToVault.ps1 `
        -VaultSubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" `
        -VMResourceGroup "rg-sql" `
        -VMName "sql-vm-01"

  After discovery, the script lists all SQL databases (grouped by instance
  if multiple instances exist) and prompts to pick one or choose [A] for
  auto-protection. Then lists policies and prompts for selection.


SMART BEHAVIORS
---------------
  - VM already registered:    Skips registration, continues with inquiry.
  - Database already protected: Shows existing protection details, exits.
  - Multiple SQL instances:   Groups databases by instance in the display.
  - -DatabaseName in 2+ instances: Prompts to pick, suggests -InstanceName.
  - -InstanceName not found:  Lists available instances, exits with error.
  - Single SQL instance:      Auto-selects it without prompting.
  - PolicyName not found:     Exits with clear error (verified via API).
  - Case-insensitive DB match: Falls back to case-insensitive search.
  - Container name from API:  Uses discovered name, not manually constructed.
  - AutoProtectAllInstances:  Continues if some instances fail; shows summary.


OUTPUT
------
Color-coded console output:
  - Cyan:    Section headers, prompts, progress
  - Yellow:  Warnings and informational messages
  - Green:   Success confirmations
  - Gray:    Detail values (IDs, names, status)
  - Red:     Errors

On success, a final summary shows:
  - Database Name, Server Name, Parent Instance
  - Protection Status/State, Health Status
  - Last Backup Status/Time, Policy Name
  - Workload Type, Container Name

For auto-protection of multiple instances, a summary shows:
  - Total Instances, Succeeded, Failed


ERROR HANDLING
--------------
Common issues:
  - 401 Unauthorized:     Wrong subscription/tenant. Run Connect-AzAccount
                          with the correct -Subscription and -Tenant.
  - SecureString token:   Newer Az.Accounts modules return SecureString tokens.
                          The script handles both formats automatically
                          (uses NetworkCredential method for cross-platform).
  - VM not found:         Lists available VMs and suggests causes.
  - DB not found:         Lists available databases with instance names.
  - Instance not found:   Lists available instances, exits with error.
  - Registration fails:   Suggests SQL IaaS Agent extension, VM state, RBAC.
  - Policy not found:     Clear error with 404 detection.
  - Auto-protection 400:  Verify policy supports AzureWorkload type.


RECENT FIXES (March 19, 2026)
-----------------------------
  - Cross-RG container matching: Protectable container discovery now uses
    containerId (ARM resource ID) and container name pattern with resource
    group as primary match. Prevents picking up a VM with the same name
    from a different resource group (e.g., sqlserver-0 in IgniteSQLAGRG
    instead of kajaiccy).
  - SQL Instance discovery: Fixed issue where SQL instances were not found
    because serverName is an FQDN (e.g., sqlserver-0.contoso.com) not matching
    the short VM name. Now matches by container name in the protectable item ID.
  - Instance fallback: When databases are found but instances are not,
    the script extracts the container name from matched databases and
    searches for instances on that container.
  - Missing exit 0: Added explicit exit 0 at script end for success path
    to prevent stale $LASTEXITCODE from propagating.


PUBLIC DOCUMENTATION
--------------------
  Back up SQL databases in Azure VMs with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-sql-vm-rest-api

  Protection Containers - Register:
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/register

  Protection Intent - Create or Update (Auto-Protection):
    https://learn.microsoft.com/en-us/rest/api/backup/protection-intent/create-or-update

  Azure Backup REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/

================================================================================

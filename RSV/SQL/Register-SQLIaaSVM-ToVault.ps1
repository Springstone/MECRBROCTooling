<#
.SYNOPSIS
    Discovers, registers, and protects SQL Server databases on Azure IaaS VMs 
    to a Recovery Services Vault using REST API.

.DESCRIPTION
    This script discovers SQL Server databases running on Azure IaaS VMs and 
    configures backup protection using Azure Backup REST API.
    
    The script supports:
    - Discovery and registration of VMs with SQL workloads
    - Inquiry of SQL instances and databases within a VM
    - Individual database protection with a chosen policy
    - Auto-protection of an entire SQL instance (all current and future DBs)
    - Detection of already-registered VMs (skips re-registration)
    - Detection of already-protected databases (shows status)
    
    Flow:
    1. Refresh containers to discover VMs with SQL workloads
    2. List protectable containers to find the target VM
    3. Register the VM as a VMAppContainer (skip if already registered)
    4. Inquire SQL workloads inside the VM
    5. List protectable items (SQL databases)
    6. Check if the target DB is already protected
    7. List available backup policies for AzureWorkload
    8. Enable protection on the database OR enable auto-protection on the SQL instance
    9. Verify and display summary
    
    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on both the VM and Recovery Services Vault
    - SQL Server IaaS Agent extension installed on the VM

.PARAMETER VaultSubscriptionId
    The Subscription ID where the Recovery Services Vault is located.

.PARAMETER VaultResourceGroup
    The Resource Group name of the Recovery Services Vault.

.PARAMETER VaultName
    The name of the Recovery Services Vault.

.PARAMETER VMResourceGroup
    The Resource Group name of the SQL Server VM.

.PARAMETER VMName
    The name of the Azure VM hosting SQL Server.

.PARAMETER InstanceName
    The name of the SQL instance (e.g. MSSQLSERVER, SQLEXPRESS).
    When specified, filters databases and instances to only those belonging
    to this instance. Useful when a VM has multiple SQL instances and you
    want to target a specific one. Also used with -EnableAutoProtection to
    select the instance without prompting.

.PARAMETER DatabaseName
    The name of the SQL database to protect.
    Required when EnableAutoProtection is not specified.
    Ignored when EnableAutoProtection is specified.

.PARAMETER PolicyName
    The name of the backup policy to assign. If not specified, the script will 
    list available policies and prompt for selection.

.PARAMETER EnableAutoProtection
    When specified, enables auto-protection on the SQL instance instead of 
    protecting an individual database. All current and future databases 
    under the instance will be automatically protected.

.PARAMETER AutoProtectAllInstances
    When specified together with -EnableAutoProtection, automatically iterates
    through ALL SQL instances on the VM and enables auto-protection on each.
    No user interaction is required (fully unattended).

.EXAMPLE
    # Protect a single database (interactive policy selection)
    .\Register-SQLIaaSVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" -DatabaseName "SalesDB"

.EXAMPLE
    # Protect a single database with a specific policy
    .\Register-SQLIaaSVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -DatabaseName "SalesDB" -PolicyName "HourlyLogBackup"

.EXAMPLE
    # Enable auto-protection on the SQL instance (all current + future DBs)
    .\Register-SQLIaaSVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -EnableAutoProtection -PolicyName "HourlyLogBackup"

.EXAMPLE
    # Auto-protect ALL SQL instances on the VM (fully non-interactive)
    .\Register-SQLIaaSVM-ToVault.ps1 -VaultSubscriptionId "xxxx" -VaultResourceGroup "rg-vault" `
        -VaultName "myVault" -VMResourceGroup "rg-sql" -VMName "sql-vm-01" `
        -EnableAutoProtection -AutoProtectAllInstances -PolicyName "HourlyLogBackup"

.EXAMPLE
    # Run without parameters - PowerShell will prompt for all mandatory inputs
    .\Register-SQLIaaSVM-ToVault.ps1

.NOTES
    Author: Azure Backup Script Generator
    Date: March 12, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-sql-vm-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/register
    Reference: https://learn.microsoft.com/en-us/rest/api/backup/protection-intent/create-or-update
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Subscription ID where the Recovery Services Vault is located.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultSubscriptionId,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Recovery Services Vault.")]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter(Mandatory = $true, HelpMessage = "Resource Group name of the SQL Server VM.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMResourceGroup,

    [Parameter(Mandatory = $true, HelpMessage = "Name of the Azure VM hosting SQL Server.")]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SQL instance to target (e.g. MSSQLSERVER). Filters databases to this instance.")]
    [string]$InstanceName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the SQL database to protect. Required unless -EnableAutoProtection is specified.")]
    [string]$DatabaseName,

    [Parameter(Mandatory = $false, HelpMessage = "Name of the backup policy to assign. If omitted, available policies will be listed for selection.")]
    [string]$PolicyName,

    [Parameter(Mandatory = $false, HelpMessage = "Enable auto-protection on the SQL instance (protects all current and future databases).")]
    [switch]$EnableAutoProtection,

    [Parameter(Mandatory = $false, HelpMessage = "When used with -EnableAutoProtection, auto-protects ALL SQL instances on the VM without prompting.")]
    [switch]$AutoProtectAllInstances,

    [Parameter(Mandatory = $false, HelpMessage = "Pre-fetched bearer token. When provided, skips authentication. Used by bulk wrapper scripts.")]
    [string]$Token
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"             # Azure Backup REST API version for discovery/registration
$apiVersionProtection = "2025-08-01"   # Azure Backup REST API version for protection operations

# ============================================================================
# HELPER FUNCTION: Poll async operation via Location header
# ============================================================================

function Wait-ForAsyncOperation {
    param(
        [string]$LocationUrl,
        [hashtable]$Headers,
        [int]$MaxRetries = 20,
        [int]$DelaySeconds = 6,
        [string]$OperationName = "Operation"
    )
    
    if ([string]::IsNullOrWhiteSpace($LocationUrl)) {
        Write-Host "  No tracking URL available. Waiting ${DelaySeconds}s..." -ForegroundColor Yellow
        Start-Sleep -Seconds ($DelaySeconds * 3)
        return $true
    }
    
    $retryCount = 0
    while ($retryCount -lt $MaxRetries) {
        Start-Sleep -Seconds $DelaySeconds
        
        try {
            $statusResponse = Invoke-WebRequest -Uri $LocationUrl -Method GET -Headers $Headers -UseBasicParsing
            if ($statusResponse.StatusCode -eq 200 -or $statusResponse.StatusCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        } catch {
            $innerCode = $_.Exception.Response.StatusCode.value__
            if ($innerCode -eq 200 -or $innerCode -eq 204) {
                Write-Host "  $OperationName completed successfully" -ForegroundColor Green
                return $true
            }
        }
        
        $retryCount++
        Write-Host "  Waiting for $OperationName... ($retryCount/$MaxRetries)" -ForegroundColor Yellow
    }
    
    Write-Host "  WARNING: $OperationName timed out." -ForegroundColor Yellow
    return $false
}

# ============================================================================
# HELPER FUNCTION: Parse error response
# ============================================================================

function Write-ApiError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$Context = "API call"
    )
    
    $statusCode = $ErrorRecord.Exception.Response.StatusCode.value__
    Write-Host "  Status Code: $statusCode" -ForegroundColor Red
    Write-Host "  Error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
    
    try {
        $errorStream = $ErrorRecord.Exception.Response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($errorStream)
        $errorBody = $reader.ReadToEnd()
        $errorJson = $errorBody | ConvertFrom-Json
        
        if ($errorJson.error) {
            Write-Host "  Code: $($errorJson.error.code)" -ForegroundColor Red
            Write-Host "  Message: $($errorJson.error.message)" -ForegroundColor Red
        }
    } catch {
        # Could not parse error response
    }
}

# ============================================================================
# PARAMETER VALIDATION & DEFAULTS
# ============================================================================

# Map parameters to internal variable names used throughout the script
$vaultSubscriptionId = $VaultSubscriptionId
$vaultResourceGroup  = $VaultResourceGroup
$vaultName           = $VaultName
$vmSubscriptionId    = $VaultSubscriptionId  # VM is assumed to be in the same subscription as the vault
$vmResourceGroup     = $VMResourceGroup
$vmName              = $VMName
$instanceName        = $InstanceName
$dbName              = $DatabaseName
$enableAutoProtection = $EnableAutoProtection.IsPresent -or $AutoProtectAllInstances.IsPresent

# Construct VM Resource ID
$vmResourceId = "/subscriptions/$vmSubscriptionId/resourceGroups/$vmResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

# ============================================================================
# DISPLAY CONFIGURATION SUMMARY
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  SQL Server on Azure IaaS VM - Backup Protection" -ForegroundColor Cyan
Write-Host "  (Using Azure Backup REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Configuration Summary:" -ForegroundColor Yellow
Write-Host "  Vault Subscription:  $vaultSubscriptionId" -ForegroundColor Gray
Write-Host "  Vault Resource Group:$vaultResourceGroup" -ForegroundColor Gray
Write-Host "  Vault Name:          $vaultName" -ForegroundColor Gray
Write-Host "  VM Resource Group:   $vmResourceGroup" -ForegroundColor Gray
Write-Host "  VM Name:             $vmName" -ForegroundColor Gray
Write-Host "  VM Resource ID:      $vmResourceId" -ForegroundColor Gray
if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
    Write-Host "  Instance Name:       $instanceName" -ForegroundColor Gray
} else {
    Write-Host "  Instance Name:       (all instances)" -ForegroundColor Gray
}
if ($enableAutoProtection) {
    Write-Host "  Protection Mode:     Auto-Protection (all current + future DBs)" -ForegroundColor Green
} else {
    if (-not [string]::IsNullOrWhiteSpace($dbName)) {
        Write-Host "  Database Name:       $dbName" -ForegroundColor Gray
    } else {
        Write-Host "  Database Name:       (will be selected after discovery)" -ForegroundColor Gray
    }
    Write-Host "  Protection Mode:     Individual Database" -ForegroundColor Gray
}
if (-not [string]::IsNullOrWhiteSpace($PolicyName)) {
    Write-Host "  Policy Name:         $PolicyName" -ForegroundColor Gray
} else {
    Write-Host "  Policy Name:         (will be selected interactively)" -ForegroundColor Gray
}
Write-Host ""

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null
$authMethod = $null

# Use pre-fetched token if provided (e.g. from bulk wrapper)
if (-not [string]::IsNullOrWhiteSpace($Token)) {
    $token = $Token
    $authMethod = "Pre-fetched Token"
    Write-Host "  Using pre-fetched token (passed via -Token parameter)" -ForegroundColor Green
} else {
# Try Azure PowerShell first
try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    
    # Handle both old (plain string) and new (SecureString) Az.Accounts module versions
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        # Use NetworkCredential trick - works reliably on both Windows and Linux
        $token = [System.Net.NetworkCredential]::new('', $tokenResponse.Token).Password
    } else {
        $token = $tokenResponse.Token
    }
    
    # Validate token looks like a JWT (starts with eyJ)
    if (-not $token.StartsWith("eyJ")) {
        Write-Host "  WARNING: Token does not appear to be a valid JWT. Trying Azure CLI fallback..." -ForegroundColor Yellow
        throw "Invalid token format"
    }
    
    $authMethod = "Azure PowerShell"
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    # If Azure PowerShell fails, try Azure CLI
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow
    
    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            $tokenObject = $azTokenOutput | ConvertFrom-Json
            $token = $tokenObject.accessToken
            $authMethod = "Azure CLI"
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else {
            throw "Azure CLI authentication failed"
        }
    } catch {
        Write-Host ""
        Write-Host "ERROR: Failed to authenticate to Azure." -ForegroundColor Red
        Write-Host ""
        Write-Host "Please authenticate using one of these methods:" -ForegroundColor Yellow
        Write-Host "  1. Azure PowerShell: Connect-AzAccount" -ForegroundColor White
        Write-Host "  2. Azure CLI: az login" -ForegroundColor White
        Write-Host ""
        Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}
} # end else (no pre-fetched token)

# Create common headers
$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# STEP 1: REFRESH CONTAINER DISCOVERY (Discover VMs with SQL workloads)
# ============================================================================

Write-Host ""
Write-Host "STEP 1: Discovering VMs with SQL Workloads" -ForegroundColor Yellow
Write-Host "--------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Triggering refresh to discover SQL workloads in the subscription..." -ForegroundColor Cyan

$refreshUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/refreshContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

try {
    $refreshResponse = Invoke-WebRequest -Uri $refreshUri -Method POST -Headers $headers -UseBasicParsing
    $statusCode = $refreshResponse.StatusCode
    
    if ($statusCode -eq 202) {
        Write-Host "  Refresh operation accepted (202)" -ForegroundColor Green
        $locationUrl = $refreshResponse.Headers["Location"]
        Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -OperationName "Discovery" | Out-Null
    } elseif ($statusCode -eq 204) {
        Write-Host "  Discovery completed immediately (204)" -ForegroundColor Green
    } else {
        Write-Host "  Refresh returned status: $statusCode" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Refresh operation accepted (202)" -ForegroundColor Green
        try {
            $locationUrl = $_.Exception.Response.Headers.Location
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -OperationName "Discovery" | Out-Null
        } catch {
            Start-Sleep -Seconds 15
        }
    } elseif ($statusCode -eq 204) {
        Write-Host "  Discovery completed (204)" -ForegroundColor Green
    } else {
        Write-Host "  WARNING: Refresh returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 2: LIST PROTECTABLE CONTAINERS (Find the VM with SQL)
# ============================================================================

Write-Host ""
Write-Host "STEP 2: Listing VMs with SQL Databases" -ForegroundColor Yellow
Write-Host "----------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectableContainersUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectableContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureWorkload'"

$matchingContainer = $null
$containerName = $null
$isAlreadyRegistered = $false

try {
    Write-Host "Querying for protectable containers (VMs with SQL)..." -ForegroundColor Cyan
    $containersResponse = Invoke-RestMethod -Uri $protectableContainersUri -Method GET -Headers $headers
    
    if ($containersResponse.value -and $containersResponse.value.Count -gt 0) {
        Write-Host "  Found $($containersResponse.value.Count) protectable container(s)" -ForegroundColor Green
        Write-Host ""
        
        # Find the matching VM - use containerId (ARM resource ID) first for precision,
        # then fall back to friendlyName + RG in container name, then friendlyName only
        $matchingContainer = $null

        # Priority 1: Match by containerId (most precise - includes resource group)
        $matchingContainer = $containersResponse.value | Where-Object {
            $_.properties.containerId -ieq $vmResourceId
        } | Select-Object -First 1

        # Priority 2: Match by container name pattern (includes resource group)
        if (-not $matchingContainer) {
            $expectedContainerPattern = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
            $matchingContainer = $containersResponse.value | Where-Object {
                $_.name -ieq $expectedContainerPattern
            } | Select-Object -First 1
        }

        # Priority 3: Match by friendlyName + verify resource group
        if (-not $matchingContainer) {
            $nameMatches = @($containersResponse.value | Where-Object {
                $_.properties.friendlyName -ieq $vmName
            })
            if ($nameMatches.Count -ge 1) {
                # Always try to filter by resource group first
                $rgFiltered = $nameMatches | Where-Object {
                    $_.properties.containerId -imatch "/resourceGroups/$([regex]::Escape($vmResourceGroup))/"
                } | Select-Object -First 1
                if ($rgFiltered) {
                    $matchingContainer = $rgFiltered
                } elseif ($nameMatches.Count -eq 1) {
                    # Single match but different RG - warn and use it
                    Write-Host "  WARNING: Found VM '$vmName' but in different resource group. Using it as fallback." -ForegroundColor Yellow
                    $matchingContainer = $nameMatches[0]
                } else {
                    Write-Host "  WARNING: Multiple VMs named '$vmName' found but none in resource group '$vmResourceGroup'." -ForegroundColor Yellow
                    Write-Host "  Constructing container name manually..." -ForegroundColor Yellow
                }
            }
        }

        if ($matchingContainer) {
            
            $containerName = $matchingContainer.name
            Write-Host "  Target VM found:" -ForegroundColor Green
            Write-Host "    Friendly Name:   $($matchingContainer.properties.friendlyName)" -ForegroundColor Gray
            Write-Host "    Container Name:  $containerName" -ForegroundColor Gray
            Write-Host "    Container Type:  $($matchingContainer.properties.protectableContainerType)" -ForegroundColor Gray
            Write-Host "    Health Status:   $($matchingContainer.properties.healthStatus)" -ForegroundColor Gray
            Write-Host "    Container ID:    $($matchingContainer.properties.containerId)" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: VM '$vmName' not found in protectable containers." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Available VMs with SQL:" -ForegroundColor Yellow
            foreach ($c in $containersResponse.value) {
                Write-Host "    - $($c.properties.friendlyName) (Type: $($c.properties.protectableContainerType))" -ForegroundColor White
            }
            Write-Host ""
            Write-Host "  Constructing container name manually..." -ForegroundColor Yellow
            $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
            Write-Host "    Container Name: $containerName" -ForegroundColor Gray
        }
    } else {
        Write-Host "  No protectable containers found." -ForegroundColor Yellow
        Write-Host "  Constructing container name manually..." -ForegroundColor Yellow
        $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
        Write-Host "    Container Name: $containerName" -ForegroundColor Gray
    }
} catch {
    Write-Host "  WARNING: Failed to list protectable containers: $($_.Exception.Message)" -ForegroundColor Yellow
    $containerName = "VMAppContainer;Compute;$vmResourceGroup;$vmName"
    Write-Host "    Container Name: $containerName" -ForegroundColor Gray
}

# ============================================================================
# STEP 3: REGISTER VM WITH RECOVERY SERVICES VAULT (Skip if already registered)
# ============================================================================

Write-Host ""
Write-Host "STEP 3: Registering VM with Recovery Services Vault" -ForegroundColor Yellow
Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
Write-Host ""

# First check if already registered by querying the container
$containerCheckUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

try {
    Write-Host "Checking if VM is already registered..." -ForegroundColor Cyan
    $containerCheckResponse = Invoke-RestMethod -Uri $containerCheckUri -Method GET -Headers $headers
    
    if ($containerCheckResponse -and $containerCheckResponse.properties.registrationStatus -eq "Registered") {
        $isAlreadyRegistered = $true
        Write-Host ""
        Write-Host "  VM is ALREADY REGISTERED with the vault. Skipping registration." -ForegroundColor Green
        Write-Host "    Registration Status: $($containerCheckResponse.properties.registrationStatus)" -ForegroundColor Gray
        Write-Host "    Health Status:       $($containerCheckResponse.properties.healthStatus)" -ForegroundColor Gray
        Write-Host "    Friendly Name:       $($containerCheckResponse.properties.friendlyName)" -ForegroundColor Gray
        
        # Update container name from actual response
        if ($containerCheckResponse.name) {
            $containerName = $containerCheckResponse.name
        }
    } else {
        Write-Host "  VM found but registration status: $($containerCheckResponse.properties.registrationStatus)" -ForegroundColor Yellow
        Write-Host "  Proceeding with registration..." -ForegroundColor Yellow
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    if ($statusCode -eq 404) {
        Write-Host "  VM is not registered. Proceeding with registration..." -ForegroundColor Cyan
    } else {
        Write-Host "  Could not check registration status (HTTP $statusCode). Proceeding..." -ForegroundColor Yellow
    }
}

if (-not $isAlreadyRegistered) {
    Write-Host ""
    Write-Host "Registering VM as VMAppContainer..." -ForegroundColor Cyan
    
    $registerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"
    
    # Construct sourceResourceId from the protectable containers response or manually
    $sourceResId = $vmResourceId
    $friendlyNameForReg = $vmName
    if ($matchingContainer) {
        if ($matchingContainer.properties.containerId) {
            $sourceResId = $matchingContainer.properties.containerId
        } elseif ($matchingContainer.id) {
            $sourceResId = $matchingContainer.id
        }
        if ($matchingContainer.properties.friendlyName) {
            $friendlyNameForReg = $matchingContainer.properties.friendlyName
        }
    }
    
    $registerBody = @{
        properties = @{
            backupManagementType = "AzureWorkload"
            containerType        = "VMAppContainer"
            friendlyName         = $friendlyNameForReg
            sourceResourceId     = $sourceResId
            workloadType         = "SQLDataBase"
        }
    } | ConvertTo-Json -Depth 10
    
    try {
        $registerResponse = Invoke-WebRequest -Uri $registerUri -Method PUT -Headers $headers -Body $registerBody -UseBasicParsing
        $statusCode = $registerResponse.StatusCode
        
        if ($statusCode -eq 200) {
            Write-Host "  Registration completed (200 OK)" -ForegroundColor Green
            $regBody = $registerResponse.Content | ConvertFrom-Json
            Write-Host "    Registration Status: $($regBody.properties.registrationStatus)" -ForegroundColor Gray
        } elseif ($statusCode -eq 202) {
            Write-Host "  Registration accepted (202). Tracking operation..." -ForegroundColor Green
            $locationUrl = $registerResponse.Headers["Location"]
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 60 -DelaySeconds 10 -OperationName "Registration" | Out-Null
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        if ($statusCode -eq 202) {
            Write-Host "  Registration accepted (202)." -ForegroundColor Green
            try {
                $locationUrl = $_.Exception.Response.Headers.Location
                Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 60 -DelaySeconds 10 -OperationName "Registration" | Out-Null
            } catch {
                Start-Sleep -Seconds 30
            }
        } else {
            Write-Host ""
            Write-Host "ERROR: Failed to register VM with vault." -ForegroundColor Red
            Write-ApiError -ErrorRecord $_ -Context "Container Registration"
            Write-Host ""
            Write-Host "Possible causes:" -ForegroundColor Yellow
            Write-Host "  1. VM doesn't exist or resource ID is incorrect" -ForegroundColor White
            Write-Host "  2. Insufficient permissions on the VM or vault" -ForegroundColor White
            Write-Host "  3. SQL Server IaaS Agent extension is not installed on the VM" -ForegroundColor White
            Write-Host "  4. VM is deallocated or stopped" -ForegroundColor White
            Write-Host ""
            exit 1
        }
    }
    
    # Verify registration
    Write-Host ""
    Write-Host "Verifying registration..." -ForegroundColor Cyan
    Start-Sleep -Seconds 5
    
    try {
        $verifyRegResponse = Invoke-RestMethod -Uri $containerCheckUri -Method GET -Headers $headers
        if ($verifyRegResponse.properties.registrationStatus -eq "Registered") {
            Write-Host "  Registration verified: $($verifyRegResponse.properties.registrationStatus)" -ForegroundColor Green
        } else {
            Write-Host "  Registration status: $($verifyRegResponse.properties.registrationStatus)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Could not verify registration immediately. Continuing..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 4: INQUIRE SQL WORKLOADS INSIDE THE VM
# ============================================================================

Write-Host ""
Write-Host "STEP 4: Discovering SQL Databases Inside VM" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

Write-Host "Inquiring SQL workloads inside '$vmName'..." -ForegroundColor Cyan

$inquireUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/inquire?api-version=$apiVersion&`$filter=workloadType eq 'SQLDataBase'"

try {
    $inquireResponse = Invoke-WebRequest -Uri $inquireUri -Method POST -Headers $headers -UseBasicParsing
    $statusCode = $inquireResponse.StatusCode
    
    if ($statusCode -eq 202) {
        Write-Host "  Inquiry accepted (202). Tracking..." -ForegroundColor Green
        $locationUrl = $inquireResponse.Headers["Location"]
        Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "SQL workload inquiry" | Out-Null
    } elseif ($statusCode -eq 200 -or $statusCode -eq 204) {
        Write-Host "  Inquiry completed ($statusCode)" -ForegroundColor Green
    }
} catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    
    if ($statusCode -eq 202) {
        Write-Host "  Inquiry accepted (202)." -ForegroundColor Green
        try {
            $locationUrl = $_.Exception.Response.Headers.Location
            Wait-ForAsyncOperation -LocationUrl $locationUrl -Headers $headers -MaxRetries 20 -DelaySeconds 8 -OperationName "SQL workload inquiry" | Out-Null
        } catch {
            Start-Sleep -Seconds 20
        }
    } else {
        Write-Host "  WARNING: Inquiry returned: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  Continuing with protectable items query..." -ForegroundColor Yellow
    }
}

# ============================================================================
# STEP 5: LIST PROTECTABLE ITEMS (SQL Databases)
# ============================================================================

Write-Host ""
Write-Host "STEP 5: Listing Protectable SQL Databases" -ForegroundColor Yellow
Write-Host "--------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$protectableItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectableItems?api-version=$apiVersionProtection&`$filter=backupManagementType eq 'AzureWorkload'"

$allProtectableItems = @()
$matchingDB = $null
$matchingInstance = $null

try {
    Write-Host "Querying for protectable SQL items..." -ForegroundColor Cyan
    
    $currentUri = $protectableItemsUri
    while ($currentUri) {
        $itemsResponse = Invoke-RestMethod -Uri $currentUri -Method GET -Headers $headers
        
        if ($itemsResponse.value) {
            $allProtectableItems += $itemsResponse.value
        }
        
        $currentUri = $itemsResponse.nextLink
        if ($currentUri) {
            Write-Host "  Fetching next page of results..." -ForegroundColor Gray
        }
    }
    
    if ($allProtectableItems.Count -gt 0) {
        # Filter items belonging to our VM (exact match to avoid similar VM names)
        # e.g., ";sql-vm" suffix would falsely match "prod-sql-vm"
        $vmNameLowerReg = $vmName.ToLower()
        $expectedContainerFull = "VMAppContainer;Compute;$vmResourceGroup;$vmName".ToLower()
        $vmItems = $allProtectableItems | Where-Object {
            $sn = if ($_.properties.serverName) { $_.properties.serverName.ToLower() } else { "" }
            $itemId = if ($_.id) { $_.id.ToLower() } else { "" }
            $snClean = $sn.TrimEnd('.')
            $idContainer = ""
            if ($itemId -match "/protectioncontainers/([^/]+)/") { $idContainer = $Matches[1] }
            # Match by full container name in ID (works for both databases and instances)
            ($idContainer -ieq $expectedContainerFull) -or
            # Also check if the item ID contains the container pattern (handles path variants)
            ($itemId.Contains($expectedContainerFull)) -or
            # Match serverName (VM hostname) + verify RG in container for databases
            (($snClean -ieq $vmNameLowerReg -or $sn -ieq $vmNameLowerReg) -and $idContainer -imatch ";$([regex]::Escape($vmResourceGroup.ToLower()));")
        }

        # Fallback: if no items found with RG-aware match, try name-only
        if ($vmItems.Count -eq 0) {
            $vmItems = $allProtectableItems | Where-Object {
                $sn = if ($_.properties.serverName) { $_.properties.serverName.ToLower() } else { "" }
                $itemId = if ($_.id) { $_.id.ToLower() } else { "" }
                $snClean = $sn.TrimEnd('.')
                $cnLastSegment = ""
                if ($itemId -match "/protectioncontainers/([^/]+)/") {
                    $cn = $Matches[1]
                    $cnLastSegment = if ($cn.Contains(";")) { $cn.Split(";")[-1] } else { $cn }
                }
                ($snClean -ieq $vmNameLowerReg) -or ($sn -ieq $vmNameLowerReg) -or ($cnLastSegment -ieq $vmNameLowerReg)
            }
            if ($vmItems.Count -gt 0) {
                Write-Host "  WARNING: Matched protectable items by server name only (no RG match). Verify results." -ForegroundColor Yellow
            }
        }
        
        # Separate databases and instances
        $sqlDatabases = @($vmItems | Where-Object { $_.properties.protectableItemType -ieq "SQLDataBase" })
        $sqlInstances = @($vmItems | Where-Object { $_.properties.protectableItemType -ieq "SQLInstance" })

        # If databases found but no instances, search for instances by container name from matched databases
        if ($sqlDatabases.Count -gt 0 -and $sqlInstances.Count -eq 0) {
            # Extract the actual container name from a matched database's ID
            $dbContainerName = ""
            if ($sqlDatabases[0].id -match "/protectionContainers/([^/]+)/") {
                $dbContainerName = $Matches[1]
            }

            if ($dbContainerName) {
                Write-Host "  Searching for SQL instances on container '$dbContainerName'..." -ForegroundColor Cyan
                $sqlInstances = @($allProtectableItems | Where-Object {
                    $_.properties.protectableItemType -ieq "SQLInstance" -and
                    $_.id -imatch [regex]::Escape($dbContainerName)
                })
            }

            # Still empty? Try matching by container name pattern in the full protectable items list
            if ($sqlInstances.Count -eq 0) {
                $sqlInstances = @($allProtectableItems | Where-Object {
                    $_.properties.protectableItemType -ieq "SQLInstance" -and
                    $_.id -imatch [regex]::Escape("$vmResourceGroup;$vmName")
                })
            }

            if ($sqlInstances.Count -gt 0) {
                Write-Host "  Found $($sqlInstances.Count) SQL instance(s) via container lookup" -ForegroundColor Green
            }
        }

        Write-Host "  Found $($sqlDatabases.Count) SQL database(s) and $($sqlInstances.Count) SQL instance(s) on VM '$vmName'" -ForegroundColor Green
        Write-Host ""
        
        # Filter by -InstanceName if provided
        if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
            $filteredDatabases = @($sqlDatabases | Where-Object { $_.properties.parentName -ieq $instanceName })
            $filteredInstances = @($sqlInstances | Where-Object { $_.properties.friendlyName -ieq $instanceName })
            
            if ($filteredDatabases.Count -eq 0 -and $filteredInstances.Count -eq 0) {
                Write-Host "  WARNING: Instance '$instanceName' not found on VM '$vmName'." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Available instances:" -ForegroundColor Yellow
                foreach ($inst in $sqlInstances) {
                    Write-Host "    - $($inst.properties.friendlyName)" -ForegroundColor White
                }
                Write-Host ""
                exit 1
            }
            
            Write-Host "  Filtered to instance '$instanceName': $($filteredDatabases.Count) database(s)" -ForegroundColor Cyan
            $sqlDatabases = $filteredDatabases
            $sqlInstances = $filteredInstances
            Write-Host ""
        }
        
        # Show SQL instances
        if ($sqlInstances.Count -gt 0) {
            Write-Host "  SQL Instances:" -ForegroundColor Cyan
            foreach ($inst in $sqlInstances) {
                $autoProtectable = if ($inst.properties.isAutoProtectable) { "Yes" } else { "No" }
                Write-Host "    - $($inst.properties.friendlyName) (Server: $($inst.properties.serverName), Auto-protectable: $autoProtectable)" -ForegroundColor White
            }
            Write-Host ""
        }
        
        # Show SQL databases grouped by instance
        if ($sqlDatabases.Count -gt 0) {
            $instanceGroups = $sqlDatabases | Group-Object { $_.properties.parentName }
            if ($instanceGroups.Count -gt 1) {
                Write-Host "  SQL Databases (grouped by instance):" -ForegroundColor Cyan
                foreach ($group in $instanceGroups) {
                    Write-Host "    [$($group.Name)]" -ForegroundColor Yellow
                    foreach ($db in $group.Group) {
                        $state = $db.properties.protectionState
                        if (-not $state) { $state = "NotProtected" }
                        Write-Host "      - $($db.properties.friendlyName) (State: $state)" -ForegroundColor White
                    }
                }
            } else {
                Write-Host "  SQL Databases:" -ForegroundColor Cyan
                foreach ($db in $sqlDatabases) {
                    $state = $db.properties.protectionState
                    if (-not $state) { $state = "NotProtected" }
                    Write-Host "    - $($db.properties.friendlyName) (Instance: $($db.properties.parentName), State: $state)" -ForegroundColor White
                }
            }
            Write-Host ""
        }
        
        if (-not $enableAutoProtection) {
            # If DatabaseName was not provided, prompt user to select from discovered list
            if ([string]::IsNullOrWhiteSpace($dbName)) {
                if ($sqlDatabases.Count -eq 0 -and $sqlInstances.Count -eq 0) {
                    Write-Host "  ERROR: No SQL databases or instances found on VM '$vmName'." -ForegroundColor Red
                    Write-Host "  Cannot proceed without a database to protect." -ForegroundColor Yellow
                    exit 1
                }
                
                Write-Host "  Select protection mode:" -ForegroundColor Cyan
                Write-Host ""
                
                # Show auto-protection option if instances are available
                if ($sqlInstances.Count -gt 0) {
                    $autoProtectableInstances = $sqlInstances | Where-Object { $_.properties.isAutoProtectable -eq $true }
                    if ($autoProtectableInstances.Count -gt 0) {
                        Write-Host "    [A] AUTO-PROTECT entire SQL instance - all current and future DBs" -ForegroundColor Green
                    }
                }
                
                # Show individual database options
                $dbIdx = 1
                foreach ($db in $sqlDatabases) {
                    $state = $db.properties.protectionState
                    if (-not $state) { $state = "NotProtected" }
                    Write-Host "    [$dbIdx] $($db.properties.friendlyName) (Instance: $($db.properties.parentName), State: $state)" -ForegroundColor White
                    $dbIdx++
                }
                Write-Host ""
                $dbChoice = Read-Host '  Enter number for individual DB, or A for auto-protection (default: 1)'
                
                if ($dbChoice -ieq 'A') {
                    # User chose auto-protection
                    $enableAutoProtection = $true
                    Write-Host ""
                    Write-Host "  Auto-protection mode selected." -ForegroundColor Green
                } else {
                    if ([string]::IsNullOrWhiteSpace($dbChoice)) { $dbChoice = "1" }
                    $dbSelectedIdx = [int]$dbChoice - 1
                    if ($dbSelectedIdx -ge 0 -and $dbSelectedIdx -lt $sqlDatabases.Count) {
                        $matchingDB = $sqlDatabases[$dbSelectedIdx]
                    } else {
                        Write-Host "  Invalid selection. Using first database." -ForegroundColor Yellow
                        $matchingDB = $sqlDatabases[0]
                    }
                    if ($matchingDB -is [array]) { $matchingDB = $matchingDB[0] }
                    $dbName = $matchingDB.properties.friendlyName
                    
                    Write-Host ""
                    Write-Host "  Selected database: $dbName" -ForegroundColor Green
                    Write-Host "    Parent Instance: $($matchingDB.properties.parentName)" -ForegroundColor Gray
                    Write-Host "    Server Name:     $($matchingDB.properties.serverName)" -ForegroundColor Gray
                    Write-Host "    Protection State:$($matchingDB.properties.protectionState)" -ForegroundColor Gray
                    Write-Host "    Item Name:       $($matchingDB.name)" -ForegroundColor Gray
                }
            } else {
                # DatabaseName was provided - find it in the list
                # If InstanceName is also provided, filter by both
                if (-not [string]::IsNullOrWhiteSpace($instanceName)) {
                    $matchingDB = $sqlDatabases | Where-Object {
                        $_.properties.friendlyName -ieq $dbName -and $_.properties.parentName -ieq $instanceName
                    }
                } else {
                    $matchingDB = $sqlDatabases | Where-Object {
                        $_.properties.friendlyName -eq $dbName
                    }
                    
                    if (-not $matchingDB) {
                        # Try case-insensitive match
                        $matchingDB = $sqlDatabases | Where-Object {
                            $_.properties.friendlyName -ieq $dbName
                        }
                    }
                    
                    # If multiple matches (same DB name in different instances), warn and prompt
                    if ($matchingDB -is [array] -and $matchingDB.Count -gt 1) {
                        Write-Host "  WARNING: Database '$dbName' exists in multiple instances:" -ForegroundColor Yellow
                        $mIdx = 1
                        foreach ($mdb in $matchingDB) {
                            Write-Host "    [$mIdx] $($mdb.properties.friendlyName) (Instance: $($mdb.properties.parentName))" -ForegroundColor White
                            $mIdx++
                        }
                        Write-Host ""
                        Write-Host "  TIP: Use -InstanceName to target a specific instance." -ForegroundColor Cyan
                        $mChoice = Read-Host '  Select instance (default: 1)'
                        if ([string]::IsNullOrWhiteSpace($mChoice)) { $mChoice = "1" }
                        $mSelectedIdx = [int]$mChoice - 1
                        if ($mSelectedIdx -ge 0 -and $mSelectedIdx -lt $matchingDB.Count) {
                            $matchingDB = $matchingDB[$mSelectedIdx]
                        } else {
                            $matchingDB = $matchingDB[0]
                        }
                    }
                }
                
                if ($matchingDB) {
                    if ($matchingDB -is [array]) { $matchingDB = $matchingDB[0] }
                    
                    Write-Host "  Target database found:" -ForegroundColor Green
                    Write-Host "    Friendly Name:   $($matchingDB.properties.friendlyName)" -ForegroundColor Gray
                    Write-Host "    Parent Instance: $($matchingDB.properties.parentName)" -ForegroundColor Gray
                    Write-Host "    Server Name:     $($matchingDB.properties.serverName)" -ForegroundColor Gray
                    Write-Host "    Protection State:$($matchingDB.properties.protectionState)" -ForegroundColor Gray
                    Write-Host "    Item Name:       $($matchingDB.name)" -ForegroundColor Gray
                } else {
                    Write-Host "  WARNING: Database '$dbName' not found in protectable items." -ForegroundColor Yellow
                    Write-Host ""
                    Write-Host "  Available databases on this VM:" -ForegroundColor Yellow
                    foreach ($db in $sqlDatabases) {
                        Write-Host "    - $($db.properties.friendlyName)" -ForegroundColor White
                    }
                    Write-Host ""
                    Write-Host "  This could mean:" -ForegroundColor Yellow
                    Write-Host "    1. Database name is incorrect" -ForegroundColor White
                    Write-Host "    2. Database is already protected" -ForegroundColor White
                    Write-Host "    3. Inquiry hasn't completed yet" -ForegroundColor White
                    Write-Host ""
                    exit 1
                }
            }
        }
        
        # Find the SQL instance(s) for auto-protection
        if ($enableAutoProtection) {
            if ($sqlInstances.Count -gt 0) {
                # If -InstanceName was provided (and not -AutoProtectAllInstances), use it to select the instance
                if (-not [string]::IsNullOrWhiteSpace($instanceName) -and -not $AutoProtectAllInstances.IsPresent) {
                    $matchingInstance = $sqlInstances | Where-Object { $_.properties.friendlyName -ieq $instanceName }
                    if ($matchingInstance) {
                        if ($matchingInstance -is [array]) { $matchingInstance = $matchingInstance[0] }
                        $allInstancesToProtect = @($matchingInstance)
                        Write-Host ""
                        Write-Host "  Selected SQL Instance (via -InstanceName):" -ForegroundColor Green
                        Write-Host "    Instance Name: $($matchingInstance.properties.friendlyName)" -ForegroundColor Gray
                        Write-Host "    Server Name:   $($matchingInstance.properties.serverName)" -ForegroundColor Gray
                        Write-Host "    Item Name:     $($matchingInstance.name)" -ForegroundColor Gray
                    } else {
                        Write-Host "  ERROR: Instance '$instanceName' not found on VM '$vmName'." -ForegroundColor Red
                        Write-Host "  Available instances:" -ForegroundColor Yellow
                        foreach ($inst in $sqlInstances) {
                            Write-Host "    - $($inst.properties.friendlyName)" -ForegroundColor White
                        }
                        exit 1
                    }
                } elseif ($AutoProtectAllInstances.IsPresent) {
                    # Auto-protect ALL instances - store them in an array for later iteration
                    $allInstancesToProtect = @($sqlInstances)
                    Write-Host ""
                    Write-Host "  AutoProtectAllInstances: Will protect $($allInstancesToProtect.Count) SQL instance(s):" -ForegroundColor Green
                    foreach ($inst in $allInstancesToProtect) {
                        Write-Host "    - $($inst.properties.friendlyName) (Server: $($inst.properties.serverName))" -ForegroundColor Gray
                    }
                    # Set matchingInstance to first for backward compatibility (Step 8A handles the loop)
                    $matchingInstance = $allInstancesToProtect[0]
                } elseif ($sqlInstances.Count -eq 1) {
                    $matchingInstance = $sqlInstances[0]
                    $allInstancesToProtect = @($matchingInstance)
                    Write-Host ""
                    Write-Host "  Selected SQL Instance for auto-protection:" -ForegroundColor Green
                    Write-Host "    Instance Name: $($matchingInstance.properties.friendlyName)" -ForegroundColor Gray
                    Write-Host "    Server Name:   $($matchingInstance.properties.serverName)" -ForegroundColor Gray
                    Write-Host "    Item Name:     $($matchingInstance.name)" -ForegroundColor Gray
                } else {
                    Write-Host "  Multiple SQL instances found. Select one:" -ForegroundColor Cyan
                    $idx = 1
                    foreach ($inst in $sqlInstances) {
                        Write-Host "    [$idx] $($inst.properties.friendlyName) (Server: $($inst.properties.serverName))" -ForegroundColor White
                        $idx++
                    }
                    $instChoice = Read-Host "  Enter number (default: 1)"
                    if ([string]::IsNullOrWhiteSpace($instChoice)) { $instChoice = "1" }
                    $instIdx = [int]$instChoice - 1
                    if ($instIdx -ge 0 -and $instIdx -lt $sqlInstances.Count) {
                        $matchingInstance = $sqlInstances[$instIdx]
                    } else {
                        $matchingInstance = $sqlInstances[0]
                    }
                    $allInstancesToProtect = @($matchingInstance)
                    Write-Host ""
                    Write-Host "  Selected SQL Instance for auto-protection:" -ForegroundColor Green
                    Write-Host "    Instance Name: $($matchingInstance.properties.friendlyName)" -ForegroundColor Gray
                    Write-Host "    Server Name:   $($matchingInstance.properties.serverName)" -ForegroundColor Gray
                    Write-Host "    Item Name:     $($matchingInstance.name)" -ForegroundColor Gray
                }
            } else {
                Write-Host "  WARNING: No SQL instances found on VM '$vmName'." -ForegroundColor Yellow
                Write-Host "  Cannot enable auto-protection without an instance." -ForegroundColor Yellow
                exit 1
            }
        }
    } else {
        Write-Host ""
        Write-Host "ERROR: No protectable SQL items discovered." -ForegroundColor Red
        Write-Host "  Ensure the SQL Server IaaS Agent extension is installed and the VM is running." -ForegroundColor Yellow
        exit 1
    }
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to list protectable items: $($_.Exception.Message)" -ForegroundColor Red
    Write-ApiError -ErrorRecord $_ -Context "List protectable items"
    exit 1
}

# ============================================================================
# STEP 6: CHECK IF DATABASE IS ALREADY PROTECTED
# ============================================================================

Write-Host ""
Write-Host "STEP 6: Checking Existing Protection Status" -ForegroundColor Yellow
Write-Host "----------------------------------------------" -ForegroundColor Yellow
Write-Host ""

$isAlreadyProtected = $false

if (-not $enableAutoProtection -and $matchingDB) {
    # Extract container and protected item name from the protectable item ID
    # ID format: .../protectionContainers/{containerName}/protectableItems/{itemName}
    $dbItemId = $matchingDB.id
    $dbItemName = $matchingDB.name
    
    # The container name from the protectable item ID
    # Parse it from the ID path
    $idParts = $dbItemId -split "/protectableItems/"
    $containerPath = $idParts[0]
    $containerFromId = ($containerPath -split "/protectionContainers/")[1]
    if (-not [string]::IsNullOrWhiteSpace($containerFromId)) {
        $containerName = $containerFromId
    }
    
    # Protected item name uses the database item name
    $protectedItemName = $dbItemName
    
    # Construct the protected item URI to check
    $protectedItemUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"
    
    try {
        Write-Host "Checking if database '$dbName' is already protected..." -ForegroundColor Cyan
        $protectedItemResponse = Invoke-RestMethod -Uri $protectedItemUri -Method GET -Headers $headers
        
        if ($protectedItemResponse -and $protectedItemResponse.properties) {
            $isAlreadyProtected = $true
            Write-Host ""
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  DATABASE IS ALREADY PROTECTED!" -ForegroundColor Green
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Write-Host "Protected Item Details:" -ForegroundColor Cyan
            Write-Host "  Friendly Name:       $($protectedItemResponse.properties.friendlyName)" -ForegroundColor White
            Write-Host "  Protection Status:   $($protectedItemResponse.properties.protectionStatus)" -ForegroundColor White
            Write-Host "  Protection State:    $($protectedItemResponse.properties.protectionState)" -ForegroundColor White
            Write-Host "  Health Status:       $($protectedItemResponse.properties.healthStatus)" -ForegroundColor White
            Write-Host "  Last Backup Status:  $($protectedItemResponse.properties.lastBackupStatus)" -ForegroundColor White
            Write-Host "  Last Backup Time:    $($protectedItemResponse.properties.lastBackupTime)" -ForegroundColor White
            Write-Host "  Policy Name:         $($protectedItemResponse.properties.policyName)" -ForegroundColor White
            Write-Host "  Workload Type:       $($protectedItemResponse.properties.workloadType)" -ForegroundColor White
            Write-Host "  Server Name:         $($protectedItemResponse.properties.serverName)" -ForegroundColor White
            Write-Host "  Parent Name:         $($protectedItemResponse.properties.parentName)" -ForegroundColor White
            Write-Host ""
            Write-Host "No further action needed. The database is already protected." -ForegroundColor Yellow
            Write-Host ""
        }
    } catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Host "  Database is not currently protected - eligible for backup configuration" -ForegroundColor Green
        } else {
            Write-Host "  Could not determine protection status (HTTP $statusCode)" -ForegroundColor Yellow
            Write-Host "  Proceeding with protection setup..." -ForegroundColor Yellow
        }
    }
} elseif ($enableAutoProtection) {
    Write-Host "  Auto-protection mode: skipping individual DB protection check." -ForegroundColor Cyan
}

# ============================================================================
# STEP 7: LIST AVAILABLE BACKUP POLICIES
# ============================================================================

if (-not $isAlreadyProtected) {
    Write-Host ""
    Write-Host "STEP 7: Listing Available Backup Policies" -ForegroundColor Yellow
    Write-Host "--------------------------------------------" -ForegroundColor Yellow
    Write-Host ""
    
    $policiesUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies?api-version=$apiVersionProtection&`$filter=backupManagementType eq 'AzureWorkload'"
    
    $selectedPolicyId = $null
    $selectedPolicyName = $null
    
    # If PolicyName was provided via parameter, use it directly
    if (-not [string]::IsNullOrWhiteSpace($PolicyName)) {
        Write-Host "Using policy specified via -PolicyName parameter: $PolicyName" -ForegroundColor Cyan
        
        # Verify the policy exists
        $policyCheckUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$PolicyName`?api-version=$apiVersionProtection"
        
        try {
            $policyCheckResponse = Invoke-RestMethod -Uri $policyCheckUri -Method GET -Headers $headers
            $selectedPolicyId = $policyCheckResponse.id
            $selectedPolicyName = $policyCheckResponse.name
            Write-Host "  Policy verified: $selectedPolicyName" -ForegroundColor Green
            Write-Host "    Management Type: $($policyCheckResponse.properties.backupManagementType)" -ForegroundColor Gray
            Write-Host "    Workload Type:   $($policyCheckResponse.properties.workloadType)" -ForegroundColor Gray
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 404) {
                Write-Host "  ERROR: Policy '$PolicyName' not found in vault '$vaultName'." -ForegroundColor Red
                Write-Host "  Please check the policy name and try again." -ForegroundColor Yellow
                exit 1
            } else {
                Write-Host "  WARNING: Could not verify policy (HTTP $statusCode). Using provided name." -ForegroundColor Yellow
                $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$PolicyName"
                $selectedPolicyName = $PolicyName
            }
        }
    } else {
        # No PolicyName parameter - list policies and prompt for selection
        try {
            Write-Host "Querying for SQL backup policies (AzureWorkload)..." -ForegroundColor Cyan
            $policiesResponse = Invoke-RestMethod -Uri $policiesUri -Method GET -Headers $headers
            
            if ($policiesResponse.value -and $policiesResponse.value.Count -gt 0) {
                Write-Host "  Found $($policiesResponse.value.Count) AzureWorkload backup policy(ies):" -ForegroundColor Green
                Write-Host ""
                
                $policyIndex = 1
                foreach ($policy in $policiesResponse.value) {
                    Write-Host "  [$policyIndex] $($policy.name)" -ForegroundColor White
                    Write-Host "       Management Type: $($policy.properties.backupManagementType)" -ForegroundColor Gray
                    Write-Host "       Workload Type:   $($policy.properties.workloadType)" -ForegroundColor Gray
                    
                    if ($policy.properties.subProtectionPolicy) {
                        foreach ($subPolicy in $policy.properties.subProtectionPolicy) {
                            Write-Host "       Sub-Policy:      $($subPolicy.policyType) - Schedule: $($subPolicy.schedulePolicy.schedulePolicyType)" -ForegroundColor Gray
                        }
                    }
                    Write-Host "       ID: $($policy.id)" -ForegroundColor DarkGray
                    Write-Host ""
                    $policyIndex++
                }
                
                Write-Host "Select a backup policy (enter number, default: 1):" -ForegroundColor Cyan
                $policyChoice = Read-Host "  Policy selection"
                
                if ([string]::IsNullOrWhiteSpace($policyChoice)) {
                    $selectedPolicyId = $policiesResponse.value[0].id
                    $selectedPolicyName = $policiesResponse.value[0].name
                    Write-Host "  Using first available policy: $selectedPolicyName" -ForegroundColor Green
                } else {
                    $policyIdx = [int]$policyChoice - 1
                    if ($policyIdx -ge 0 -and $policyIdx -lt $policiesResponse.value.Count) {
                        $selectedPolicyId = $policiesResponse.value[$policyIdx].id
                        $selectedPolicyName = $policiesResponse.value[$policyIdx].name
                        Write-Host "  Selected policy: $selectedPolicyName" -ForegroundColor Green
                    } else {
                        Write-Host "  Invalid selection. Using first available policy." -ForegroundColor Yellow
                        $selectedPolicyId = $policiesResponse.value[0].id
                        $selectedPolicyName = $policiesResponse.value[0].name
                    }
                }
            } else {
                Write-Host "  WARNING: No AzureWorkload backup policies found in the vault." -ForegroundColor Yellow
                Write-Host "  You must create a SQL backup policy first in the Azure Portal." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  Alternatively, enter a policy name to construct the ID:" -ForegroundColor Yellow
                $manualPolicyName = Read-Host "  Enter Policy Name"
                if ([string]::IsNullOrWhiteSpace($manualPolicyName)) {
                    Write-Host "ERROR: A backup policy is required. Use -PolicyName parameter or create a policy first." -ForegroundColor Red
                    exit 1
                }
                $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$manualPolicyName"
                $selectedPolicyName = $manualPolicyName
                Write-Host "  Using policy ID: $selectedPolicyId" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  WARNING: Failed to list policies: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "  Enter a policy name manually:" -ForegroundColor Yellow
            $manualPolicyName = Read-Host "  Enter Policy Name"
            if ([string]::IsNullOrWhiteSpace($manualPolicyName)) {
                Write-Host "ERROR: A backup policy is required. Use -PolicyName parameter or create a policy first." -ForegroundColor Red
                exit 1
            }
            $selectedPolicyId = "/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupPolicies/$manualPolicyName"
            $selectedPolicyName = $manualPolicyName
        }
    }
    
    # ============================================================================
    # STEP 8A: ENABLE AUTO-PROTECTION (if selected)
    # ============================================================================
    
    if ($enableAutoProtection -and $matchingInstance) {
        Write-Host ""
        Write-Host "STEP 8: Enabling Auto-Protection on SQL Instance(s)" -ForegroundColor Yellow
        Write-Host "----------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        
        $instCount = $allInstancesToProtect.Count
        $instCurrent = 0
        $instSucceeded = 0
        $instFailed = 0
        
        foreach ($currentInstance in $allInstancesToProtect) {
            $instCurrent++
            
            Write-Host "Preparing auto-protection request ($instCurrent/$instCount)..." -ForegroundColor Cyan
            Write-Host "  Vault:              $vaultName" -ForegroundColor Gray
            Write-Host "  SQL Instance:       $($currentInstance.properties.friendlyName)" -ForegroundColor Gray
            Write-Host "  Server:             $($currentInstance.properties.serverName)" -ForegroundColor Gray
            Write-Host "  Policy:             $selectedPolicyName" -ForegroundColor Gray
            Write-Host ""
            
            # The intentObjectName for auto-protection must be a random GUID
            # (Azure CLI uses uuid4() for this - using the item name causes 400 errors)
            $intentObjectName = [guid]::NewGuid().ToString()
            
            $autoProtectUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/backupProtectionIntent/$intentObjectName`?api-version=$apiVersionProtection"
            
            # Get the protectable item ID of the SQL instance
            $instanceProtectableItemId = $currentInstance.id
            
            # The request body uses RecoveryServiceVaultItem type with only
            # backupManagementType, policyId, and itemId (matching Azure CLI behavior)
            $autoProtectBody = @{
                properties = @{
                    protectionIntentItemType = "RecoveryServiceVaultItem"
                    backupManagementType     = "AzureWorkload"
                    policyId                 = $selectedPolicyId
                    itemId                   = $instanceProtectableItemId
                }
            } | ConvertTo-Json -Depth 10
            
            Write-Host "Submitting auto-protection request..." -ForegroundColor Cyan
            
            try {
                $autoProtectResponse = Invoke-RestMethod -Uri $autoProtectUri -Method PUT -Headers $headers -Body $autoProtectBody
                
                $instSucceeded++
                Write-Host ""
                Write-Host "  AUTO-PROTECTION ENABLED for '$($currentInstance.properties.friendlyName)'" -ForegroundColor Green
                
                if ($autoProtectResponse.properties) {
                    Write-Host "    Protection Intent Type: $($autoProtectResponse.properties.protectionIntentItemType)" -ForegroundColor White
                    Write-Host "    Protection State:       $($autoProtectResponse.properties.protectionState)" -ForegroundColor White
                    Write-Host "    Policy ID:              $($autoProtectResponse.properties.policyId)" -ForegroundColor White
                    Write-Host "    Item ID:                $($autoProtectResponse.properties.itemId)" -ForegroundColor White
                }
                Write-Host ""
            } catch {
                $instFailed++
                $statusCode = $_.Exception.Response.StatusCode.value__
                
                Write-Host ""
                Write-Host "  FAILED to enable auto-protection for '$($currentInstance.properties.friendlyName)'" -ForegroundColor Red
                Write-ApiError -ErrorRecord $_ -Context "Auto-Protection ($($currentInstance.properties.friendlyName))"
                Write-Host ""
                
                # If only one instance, exit on failure; if multiple, continue with the rest
                if ($instCount -eq 1) {
                    Write-Host "Possible causes:" -ForegroundColor Yellow
                    Write-Host "  1. The SQL instance is not auto-protectable" -ForegroundColor White
                    Write-Host "  2. Insufficient permissions" -ForegroundColor White
                    Write-Host "  3. The policy doesn't support SQL workloads" -ForegroundColor White
                    Write-Host "  4. Another auto-protection intent already exists for this instance" -ForegroundColor White
                    Write-Host ""
                    exit 1
                }
            }
        }
        
        # Summary for multi-instance auto-protection
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "  AUTO-PROTECTION SUMMARY" -ForegroundColor Green
        Write-Host "==========================================================" -ForegroundColor Green
        Write-Host "  Total Instances:   $instCount" -ForegroundColor White
        Write-Host "  Succeeded:         $instSucceeded" -ForegroundColor Green
        if ($instFailed -gt 0) {
            Write-Host "  Failed:            $instFailed" -ForegroundColor Red
        } else {
            Write-Host "  Failed:            0" -ForegroundColor White
        }
        Write-Host ""
        
        if ($instFailed -gt 0 -and $instSucceeded -eq 0) {
            Write-Host "ERROR: All auto-protection attempts failed." -ForegroundColor Red
            exit 1
        }
    }
    
    # ============================================================================
    # STEP 8B: ENABLE INDIVIDUAL DATABASE PROTECTION (if not auto-protect)
    # ============================================================================
    
    if (-not $enableAutoProtection -and $matchingDB) {
        Write-Host ""
        Write-Host "STEP 8: Enabling Backup Protection for SQL Database" -ForegroundColor Yellow
        Write-Host "-----------------------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        
        Write-Host "Preparing protection request..." -ForegroundColor Cyan
        Write-Host "  Vault:              $vaultName" -ForegroundColor Gray
        Write-Host "  Virtual Machine:    $vmName" -ForegroundColor Gray
        Write-Host "  Database:           $dbName" -ForegroundColor Gray
        Write-Host "  Container Name:     $containerName" -ForegroundColor Gray
        Write-Host "  Protected Item:     $protectedItemName" -ForegroundColor Gray
        Write-Host "  Policy:             $selectedPolicyName" -ForegroundColor Gray
        Write-Host ""
        
        # Enable protection URI (PUT)
        $enableProtectionUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName`?api-version=$apiVersionProtection"
        
        $protectionBody = @{
            properties = @{
                backupManagementType = "AzureWorkload"
                workloadType         = "SQLDataBase"
                policyId             = $selectedPolicyId
            }
        } | ConvertTo-Json -Depth 10
        
        Write-Host "Submitting protection request..." -ForegroundColor Cyan
        
        try {
            $protectionResponse = Invoke-WebRequest -Uri $enableProtectionUri -Method PUT -Headers $headers -Body $protectionBody -UseBasicParsing
            $statusCode = $protectionResponse.StatusCode
            
            if ($statusCode -eq 200) {
                $responseBody = $protectionResponse.Content | ConvertFrom-Json
                Write-Host ""
                Write-Host "==========================================================" -ForegroundColor Green
                Write-Host "  SQL DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                Write-Host "==========================================================" -ForegroundColor Green
                Write-Host ""
                Write-Host "Protected Item Details:" -ForegroundColor Cyan
                Write-Host "  Friendly Name:       $($responseBody.properties.friendlyName)" -ForegroundColor White
                Write-Host "  Protection State:    $($responseBody.properties.protectionState)" -ForegroundColor White
                Write-Host "  Health Status:       $($responseBody.properties.healthStatus)" -ForegroundColor White
                Write-Host "  Workload Type:       $($responseBody.properties.workloadType)" -ForegroundColor White
                Write-Host "  Policy Name:         $($responseBody.properties.policyName)" -ForegroundColor White
                Write-Host ""
            } elseif ($statusCode -eq 202) {
                Write-Host "  Protection request accepted (202). Tracking..." -ForegroundColor Green
                
                $asyncUrl = $protectionResponse.Headers["Azure-AsyncOperation"]
                $locationUrl = $protectionResponse.Headers["Location"]
                $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                
                if ($trackingUrl) {
                    $maxRetries = 30
                    $retryCount = 0
                    $operationCompleted = $false
                    
                    while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                        Start-Sleep -Seconds 10
                        
                        try {
                            $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers
                            
                            $opStatus = $null
                            if ($opResponse.status) { $opStatus = $opResponse.status }
                            elseif ($opResponse.properties.protectionState) { $opStatus = $opResponse.properties.protectionState }
                            
                            if ($opStatus -eq "Succeeded" -or $opStatus -eq "Protected" -or $opStatus -eq "IRPending") {
                                $operationCompleted = $true
                                Write-Host ""
                                Write-Host "==========================================================" -ForegroundColor Green
                                Write-Host "  SQL DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                                Write-Host "==========================================================" -ForegroundColor Green
                                Write-Host ""
                                
                                if ($opResponse.properties) {
                                    Write-Host "Protected Item Details:" -ForegroundColor Cyan
                                    Write-Host "  Friendly Name:       $($opResponse.properties.friendlyName)" -ForegroundColor White
                                    Write-Host "  Protection State:    $($opResponse.properties.protectionState)" -ForegroundColor White
                                    Write-Host "  Health Status:       $($opResponse.properties.healthStatus)" -ForegroundColor White
                                    Write-Host "  Workload Type:       $($opResponse.properties.workloadType)" -ForegroundColor White
                                    Write-Host "  Policy Name:         $($opResponse.properties.policyName)" -ForegroundColor White
                                }
                                Write-Host ""
                            } else {
                                $retryCount++
                                Write-Host "  Waiting for protection... ($retryCount/$maxRetries) [Status: $opStatus]" -ForegroundColor Yellow
                            }
                        } catch {
                            $retryCount++
                            Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                        }
                    }
                    
                    if (-not $operationCompleted) {
                        Write-Host ""
                        Write-Host "  Protection operation is taking longer than expected." -ForegroundColor Yellow
                        Write-Host "  Please check the Azure Portal to verify status." -ForegroundColor Yellow
                        Write-Host ""
                    }
                } else {
                    Write-Host "  Protection in progress (no tracking URL). Check Azure Portal." -ForegroundColor Yellow
                }
            }
        } catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            
            if ($statusCode -eq 202) {
                Write-Host "  Protection request accepted (202)." -ForegroundColor Green
                
                try {
                    $asyncUrl = $_.Exception.Response.Headers["Azure-AsyncOperation"]
                    $locationUrl = $_.Exception.Response.Headers["Location"]
                    $trackingUrl = if ($asyncUrl) { $asyncUrl } else { $locationUrl }
                    
                    if ($trackingUrl) {
                        $maxRetries = 30
                        $retryCount = 0
                        $operationCompleted = $false
                        
                        while (-not $operationCompleted -and $retryCount -lt $maxRetries) {
                            Start-Sleep -Seconds 10
                            
                            try {
                                $opResponse = Invoke-RestMethod -Uri $trackingUrl -Method GET -Headers $headers
                                
                                $opStatus = $null
                                if ($opResponse.status) { $opStatus = $opResponse.status }
                                elseif ($opResponse.properties.protectionState) { $opStatus = $opResponse.properties.protectionState }
                                
                                if ($opStatus -eq "Succeeded" -or $opStatus -eq "Protected" -or $opStatus -eq "IRPending") {
                                    $operationCompleted = $true
                                    Write-Host ""
                                    Write-Host "==========================================================" -ForegroundColor Green
                                    Write-Host "  SQL DATABASE PROTECTION ENABLED SUCCESSFULLY!" -ForegroundColor Green
                                    Write-Host "==========================================================" -ForegroundColor Green
                                    Write-Host ""
                                } else {
                                    $retryCount++
                                    Write-Host "  Waiting... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                                }
                            } catch {
                                $retryCount++
                                Write-Host "  Polling... ($retryCount/$maxRetries)" -ForegroundColor Yellow
                            }
                        }
                    } else {
                        Write-Host "  Protection submitted. Check Azure Portal for status." -ForegroundColor Yellow
                    }
                } catch {
                    Write-Host "  Protection submitted. Check Azure Portal." -ForegroundColor Yellow
                }
            } else {
                Write-Host ""
                Write-Host "ERROR: Failed to enable SQL database protection." -ForegroundColor Red
                Write-ApiError -ErrorRecord $_ -Context "Enable Protection"
                Write-Host ""
                Write-Host "Possible causes:" -ForegroundColor Yellow
                Write-Host "  1. Database is already protected by another vault" -ForegroundColor White
                Write-Host "  2. Insufficient permissions on the VM or vault" -ForegroundColor White
                Write-Host "  3. The backup policy is invalid or doesn't support SQL workloads" -ForegroundColor White
                Write-Host "  4. SQL IaaS Agent extension is not installed or not responding" -ForegroundColor White
                Write-Host "  5. VM is deallocated" -ForegroundColor White
                Write-Host ""
                exit 1
            }
        }
        
        # ============================================================================
        # POST-PROTECTION: VERIFY AND DISPLAY SUMMARY
        # ============================================================================
        
        Write-Host ""
        Write-Host "VERIFICATION: Confirming Protection" -ForegroundColor Yellow
        Write-Host "-------------------------------------" -ForegroundColor Yellow
        Write-Host ""
        
        Start-Sleep -Seconds 5
        
        try {
            Write-Host "Verifying protected item status..." -ForegroundColor Cyan
            $verifyResponse = Invoke-RestMethod -Uri $enableProtectionUri -Method GET -Headers $headers
            
            if ($verifyResponse -and $verifyResponse.properties) {
                Write-Host ""
                Write-Host "SQL Database Protection Summary:" -ForegroundColor Cyan
                Write-Host "  Database Name:       $($verifyResponse.properties.friendlyName)" -ForegroundColor White
                Write-Host "  Server Name:         $($verifyResponse.properties.serverName)" -ForegroundColor White
                Write-Host "  Parent Instance:     $($verifyResponse.properties.parentName)" -ForegroundColor White
                Write-Host "  Protection Status:   $($verifyResponse.properties.protectionStatus)" -ForegroundColor White
                Write-Host "  Protection State:    $($verifyResponse.properties.protectionState)" -ForegroundColor White
                Write-Host "  Health Status:       $($verifyResponse.properties.healthStatus)" -ForegroundColor White
                Write-Host "  Last Backup Status:  $($verifyResponse.properties.lastBackupStatus)" -ForegroundColor White
                Write-Host "  Last Backup Time:    $($verifyResponse.properties.lastBackupTime)" -ForegroundColor White
                Write-Host "  Policy Name:         $($verifyResponse.properties.policyName)" -ForegroundColor White
                Write-Host "  Workload Type:       $($verifyResponse.properties.workloadType)" -ForegroundColor White
                Write-Host "  Container Name:      $($verifyResponse.properties.containerName)" -ForegroundColor White
                Write-Host ""
            }
        } catch {
            Write-Host "  Could not verify protection immediately." -ForegroundColor Yellow
            Write-Host "  Protection may still be initializing. Check the Azure Portal." -ForegroundColor Yellow
            Write-Host ""
        }
    }
    
    # ============================================================================
    # NEXT STEPS
    # ============================================================================
    
    Write-Host ""
    Write-Host "Next Steps:" -ForegroundColor Yellow
    if ($enableAutoProtection) {
        Write-Host "  1. All databases under the SQL instance will be automatically protected" -ForegroundColor White
        Write-Host "  2. New databases added to the instance will be auto-discovered and protected" -ForegroundColor White
        Write-Host "  3. Backups will run according to the selected policy schedule" -ForegroundColor White
        Write-Host "  4. To trigger an on-demand backup, use the Azure Portal or REST API" -ForegroundColor White
        Write-Host "  5. Monitor backup jobs: Azure Portal > Recovery Services Vault > Backup Jobs" -ForegroundColor White
    } else {
        Write-Host "  1. The first backup will trigger according to the policy schedule" -ForegroundColor White
        Write-Host "  2. To trigger an on-demand backup, use the Azure Portal or REST API" -ForegroundColor White
        Write-Host "  3. Monitor backup jobs: Azure Portal > Recovery Services Vault > Backup Jobs" -ForegroundColor White
        Write-Host "  4. To protect additional databases, run this script again" -ForegroundColor White
        Write-Host "  5. Consider enabling auto-protection for the SQL instance to cover future DBs" -ForegroundColor White
    }
    Write-Host ""
}

Write-Host ""
Write-Host "Script completed." -ForegroundColor Cyan
Write-Host ""

exit 0

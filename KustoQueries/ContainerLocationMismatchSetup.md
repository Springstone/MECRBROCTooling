# Container Location Mismatch Detection - Kusto Setup Guide

**Cluster:** `mabprod1.kusto.windows.net`  
**Database:** `MABKustoProd1`

---

## Step 1: Create the Deployment Stamp Mapping Table

This reference table maps deployment names to their expected stamp locations.

```kusto
.create table DeploymentStampMapping (
    DeploymentName: string,
    DeploymentStampLocation: string
)
```

## Step 2: Seed the Mapping Data

```kusto
.ingest inline into table DeploymentStampMapping <|
ne-pod01,northeurope
uks-pod01,uksouth
we-pod01,westeurope
sdc-pod01,SwedenCentral
gwc-pod01,GermanyWestCentral
szn-pod01,SwitzerlandNorth
ukw-pod01,ukwest
nwe-pod01,NorwayEast
gn-pod01,GermanyNorth
szw-pod01,SwitzerlandWest
plc-pod01,PolandCentral
frc-pod01,FranceCentral
nww-pod01,NorwayWest
sds-pod01,SwedenSouth
eus-pod01,eastus
eus2-pod01,eastus2
cus-pod01,centralus
wus-pod01,westus
wus2-pod01,westus2
brs-pod01,brazilsouth
scus-pod01,southcentralus
ncus-pod01,northcentralus
wus3-pod01,WestUS3
wcus-pod01,westcentralus
bse-pod01,BrazilSoutheast
sea-pod01,southeastasia
ins-pod01,SouthIndia
jpe-pod01,japaneast
ae-pod01,australiaeast
aue-pod01,AustriaEast
uan-pod01,UAENorth
cnc-pod01,CanadaCentral
san-pod01,SouthAfricaNorth
inc-pod01,CentralIndia
ase-pod01,australiasoutheast
krs-pod01,KoreaSouth
itn-pod01,ItalyNorth
cne-pod01,CanadaEast
bec-pod01,BelgiumCentral
acl-pod01,AustraliaCentral
idc-pod01,IndonesiaCentral
krc-pod01,KoreaCentral
jpw-pod01,japanwest
qac-pod01,QatarCentral
spc-pod01,SpainCentral
mxc-pod01,MexicoCentral
ea-pod01,eastasia
uac-pod01,UAECentral
ilc-pod01,IsraelCentral
mys-pod01,MalaysiaSouth
iln-pod01,IsraelNorthwest
jic-pod01,JioIndiaCentral
saw-pod01,SouthAfricaWest
jiw-pod01,JioIndiaWest
inw-pod01,WestIndia
use-pod01,SoutheastUS
acl2-pod01,AustraliaCentral2
usc2-pod01,SouthCentralUS2
use3-pod01,SoutheastUS3
nzn-pod01,NewZealandNorth
tnw-pod01,TaiwanNorthwest
myw-pod01,MalaysiaWest
twn-pod01,TaiwanNorth
clc-pod01,ChileCentral
eus3-pod01,EastUS3
```

> **To add a new deployment later:**
> ```kusto
> .ingest inline into table DeploymentStampMapping <|
> newregion-pod01,NewRegionName
> ```

---

## Step 3: Create the Stored Function

This function queries `TraceLogMessageAll`, parses container locations, joins with the mapping table, and returns rows where the container location doesn't match the expected deployment stamp location.

```kusto
.create-or-alter function with (folder="Monitoring", docstring="Finds containers deployed to mismatched locations")
GetContainerLocationMismatches() {
    TraceLogMessageAll
    | where TIMESTAMP > ago(30d)
    | where DeploymentName !in ("ea-can02", "ecy-pod01", "ccy-pod01")
    | where ServiceName == "fabrics"
    | where Role == "FabricServiceTeeWorkerRole"
    | where FileNameLineNumber contains "InstallExtensionTask"
    | where Message contains "InstallExtensionTask" and Message contains "TrackingUri "
    | parse Message with * "{ContainerName = " ContainerName:string "}" * "locations/" ContainerLocation:string "/operations" *
    | summarize by DeploymentName, ContainerLocation, ContainerName
    | where ContainerLocation != "EastUS2EUAP"
    | join kind=leftouter DeploymentStampMapping on DeploymentName
    | project DeploymentName, DeploymentStampLocation, ContainerLocation, ContainerName
    | where tolower(DeploymentStampLocation) != tolower(ContainerLocation)
}
```

### Verify the function works

```kusto
GetContainerLocationMismatches()
| take 20
```

---

## Step 4: Create the Results Table

This table stores the mismatch records over time.

```kusto
.create table ContainerLocationMismatch (
    DeploymentName: string,
    DeploymentStampLocation: string,
    ContainerLocation: string,
    ContainerName: string,
    IngestionTimestamp: datetime
)
```

---

## Step 5: First-Time Ingestion

For the initial load (table is empty, no dedup needed):

```kusto
.set-or-append ContainerLocationMismatch <|
    GetContainerLocationMismatches()
    | extend IngestionTimestamp = now()
```

---

## Step 6: Subsequent Runs (Compare & Ingest New Rows Only)

Run this periodically to ingest only **new** mismatches that don't already exist in the table:

```kusto
.append ContainerLocationMismatch <|
    GetContainerLocationMismatches()
    | join kind=anti ContainerLocationMismatch on DeploymentName, ContainerLocation, ContainerName
    | extend IngestionTimestamp = now()
```

> **How it works:** The `join kind=anti` compares on 3 keys (`DeploymentName`, `ContainerLocation`, `ContainerName`) and only returns rows that are **not already present** in the table — preventing duplicates.

---

## Step 7: Verify Ingested Data

```kusto
ContainerLocationMismatch
| order by IngestionTimestamp desc
```

---

## Optional: Set Retention Policy

```kusto
.alter table ContainerLocationMismatch policy retention
```
```json
{
    "SoftDeletePeriod": "365.00:00:00",
    "Recoverability": "Enabled"
}
```

---

## Scheduling Options

To run Step 6 periodically:

| Method | How |
|---|---|
| **Azure Logic App** | Timer trigger → "Run KQL query" action with the `.append` command |
| **Azure Data Factory** | Pipeline with a scheduled trigger → Azure Data Explorer command activity |
| **Power Automate** | Recurrence trigger → Kusto connector |

---

## Summary

| Object | Type | Purpose |
|---|---|---|
| `DeploymentStampMapping` | Table | Reference mapping of deployment names to locations |
| `GetContainerLocationMismatches` | Function | Detects containers in wrong locations |
| `ContainerLocationMismatch` | Table | Stores mismatch records over time |

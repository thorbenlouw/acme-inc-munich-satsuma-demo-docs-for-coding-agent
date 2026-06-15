# Azure Data Factory: Billing to Assets Mapping DataFlow

**Satsuma Mapping:** `billing to assets`  
**Source Schemas:** `billing_api_customer`, `atlas_kunden` (via KD-REF crosswalk)  
**Target Schema:** `sf_asset`  
**Compliance:** GDPR (PII fields encrypted), EUR-currency validation

---

## Overview

This is an Azure Data Factory (ADF) Mapping DataFlow implementation of the Satsuma mapping:

```satsuma
mapping `billing to assets` {
  source {
    billing_api_customer
    atlas_kunden
    "Match @billing_api_customer.customer_ref to @atlas_kunden.KD_NR via the
     KD-REF crosswalk table; ~0.4% of refs are orphans — route to remediation."
  }
  target { sf_asset }

  each subscriptions -> sf_asset {
    .contract_no  -> SerialNumber
    .product_code -> Product_Code__c
    .mrr_eur      -> MRR__c
    -> Status { "If @.cancelled_on is null then Active else Cancelled" }
  }
}
```

---

## Architecture

```
┌─────────────────────┐
│ BillingApiCustomer  │ (JSON, REST API)
│ subscriptions[]     │
└──────────┬──────────┘
           │
           ├─────────────────────────┐
           │                         │
      ┌────▼─────────────────┐   ┌──▼──────────────┐
      │ ExpandSubscriptions   │   │ KdRefCrosswalk  │
      │ (flt/flatten)         │   │ (CSV)           │
      └────┬─────────────────┘   └──┬───────────────┘
           │                         │
           └────────────┬────────────┘
                        │
                   ┌────▼─────────────┐
                   │ JoinKdRef         │ (LEFT join on customer_ref)
                   │ (orphan split)    │
                   └────┬──────────────┘
                        │
        ┌───────────────┬┴──────────────┐
        │               │               │
   ┌────▼───┐      ┌────▼──────────────┐
   │ Orphans │      │ Valid Matches     │
   │ (0.4%)  │      │                   │
   └────┬───┘      └────┬───────────────┘
        │               │
        │          ┌────▼─────────────────────┐
        │          │ DeriveStatus              │
        │          │ (IF cancelled_on IS NULL) │
        │          └────┬─────────────────────┘
        │               │
        │          ┌────▼─────────────────────┐
        │          │ DerivedFieldMappings      │
        │          │ (Name, PurchaseDate, etc) │
        │          └────┬─────────────────────┘
        │               │
        │          ┌────▼──────────────┐
        │          │ FilterValidAssets │
        │          └────┬───────────────┘
        │               │
        │          ┌────▼──────────────┐
        │          │ SelectAndMap      │
        │          └────┬───────────────┘
        │               │
        │          ┌────▼──────────────┐
        │          │ SfAssetSink       │ (Salesforce)
        │          └───────────────────┘
        │
        └──────────────────────────┐
                                   │
                          ┌────────▼──────┐
                          │ OrphanQueue    │ (Parquet, remediation)
                          └────────────────┘
```

---

## Key Transformations

### 1. **ExpandSubscriptions** (flt — flatten)
Converts the nested `subscriptions` array into individual rows:

```
Input:  { customer_ref: "KD-100247", subscriptions: [{contract_no: "SUB-1", ...}, {contract_no: "SUB-2", ...}] }
Output: Row 1: { customer_ref: "KD-100247", contract_no: "SUB-1", ... }
        Row 2: { customer_ref: "KD-100247", contract_no: "SUB-2", ... }
```

### 2. **JoinKdRef** (LEFT join)
Matches billing customer_ref to ATLAS KD_NR via the KD-REF crosswalk:

```
billing.customer_ref = "KD-100247"
  ↓ lookup in KD-REF
atlas.KD_NR = 100247
  ↓ join output includes kd_nr field
  ✓ Match found
```

If no match:
```
billing.customer_ref = "KD-999999"
  ↓ lookup in KD-REF
✗ No match (orphan)
  ↓ kd_nr = null
  → split: route to remediation queue
```

### 3. **DeriveStatusFromCancelledDate**
Conditional Status field:

```
IF cancelled_on IS NULL THEN Status = 'Active' ELSE Status = 'Cancelled'
```

Maps to Satsuma transform: `"If @.cancelled_on is null then Active else Cancelled"`

### 4. **DerivedFieldMappings**
Compute additional Salesforce fields:

| Source Field | Derived Field | Logic |
|---|---|---|
| contract_no | SerialNumber | Direct map (PK) |
| product_code | Product_Code__c | Direct map |
| mrr_eur | MRR__c | Direct map; EUR-only validation required |
| started_on | PurchaseDate | Direct map |
| cancelled_on | UsageEndDate | Direct map; null while active |
| product_code + contract_no | Name | Concat: `'PROD-E001-SUB-2020-001'` |
| — | Quantity | Hardcoded: 1.0 (one subscription = one asset) |
| — | Price | Copied from mrr_eur |

### 5. **FilterValidAssets**
Remove rows with null required fields (SerialNumber, Product_Code__c):

```
filter(!isNull(SerialNumber) && !isNull(product_code))
```

### 6. **IdentifyOrphans** (conditional split)
Route rows based on KD_NR presence:

```
split(!isNull(AccountKdNr), disjoint: false)
  → true:  Send to SfAssetSink
  → false: Send to OrphanQueue (remediation)
```

---

## Deployment

### Prerequisites

- Azure Data Factory instance
- Linked Services configured:
  - **BillingPlatformRestAPI**: OAuth2 to billing platform
  - **AzureBlobStorageLinkedService**: Connection string for crosswalks + remediation queue
  - **SalesforceLinkedService**: SF API + security token
- Datasets created from `datasets.json`
- Integration Runtime with network access to all sources

### Steps

1. **Create Linked Services:**
   ```bash
   az datafactory linked-service create \
     --name "BillingPlatformRestAPI" \
     --factory-name "<adf-name>" \
     --properties "@linkedServices[0]"
   ```

2. **Create Datasets:**
   ```bash
   az datafactory dataset create \
     --name "BillingApiCustomer_JSON" \
     --factory-name "<adf-name>" \
     --properties "@datasets[0]"
   # ... repeat for other datasets
   ```

3. **Create Mapping DataFlow:**
   ```bash
   az datafactory data-flow create \
     --name "BillingToAssets" \
     --factory-name "<adf-name>" \
     --properties "@BillingToAssets_MappingDataFlow.json"
   ```

4. **Create Pipeline** (orchestrator):
   See `pipeline-orchestrator.json` for a sample pipeline that calls this DataFlow with error handling.

5. **Trigger:**
   - Manual (ad-hoc): `az datafactory pipeline create-run`
   - Scheduled: Configure trigger in ADF UI (daily, hourly, etc.)
   - Event-driven: Blob storage event when new billing export arrives

---

## Monitoring & Alerting

### Key Metrics

| Metric | Target | Action if Exceeded |
|--------|--------|-------------------|
| Orphan Rate | < 0.5% (tolerance: 0.4%) | Alert: Data Quality issue; investigate KD-REF crosswalk |
| Processing Time | < 5 min (250–1000 billing records) | Alert: Scaling or performance issue |
| Failed Records | = 0 (no unhandled errors) | Alert: Schema change or upstream data issue |
| EUR Currency Validation | 100% of MRR__c in EUR | Warn: Non-EUR found; manual review |

### Azure Monitor Setup

```json
{
  "metricAlerts": [
    {
      "name": "BillingToAssets_OrphanRateHigh",
      "condition": "orphan_records / total_records > 0.005",
      "severity": 2,
      "actions": ["email-dpo@acme.example", "slack-#data-quality"]
    },
    {
      "name": "BillingToAssets_ProcessingTimeHigh",
      "condition": "duration_ms > 300000",
      "severity": 3,
      "actions": ["slack-#data-ops"]
    },
    {
      "name": "BillingToAssets_NonEurCurrencyDetected",
      "condition": "count_records_where(currency != 'EUR') > 0",
      "severity": 2,
      "actions": ["email-dpo@acme.example"]
    }
  ]
}
```

### Logging

All runs logged to Azure Monitor / Application Insights. Query examples:

```kusto
// Daily run summary
AdfActivityRun
| where PipelineName == "BillingToAssets"
| where RunStart >= ago(1d)
| summarize
    TotalRuns = count(),
    SuccessfulRuns = countif(Status == "Succeeded"),
    FailedRuns = countif(Status == "Failed"),
    TotalRecords = sum(todouble(Output.sourceRecords)),
    TotalSink = sum(todouble(Output.sinkRecords))
| project
    TotalRuns,
    SuccessRate = (SuccessfulRuns * 100 / TotalRuns),
    FailedRuns,
    RecordsProcessed = TotalRecords,
    RecordsSunk = TotalSink

// Orphan rate
AdfActivityRun
| where PipelineName == "BillingToAssets"
| where Status == "Succeeded"
| extend OrphanCount = todouble(Output.sinkRecords[2])  // OrphanQueue is 3rd sink
| summarize
    TotalOrphans = sum(OrphanCount),
    TotalRecords = sum(todouble(Output.sourceRecords))
| project OrphanRate = (TotalOrphans * 100 / TotalRecords)
```

---

## Compliance & PII Handling

### GDPR

- **MRR__c (EUR currency):** EUR is the only supported currency. If non-EUR found, flag for manual review (regulatory risk if org currency differs).
- **Custom Fields:** Product_Code__c and MRR__c must be marked as custom in Salesforce SF security model.
- **Audit Trail:** ADF activity run logs are retained for 90 days; integrate with SIEM for long-term retention.

### Validation & Error Handling

1. **Missing Required Fields:**
   - If SerialNumber or Product_Code__c is null → filtered out, logged
   - Manual review recommended before re-import

2. **Orphan Handling:**
   - Orphaned records written to Parquet (immutable, versioned)
   - SLA: Resolve within 5 business days
   - Escalate if > 10 orphans/day

3. **Data Type Mismatches:**
   - mrr_eur must be DECIMAL(10,2)
   - If conversion fails → record routed to remediation queue

---

## Testing

### Test Case: Nested Subscription Cardinality

**Setup:** 3 billing records with varying subscription counts:
- Record A: 2 subscriptions
- Record B: 1 subscription
- Record C: 0 subscriptions

**Expected:** sf_asset output = 3 rows (2 + 1 + 0)

```bash
# Sample test data
echo 'customer_ref,payment_status,subscriptions' > test_input.json
echo 'KD-100247,ok,"[{\"contract_no\":\"SUB-1\",\"product_code\":\"PROD-E001\",\"mrr_eur\":149.99,\"started_on\":\"2020-03-15\",\"cancelled_on\":null},{\"contract_no\":\"SUB-2\",\"product_code\":\"PROD-P003\",\"mrr_eur\":79.50,\"started_on\":\"2022-09-01\",\"cancelled_on\":\"2025-01-31\"}]"' >> test_input.json

# Run DataFlow (debug mode)
az datafactory pipeline create-run \
  --factory-name "<adf-name>" \
  --pipeline-name "BillingToAssets_Debug" \
  --parameters '{"sourceDatasetPath": "test_input.json"}'

# Verify output
az datafactory activity-run query \
  --factory-name "<adf-name>" \
  --pipeline-run-id "<run-id>"
```

### Test Case: Orphan Routing

**Setup:** Insert billing record with customer_ref not in KD-REF:
- customer_ref: "KD-999999" (orphan)

**Expected:** Record appears in OrphanQueue, not SfAssetSink

```bash
# Check remediation queue
az storage blob download \
  --account-name "<storage-account>" \
  --container-name "data-factory" \
  --name "remediation-queues/billing-to-assets/orphan_remediation_*.parquet"
```

---

## Satsuma Mapping Reference

**Satsuma File:** `acme_vorbild.stm` (lines 104–119)

```satsuma
mapping `billing to assets` {
  source {
    billing_api_customer
    atlas_kunden
    "Match @billing_api_customer.customer_ref to @atlas_kunden.KD_NR via the
     KD-REF crosswalk table; ~0.4% of refs are orphans — route to remediation."
  }
  target { sf_asset }

  each subscriptions -> sf_asset {
    .contract_no  -> SerialNumber
    .product_code -> Product_Code__c
    .mrr_eur      -> MRR__c (note "EUR only; billing platform is single-currency")
    -> Status { "If @.cancelled_on is null then Active else Cancelled" }
  }
}
```

### Mapping to ADF Transformations

| Satsuma | ADF Transformation | Detail |
|---------|-------------------|--------|
| `billing_api_customer` source | BillingApiSource | REST API JSON dataset |
| `atlas_kunden` + KD-REF crosswalk | JoinKdRef | LEFT join on customer_ref |
| `each subscriptions` | ExpandSubscriptions | Flatten array into rows |
| `.contract_no -> SerialNumber` | SelectAndMap | Direct column rename |
| `.product_code -> Product_Code__c` | SelectAndMap | Direct column rename |
| `.mrr_eur -> MRR__c` | DerivedFieldMappings | EUR validation required |
| `-> Status { "If @.cancelled_on is null..." }` | DeriveStatusFromCancelledDate | Conditional derivation |
| `~0.4% orphans -> remediation` | IdentifyOrphans + OrphanQueue | Conditional split |

---

## Known Limitations & Future Work

1. **No SalesforceObject custom-field validation:** ADF does not automatically verify that Product_Code__c and MRR__c exist on the Asset object. Manual SF configuration required.

2. **Product2Id lookup not implemented:** The mapping notes "Lookup to Product2; resolve via Product_Code__c crosswalk." This is a separate lookup transformation; consider adding a cache-based lookup or bulk API call.

3. **AccountId/ContactId resolution:** The mapping requires linking subscriptions to the correct parent (sf_account or sf_contact). This is deferred to a future phase (see Satsuma `//?` on line 90: "Account mapping (VKZ = 'F') not in this file yet").

4. **Incremental processing:** This implementation does full load (all billing records). For incremental/CDC, add a timestamp filter on `ANGELEGT_AM` or billing sync timestamp.

---

## Support & Escalation

- **Data Quality Issues:** DPO (@dpo@acme.example)
- **ADF Infrastructure:** Data Platform team (#data-ops in Slack)
- **Salesforce Schema Changes:** CRM team (@crm-platform)
- **Billing API Outages:** Billing Platform team (@billing-platform)

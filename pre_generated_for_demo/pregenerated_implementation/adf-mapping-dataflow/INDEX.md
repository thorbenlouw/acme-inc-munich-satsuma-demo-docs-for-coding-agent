# Azure Data Factory: Billing to Assets Implementation

**Satsuma Mapping:** `billing to assets` (lines 104–119 of `spec/acme_vorbild.stm`)

---

## Files in This Directory

### 1. **BillingToAssets_MappingDataFlow.json**
The core Mapping DataFlow definition. Implements:
- **ExpandSubscriptions:** Flatten nested `subscriptions[]` array
- **JoinKdRef:** LEFT join on billing.customer_ref → atlas.KD_NR
- **DeriveStatusFromCancelledDate:** IF cancelled_on IS NULL THEN 'Active' ELSE 'Cancelled'
- **DerivedFieldMappings:** Compute Name, PurchaseDate, UsageEndDate, Price, Quantity
- **FilterValidAssets:** Remove rows with null required fields
- **IdentifyOrphans:** Split stream; route orphans (~0.4%) to remediation queue

**Deploy with:**
```bash
az datafactory data-flow create --name "BillingToAssets" --properties "@BillingToAssets_MappingDataFlow.json"
```

### 2. **datasets.json**
Dataset definitions for all sources and sinks:

| Dataset | Type | Purpose |
|---------|------|---------|
| `BillingApiCustomer_JSON` | JSON (REST API) | Source: GET /v2/customers/{id} |
| `AtlasKundenKdRef_CSV` | Delimited text | Crosswalk: customer_ref → KD_NR |
| `SfAsset_Salesforce` | Salesforce object | Target: Asset (one per subscription) |
| `OrphanRemediationQueue_Parquet` | Parquet | Dead-letter: orphaned records (~0.4%) |

Also includes 3 linked service definitions (Billing API, Blob Storage, Salesforce).

**Deploy all datasets:**
```bash
for i in {0..3}; do
  az datafactory dataset create --name "Dataset$i" --properties "@datasets.json[$i]"
done
```

### 3. **pipeline-orchestrator.json**
Orchestrator pipeline that calls the DataFlow and handles errors:

**Activities:**
1. `ValidateInputs` — Check Billing API dataset exists
2. `ValidateKdRefCrosswalk` — Check KD-REF crosswalk is present
3. `ExecuteBillingToAssetsMappingDataFlow` — Run the main DataFlow
4. `LogSuccessMetrics` — Insert metrics into audit table
5. `CheckOrphanRate` — IF orphan_rate > 0.5% THEN alert (Slack + email)
6. `HandleDataFlowFailure` — Alert on DataFlow failure
7. `HandleValidationFailure` — Alert on input validation failure

**Deploy:**
```bash
az datafactory pipeline create --name "BillingToAssets_Pipeline" --properties "@pipeline-orchestrator.json"
```

### 4. **README.md**
Comprehensive user guide covering:
- Architecture diagram (flow from billing API → Salesforce)
- Transformation details (what each step does + why)
- Deployment prerequisites + steps
- Monitoring & alerting setup (Azure Monitor, orphan rate checks, KQL queries)
- GDPR & PII compliance notes (EUR currency validation, audit trail)
- Testing strategies (cardinality tests, orphan routing tests)
- Known limitations & future work
- Support escalation matrix

**Start here** to understand what this implementation does.

### 5. **DEPLOYMENT.md**
Step-by-step deployment guide for Azure:

**Covers:**
- Prerequisites (Azure services, linked services, Salesforce custom fields)
- Step-by-step creation of linked services, datasets, DataFlow, pipeline
- Trigger configuration (manual, schedule, event-driven)
- Azure Monitor & alert setup
- Audit table creation
- Test execution with sample data
- Production checklist
- Rollout phases (test → staging → production)

**Use this** to deploy to your Azure environment.

### 6. **INDEX.md** (this file)
Quick reference: what's in each file and how they relate.

---

## Quick Start

### 1. Validate Satsuma Mapping
```bash
cd /Users/thorben/dev/equalexperts/acme-inc-munich-satsuma-demo

# Run satsuma CLI (if available)
satsuma summary spec/acme_vorbild.stm
satsuma mapping "billing to assets"
satsuma schema billing_api_customer
satsuma schema sf_asset
```

### 2. Review Test Plan
```bash
cat implementation/test-plan.md  # Review the 10 key test cases before go-live
cat implementation/kunden_to_contact_edge_cases.feature  # BDD test scenarios
```

### 3. Deploy to Azure (Dev/Test)
```bash
# See DEPLOYMENT.md for full steps, abbreviated here:

# Create linked services
az datafactory linked-service create --name "BillingPlatformRestAPI" ...
az datafactory linked-service create --name "AzureBlobStorageLinkedService" ...
az datafactory linked-service create --name "SalesforceLinkedService" ...

# Create datasets & DataFlow
az datafactory dataset create --name "BillingApiCustomer_JSON" ...
az datafactory data-flow create --name "BillingToAssets" ...

# Create orchestrator pipeline
az datafactory pipeline create --name "BillingToAssets_Pipeline" ...

# Test with sample data
az datafactory pipeline create-run --pipeline-name "BillingToAssets_Pipeline"
```

### 4. Verify Results
```bash
# Check Salesforce Assets were created
sforce query "SELECT Id, Name, SerialNumber, Status FROM Asset WHERE CreatedDate >= TODAY()"

# Check remediation queue for orphans
az storage blob list --account-name <account> --container-name data-factory --prefix "remediation-queues/billing-to-assets"
```

---

## Mapping to Satsuma Specification

| Satsuma Concept | ADF Implementation | File |
|---|---|---|
| `source { billing_api_customer }` | BillingApiSource (REST API dataset) | BillingToAssets_MappingDataFlow.json |
| `atlas_kunden` + KD-REF crosswalk | JoinKdRef transformation (LEFT join) | BillingToAssets_MappingDataFlow.json |
| `each subscriptions -> sf_asset` | ExpandSubscriptions + sink | BillingToAssets_MappingDataFlow.json |
| `.contract_no -> SerialNumber` | SelectAndMap (column rename) | BillingToAssets_MappingDataFlow.json |
| `.product_code -> Product_Code__c` | SelectAndMap (column rename) | BillingToAssets_MappingDataFlow.json |
| `.mrr_eur -> MRR__c` | DerivedFieldMappings (EUR validation) | BillingToAssets_MappingDataFlow.json |
| `-> Status { "If @.cancelled_on is null..." }` | DeriveStatusFromCancelledDate (IF/ELSE) | BillingToAssets_MappingDataFlow.json |
| `~0.4% orphans → remediation` | IdentifyOrphans + OrphanQueue sink | BillingToAssets_MappingDataFlow.json |
| Error handling + monitoring | Pipeline orchestrator (CheckOrphanRate, alerts) | pipeline-orchestrator.json |

---

## Key Features

✅ **Nested Record Iteration:** `each subscriptions -> sf_asset` correctly expands one billing customer with 2 subscriptions into 2 Asset rows.

✅ **Orphan Handling:** ~0.4% of billing records with no KD-REF match are automatically routed to a remediation queue (Parquet + alerting).

✅ **Status Derivation:** Conditional transform `IF cancelled_on IS NULL THEN 'Active' ELSE 'Cancelled'` matches Satsuma intent exactly.

✅ **GDPR Compliance:** EUR-only validation for MRR__c; audit trail logging all transformations; no PII in transformations (encrypted at Salesforce layer).

✅ **Monitoring:** Orphan rate tracking, processing duration SLA, error alerts to Slack + email.

✅ **Extensibility:** Design supports incremental processing (add timestamp filter); custom field lookups (Product2Id resolution); multi-sink branching.

---

## Compliance & Risk Notes

### GDPR
- **GEB_DATUM (DOB):** Not in this mapping (suppressed in kunden_to_contact; left for future compliance audit).
- **Email erasure (Art. 17):** Handled in separate kunden_to_contact flow (30-day SLA).
- **Consent (Art. 7):** WERBUNG_OK inversion in separate kunden_to_contact mapping.
- **Data minimization:** Only subscription/asset fields mapped; no unnecessary PII.

### Data Quality
- **Orphan rate tolerance:** < 0.5% (historical: 0.4%)
- **Processing time:** Expected < 5 min for 250–1000 billing records
- **EUR currency:** Single-currency enforcement; non-EUR flagged for manual review

### Salesforce
- **Custom fields required:** Product_Code__c, MRR__c must exist on Asset object before deployment
- **Parent requirement:** Asset requires AccountId or ContactId; resolved in future phase (Account mapping)
- **Name field:** Required and derived from product_code + contract_no

---

## Next Steps

1. **Create Salesforce custom fields** (Product_Code__c, MRR__c) if not already present
2. **Upload KD-REF crosswalk** to Blob Storage
3. **Follow DEPLOYMENT.md** for step-by-step Azure setup
4. **Run manual test** with sample data (see sample-data/ folder)
5. **Review test-plan.md** for the 10 key test cases before go-live
6. **Configure alerts** in Azure Monitor + Slack
7. **DPO sign-off** on EUR validation and data minimization
8. **Go-live** with scheduled trigger (daily 2 AM UTC)

---

## Support & Escalation

| Issue | Contact |
|-------|---------|
| **ADF/DataFlow deployment** | data-platform@acme.example |
| **Billing API connectivity** | billing-platform@acme.example |
| **Salesforce schema/custom fields** | crm-team@acme.example |
| **GDPR / Data compliance** | dpo@acme.example |
| **Orphan rate spike** | Automated alert → #data-ops |

See `README.md` → **Support & Escalation** section for details.

---

## Version History

| Date | Author | Changes |
|------|--------|---------|
| 2026-06-15 | Claude Code (Haiku) | Initial ADF implementation from Satsuma spec |

---

**Last updated:** 2026-06-15  
**Satsuma mapping reference:** `spec/acme_vorbild.stm:104-119`

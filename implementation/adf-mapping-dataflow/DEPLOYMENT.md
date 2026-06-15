# Deployment Guide: BillingToAssets Mapping DataFlow

---

## Prerequisites

1. **Azure Subscription** with:
   - Azure Data Factory (Standard or Premium tier)
   - Azure Blob Storage (for staging, crosswalks, remediation queue)
   - Azure SQL Database (for audit metrics table)
   - Integration Runtime (self-hosted or Azure IR with outbound access)

2. **Linked Services** (must be created before deploying DataFlow):
   - `BillingPlatformRestAPI` — OAuth2 credentials for billing API
   - `AzureBlobStorageLinkedService` — Storage connection string
   - `SalesforceLinkedService` — Salesforce OAuth / user credentials

3. **Salesforce Org**:
   - Asset object exists and is accessible via API
   - Custom fields: `Product_Code__c`, `MRR__c` (must be created beforehand)
   - API user with Asset Create/Update permissions

4. **Billing Platform**:
   - REST API endpoint `/v2/customers/{id}` is accessible
   - OAuth2 client credentials (Client ID + Secret)
   - Data format: JSON with nested `subscriptions` array (see `datasets.json`)

5. **Data Files** (in Azure Blob Storage):
   - `crosswalks/kd_ref_crosswalk.csv` — Customer reference crosswalk
   - Format: `customer_ref,kd_nr` (e.g., `KD-100247,100247`)

---

## Step 1: Create Linked Services

### 1.1 Billing Platform REST API

```bash
cat > linked_service_billing_api.json << 'EOF'
{
  "name": "BillingPlatformRestAPI",
  "type": "HttpServer",
  "typeProperties": {
    "url": "https://billing.api.acme.example",
    "authenticationType": "OAuth2ClientCredential",
    "clientId": "@{linkedService().billingApiClientId}",
    "clientSecret": {
      "type": "SecureString",
      "value": "@{linkedService().billingApiClientSecret}"
    },
    "tokenEndpoint": "https://auth.billing.acme.example/oauth/token",
    "scope": "billing:read"
  },
  "connectVia": {
    "referenceName": "AutoResolveIntegrationRuntime",
    "type": "IntegrationRuntimeReference"
  }
}
EOF

az datafactory linked-service create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingPlatformRestAPI" \
  --properties "@linked_service_billing_api.json"
```

**Set secure parameters in Key Vault:**
```bash
az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "billingApiClientId" \
  --value "<client-id>"

az keyvault secret set \
  --vault-name "<key-vault-name>" \
  --name "billingApiClientSecret" \
  --value "<client-secret>"
```

### 1.2 Azure Blob Storage

```bash
az datafactory linked-service create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "AzureBlobStorageLinkedService" \
  --properties '{
    "type": "AzureBlobStorage",
    "typeProperties": {
      "connectionString": {
        "type": "SecureString",
        "value": "DefaultEndpointProtocol=https;AccountName=<account>;AccountKey=<key>;EndpointSuffix=core.windows.net"
      }
    }
  }'
```

### 1.3 Salesforce

```bash
cat > linked_service_salesforce.json << 'EOF'
{
  "name": "SalesforceLinkedService",
  "type": "Salesforce",
  "typeProperties": {
    "environmentUrl": "https://acme.my.salesforce.com",
    "username": "api.user@acme.example",
    "password": {
      "type": "SecureString",
      "value": "@{linkedService().sfPassword}"
    },
    "securityToken": {
      "type": "SecureString",
      "value": "@{linkedService().sfSecurityToken}"
    }
  }
}
EOF

az datafactory linked-service create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "SalesforceLinkedService" \
  --properties "@linked_service_salesforce.json"
```

---

## Step 2: Create Datasets

```bash
# BillingApiCustomer_JSON
az datafactory dataset create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingApiCustomer_JSON" \
  --properties "@datasets.json[0]"

# AtlasKundenKdRef_CSV
az datafactory dataset create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "AtlasKundenKdRef_CSV" \
  --properties "@datasets.json[1]"

# SfAsset_Salesforce
az datafactory dataset create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "SfAsset_Salesforce" \
  --properties "@datasets.json[2]"

# OrphanRemediationQueue_Parquet
az datafactory dataset create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "OrphanRemediationQueue_Parquet" \
  --properties "@datasets.json[3]"
```

---

## Step 3: Create Mapping DataFlow

```bash
az datafactory data-flow create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets" \
  --properties "@BillingToAssets_MappingDataFlow.json"
```

Verify:
```bash
az datafactory data-flow show \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets"
```

---

## Step 4: Create Orchestrator Pipeline

```bash
az datafactory pipeline create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_Pipeline" \
  --properties "@pipeline-orchestrator.json"
```

**Important:** Update Slack webhook URLs in `pipeline-orchestrator.json`:
- Line containing `https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK`
- Replace with your Slack app's incoming webhook

---

## Step 5: Create Audit Table (SQL Database)

```sql
CREATE TABLE dbo.pipeline_metrics (
    id INT PRIMARY KEY IDENTITY(1,1),
    pipeline_name VARCHAR(255) NOT NULL,
    run_date DATETIME NOT NULL DEFAULT GETDATE(),
    records_processed INT,
    records_sunk INT,
    orphan_count INT,
    duration_ms INT,
    status VARCHAR(50),
    created_at DATETIME DEFAULT GETDATE()
);

CREATE INDEX idx_pipeline_run_date ON dbo.pipeline_metrics(pipeline_name, run_date DESC);
```

Add linked service to ADF:
```bash
az datafactory linked-service create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "AzureSqlDatabaseLinkedService" \
  --properties '{
    "type": "AzureSqlDatabase",
    "typeProperties": {
      "connectionString": {
        "type": "SecureString",
        "value": "Server=tcp:<server>.database.windows.net;Database=<db>;User ID=<user>;Password=<pass>"
      }
    }
  }'
```

---

## Step 6: Configure Triggers

### Manual Trigger (Test)
```bash
az datafactory trigger create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_Manual" \
  --trigger-type "ManualTrigger" \
  --pipelines '[{"pipelineReference": {"referenceName": "BillingToAssets_Pipeline", "type": "PipelineReference"}}]'
```

### Schedule Trigger (Daily at 2 AM UTC)
```bash
cat > trigger_schedule.json << 'EOF'
{
  "type": "ScheduleTrigger",
  "typeProperties": {
    "recurrence": {
      "frequency": "Day",
      "interval": 1,
      "startTime": "2026-06-16T02:00:00Z",
      "timeZone": "UTC"
    }
  },
  "pipelines": [
    {
      "pipelineReference": {
        "referenceName": "BillingToAssets_Pipeline",
        "type": "PipelineReference"
      }
    }
  ]
}
EOF

az datafactory trigger create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_DailyAt2AM" \
  --trigger-type "ScheduleTrigger" \
  --trigger "@trigger_schedule.json"
```

### Storage Event Trigger (When new billing export arrives)
```bash
cat > trigger_blob_event.json << 'EOF'
{
  "type": "BlobEventsTrigger",
  "typeProperties": {
    "blobPathBeginsWith": "/billing-exports/blobs/",
    "blobPathEndsWith": ".json",
    "ignoreEmptyBlobs": true,
    "events": ["Microsoft.Storage.BlobCreated"],
    "scope": "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<account>"
  },
  "pipelines": [
    {
      "pipelineReference": {
        "referenceName": "BillingToAssets_Pipeline",
        "type": "PipelineReference"
      }
    }
  ]
}
EOF

az datafactory trigger create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_OnNewExport" \
  --trigger-type "BlobEventsTrigger" \
  --trigger "@trigger_blob_event.json"
```

---

## Step 7: Deploy Monitoring & Alerts

### Configure Azure Monitor

```bash
# Create log analytics workspace
az monitor log-analytics workspace create \
  --resource-group "<resource-group>" \
  --workspace-name "adf-monitoring" \
  --location "westeurope"

# Link to ADF
az datafactory create \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --location "westeurope" \
  --logging-resource-id "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/adf-monitoring"
```

### Create Alert Rules

```bash
# Alert: Orphan rate > 0.5%
az monitor metrics alert create \
  --resource-group "<resource-group>" \
  --scopes "/subscriptions/<sub-id>/resourceGroups/<rg>/providers/microsoft.datafactory/factories/<adf-name>" \
  --name "BillingToAssets_HighOrphanRate" \
  --description "Orphan rate exceeded 0.5%" \
  --condition "avg ActivityRunResult where Activity == 'BillingToAssets' and RunResult == 'Failed' > 0.5" \
  --window-size 1h \
  --evaluation-frequency 5m \
  --severity 2 \
  --action "/subscriptions/<sub-id>/resourcegroups/<rg>/providers/microsoft.insights/actiongroups/DataOpsOnCall"
```

---

## Step 8: Test Deployment

### Unit Test: Validate DataFlow Schema

```bash
# Clone this repo
git clone https://github.com/acme-inc/satsuma-demo.git
cd implementation/adf-mapping-dataflow

# Validate DataFlow JSON
az datafactory data-flow validate \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --properties "@BillingToAssets_MappingDataFlow.json"
```

### Integration Test: Run with Sample Data

```bash
# Upload sample billing data to Blob Storage
az storage blob upload \
  --account-name "<account>" \
  --container-name "billing-exports" \
  --name "test-2026-06-15.json" \
  --file "./sample-data/billing_api_customer.json"

# Upload KD-REF crosswalk
az storage blob upload \
  --account-name "<account>" \
  --container-name "data-factory" \
  --name "crosswalks/kd_ref_crosswalk.csv" \
  --file "./sample-data/kd_ref_crosswalk.csv"

# Trigger pipeline (manual)
RUN_ID=$(az datafactory pipeline create-run \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --pipeline-name "BillingToAssets_Pipeline" \
  --query "runId" -o tsv)

echo "Pipeline run: $RUN_ID"

# Wait for completion (polling)
for i in {1..60}; do
  STATUS=$(az datafactory pipeline-run show \
    --resource-group "<resource-group>" \
    --factory-name "<adf-name>" \
    --run-id "$RUN_ID" \
    --query "status" -o tsv)
  
  if [ "$STATUS" = "Succeeded" ] || [ "$STATUS" = "Failed" ]; then
    echo "Pipeline $STATUS"
    break
  fi
  
  echo "Waiting... ($i/60) Status: $STATUS"
  sleep 5
done

# Check results
az datafactory activity-run query \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --pipeline-run-id "$RUN_ID" \
  --filters "PipelineName-eq-BillingToAssets_Pipeline" \
  --query "value[*].[activityName, status, output]" -o table
```

### E2E Test: Verify Salesforce Assets Created

```bash
# Query Salesforce for new Assets
sforce query "SELECT Id, Name, SerialNumber, Status, MRR__c FROM Asset WHERE CreatedDate >= TODAY() ORDER BY CreatedDate DESC LIMIT 10"

# Expected output: 3 Assets (2 from customer KD-100247, 1 from KD-100248)
```

---

## Step 9: Cleanup & Rollback

### Disable Triggers
```bash
az datafactory trigger delete \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_DailyAt2AM"
```

### Delete Pipeline (if needed)
```bash
az datafactory pipeline delete \
  --resource-group "<resource-group>" \
  --factory-name "<adf-name>" \
  --name "BillingToAssets_Pipeline"
```

### Restore Salesforce Assets (from backup)
```sql
-- Rollback in Salesforce via recycle bin or backup restore
-- If < 15 days old, recover from SF Recycle Bin
-- Otherwise, restore from backup
```

---

## Production Checklist

- [ ] All linked services created and tested
- [ ] KD-REF crosswalk CSV uploaded to Blob Storage
- [ ] Salesforce custom fields (Product_Code__c, MRR__c) exist and are populated
- [ ] Audit table created in SQL Database
- [ ] Triggers configured (schedule + manual)
- [ ] Alerts configured in Azure Monitor + Slack webhook
- [ ] Integration test passed (sample data processed correctly)
- [ ] Orphan rate acceptable (< 0.5% on test data)
- [ ] DataFlow validated with `az datafactory data-flow validate`
- [ ] DPO sign-off on GDPR compliance (EUR currency, no PII leakage)
- [ ] Go-live runbook prepared (escalation contacts, SLA definitions)
- [ ] Documentation links in ADF tags/annotations

---

## Rollout Plan

**Phase 1: Test (Week 1)**
- Manual trigger testing with sample data
- Verify Salesforce Asset creation
- Monitor orphan rate, validate error handling

**Phase 2: Staging (Week 2)**
- Deploy to staging ADF instance
- Run with 1 week of historical billing data
- Validate Salesforce sync quality, test orphan recovery

**Phase 3: Production (Week 3+)**
- Deploy to production ADF
- Enable scheduled trigger (daily 2 AM UTC)
- Monitor for first 7 days; escalate any anomalies
- Quarterly review of orphan rate, processing duration, data quality metrics

---

## Support Contacts

| Role | Contact | Escalation |
|------|---------|-----------|
| **ADF Infrastructure** | data-platform@acme.example | #data-ops (Slack) |
| **Billing Platform API** | billing-platform@acme.example | PagerDuty on-call |
| **Salesforce CRM** | crm-team@acme.example | Sales leadership |
| **Data Quality / DPO** | dpo@acme.example | Legal / Compliance |
| **On-Call Rotation** | [PagerDuty schedule] | https://acme.pagerduty.com |

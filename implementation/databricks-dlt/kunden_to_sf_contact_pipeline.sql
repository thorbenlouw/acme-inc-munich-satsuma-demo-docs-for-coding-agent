-- Databricks notebook source

-- MAGIC %md
-- MAGIC # Kunden → Salesforce Contact Export Pipeline
-- MAGIC
-- MAGIC Lakehouse Declarative Pipeline (DLT) — `kunden_to_sf_contact` reverse ETL data product.
-- MAGIC
-- MAGIC | | |
-- MAGIC |---|---|
-- MAGIC | **Owner** | sales-it (source) / crm-platform (target) |
-- MAGIC | **Steward** | sabine.keller@acme.example |
-- MAGIC | **Compliance** | GDPR — PII encrypted/masked; consent flag inverted per DPO sign-off |
-- MAGIC | **Scope** | Natural persons only (`VKZ = 'P'`). Companies (`VKZ = 'F'`) feed the Account pipeline. |
-- MAGIC | **Target object** | Salesforce Contact (SF Bulk API v2) |
-- MAGIC
-- MAGIC **Pipeline flow**
-- MAGIC
-- MAGIC ```
-- MAGIC ATLAS CSV export (cloud storage)
-- MAGIC        │
-- MAGIC        ▼
-- MAGIC [TEMP] bronze_atlas_kunden       — raw ingest, no transforms
-- MAGIC        │  filter VKZ = 'P'
-- MAGIC        ▼
-- MAGIC [TEMP] silver_kunden_contacts    — cleansed, DQ-flagged, VKZ='P' only
-- MAGIC        │
-- MAGIC        ├──► [GOLD] sf_contact            — valid rows, export-ready
-- MAGIC        └──► [GOLD] sf_contact_remediation — DQ failures for manual review
-- MAGIC ```
-- MAGIC
-- MAGIC **Key business rules (see acme_vorbild.stm `kunden_to_contact` mapping)**
-- MAGIC - `ANREDE` → `Salutation`: H→Herr, F→Frau, D→Divers, X→Familie, null→Divers
-- MAGIC - `EMAIL` → `Email`: trim | lowercase | strip trailing `;` | RFC 5322 check | null if still invalid
-- MAGIC - `TELEFON` → `Phone`: E.164 via `acme_utils.to_e164` UDF; ~2% expected to land in remediation
-- MAGIC - `WERBUNG_OK` → `HasOptedOutOfEmail`: **inverted** — J→false, N/null→true (GDPR: no consent = opted out)
-- MAGIC - `GEB_DATUM`: **not migrated** — GDPR Art 5(1)(c) data minimisation; purpose unclear on B2B system

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Pipeline Configuration
-- MAGIC
-- MAGIC Set the following in the DLT pipeline UI or Asset Bundle `pipeline.yml`:
-- MAGIC
-- MAGIC | Parameter | Description | Example |
-- MAGIC |---|---|---|
-- MAGIC | `atlas_kunden_landing_path` | Cloud storage landing zone for ATLAS KUNDEN CSV exports | `abfss://landing@acmedatalake.dfs.core.windows.net/atlas/kunden/` |
-- MAGIC | `pipeline_env` | Deployment tier — sets target catalog prefix | `prod` |
-- MAGIC
-- MAGIC **Pipeline target** (set in pipeline configuration):
-- MAGIC - Catalog: `${pipeline_env}_gold`
-- MAGIC - Schema: `salesforce_crm_export`
-- MAGIC
-- MAGIC The two `TEMPORARY` intermediate tables (`bronze_atlas_kunden`, `silver_kunden_contacts`)
-- MAGIC are managed by DLT only and are not published to Unity Catalog.

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Bronze — Raw Ingest from ATLAS KUNDEN
-- MAGIC
-- MAGIC Reads CSV exports from the ATLAS KUNDEN landing zone using Autoloader.
-- MAGIC No transforms applied — all source fields preserved faithfully.
-- MAGIC `GEB_DATUM` is ingested here but explicitly excluded at the gold layer.

-- COMMAND ----------

CREATE OR REFRESH TEMPORARY STREAMING TABLE bronze_atlas_kunden (
  KD_NR        INT       COMMENT "Customer number (PK). Not contiguous — gaps from 2009 archive purge.",
  ANREDE       STRING    COMMENT "Salutation code: H=Herr, F=Frau, D=Divers, X=couples/families (2003 campaign). No DB-level constraint — values discovered by profiling.",
  NAME1        STRING    COMMENT "Company name when VKZ=F; surname when VKZ=P. Overloaded column.",
  NAME2        STRING    COMMENT "First name when VKZ=P; second address line when VKZ=F. May be NULL.",
  VKZ          STRING    COMMENT "Customer type: F=Firma (company), P=Privat (person). Drives Salesforce object routing.",
  EMAIL        STRING    COMMENT "Email address. ~4.1% fail RFC 5322 — mostly trailing semicolons from 2011 import artifact.",
  TELEFON      STRING    COMMENT "Free-text phone. ~19 observed formats including local and international variants.",
  GEB_DATUM    STRING    COMMENT "Date of birth. ~12% populated. Ingested to bronze only — NOT forwarded to silver or gold (GDPR Art 5(1)(c) data minimisation: no clear purpose on a B2B sales system).",
  WERBUNG_OK   STRING    COMMENT "Marketing consent flag: J=opted in, N=opted out. Default N.",
  ANGELEGT_AM  TIMESTAMP COMMENT "Record creation timestamp (system-set by ATLAS).",
  _source_file    STRING    COMMENT "Autoloader source file path — retained for end-to-end lineage.",
  _ingested_at    TIMESTAMP COMMENT "Autoloader file modification time — proxy for export timestamp."
)
COMMENT "Raw ATLAS KUNDEN records from CSV landing zone. Source-faithful — no transformations. Classification: CONFIDENTIAL. Owner: sales-it."
TBLPROPERTIES (
  "owner"                   = "sales-it",
  "classification"          = "CONFIDENTIAL",
  "compliance"              = "GDPR",
  "pipeline.layer"          = "bronze",
  "pipeline.source_system"  = "atlas_postgres",
  "pipeline.data_product"   = "kunden_to_sf_contact"
)
AS SELECT
  CAST(KD_NR AS INT)                         AS KD_NR,
  ANREDE,
  NAME1,
  NAME2,
  VKZ,
  EMAIL,
  TELEFON,
  GEB_DATUM,
  WERBUNG_OK,
  CAST(ANGELEGT_AM AS TIMESTAMP)             AS ANGELEGT_AM,
  _metadata.file_path                        AS _source_file,
  _metadata.file_modification_time           AS _ingested_at
FROM cloud_files(
  "${atlas_kunden_landing_path}",
  "csv",
  map(
    "header",   "true",
    "encoding", "UTF-8",
    "schema",   "KD_NR STRING, ANREDE STRING, NAME1 STRING, NAME2 STRING, VKZ STRING, EMAIL STRING, TELEFON STRING, GEB_DATUM STRING, WERBUNG_OK STRING, ANGELEGT_AM STRING"
  )
);

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Silver — Cleansed & Validated Contacts
-- MAGIC
-- MAGIC Filters to natural persons (`VKZ = 'P'`), applies email/phone cleansing,
-- MAGIC and attaches DQ flags. Invalid values are NULL-ed rather than dropped so
-- MAGIC that no records are silently lost — the gold layer routes flagged rows
-- MAGIC to the remediation table.
-- MAGIC
-- MAGIC **Email cleansing**: trim → lowercase → strip trailing `;` chars → RFC 5322 check.
-- MAGIC **Phone normalisation**: delegated to `acme_utils.to_e164` registered UDF
-- MAGIC (handles the 19 observed source formats; see `acme_utils` library for format rules).

-- COMMAND ----------

CREATE OR REFRESH TEMPORARY STREAMING TABLE silver_kunden_contacts (
  KD_NR              INT       COMMENT "Customer number (PK).",
  ANREDE             STRING    COMMENT "Source salutation code — preserved for downstream map. Validated against {H, F, D, X}.",
  NACHNAME           STRING    COMMENT "Surname (from NAME1 where VKZ=P). Required for SF Contact LastName. PII.",
  VORNAME            STRING    COMMENT "First name (from NAME2 where VKZ=P). Optional. NULL when not present. PII.",
  EMAIL_CLEAN        STRING    COMMENT "Email after trim, lowercase, trailing-semicolon removal. NULL if still invalid after cleaning. PII.",
  EMAIL_VALID        BOOLEAN   COMMENT "True when EMAIL_CLEAN passes RFC 5322 basic format check.",
  TELEFON_E164       STRING    COMMENT "Phone normalised to E.164 by acme_utils.to_e164. NULL when normalisation fails (~2% expected). PII.",
  WERBUNG_OK         STRING    COMMENT "Source consent flag J/N — preserved for audit trail and gold-layer inversion.",
  ANGELEGT_AM        TIMESTAMP COMMENT "Source record creation timestamp.",
  _dq_anrede_unknown BOOLEAN   COMMENT "DQ flag: true when ANREDE was not in {H, F, D, X} and fallback mapping was applied.",
  _dq_email_invalid  BOOLEAN   COMMENT "DQ flag: true when email was NULL-ed due to failed validation. Record needs email remediation.",
  _dq_phone_failed   BOOLEAN   COMMENT "DQ flag: true when phone could not be normalised to E.164. Record needs phone remediation.",
  _source_file       STRING    COMMENT "Source file path for lineage.",
  _ingested_at       TIMESTAMP COMMENT "Source file ingestion timestamp."
)
COMMENT "Cleansed ATLAS KUNDEN records — natural persons (VKZ=P) only. DQ flags attached; invalid emails and phones are NULL-ed rather than dropped to prevent silent data loss. Owner: sales-it."
TBLPROPERTIES (
  "owner"                          = "sales-it",
  "classification"                 = "CONFIDENTIAL",
  "compliance"                     = "GDPR",
  "pipeline.layer"                 = "silver",
  "pipeline.data_product"          = "kunden_to_sf_contact",
  "quality.invalid_email_action"   = "null_and_flag",
  "quality.invalid_phone_action"   = "null_and_flag"
)
-- Hard failure: a row with no customer number cannot be loaded to SF or remediated
CONSTRAINT valid_kd_nr EXPECT (KD_NR IS NOT NULL) ON VIOLATION DROP ROW
-- Warn (don't drop): missing surname is a data quality concern but row is still routeable to remediation
CONSTRAINT has_last_name EXPECT (NAME1 IS NOT NULL AND LENGTH(TRIM(NAME1)) > 0) ON VIOLATION WARN
AS SELECT
  KD_NR,
  ANREDE,

  -- NAME1 = surname when VKZ='P'
  TRIM(NAME1)                                                                       AS NACHNAME,

  -- NAME2 = first name when VKZ='P'; may be NULL or blank
  NULLIF(TRIM(NAME2), '')                                                           AS VORNAME,

  -- Email: trim → lowercase → strip trailing semicolons → null if still non-RFC-5322
  CASE
    WHEN REGEXP_LIKE(
           REGEXP_REPLACE(TRIM(LOWER(EMAIL)), ';+\\s*$', ''),
           '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$'
         )
    THEN REGEXP_REPLACE(TRIM(LOWER(EMAIL)), ';+\\s*$', '')
    ELSE NULL
  END                                                                               AS EMAIL_CLEAN,

  REGEXP_LIKE(
    REGEXP_REPLACE(TRIM(LOWER(EMAIL)), ';+\\s*$', ''),
    '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$'
  )                                                                                 AS EMAIL_VALID,

  -- Phone: E.164 normalisation via registered UDF (handles 19 observed source formats)
  -- Returns NULL when normalisation is impossible; expect ~2% manual remediation residual
  acme_utils.to_e164(TELEFON)                                                      AS TELEFON_E164,

  WERBUNG_OK,
  ANGELEGT_AM,

  -- DQ flags for downstream routing and observability dashboards
  (ANREDE IS NOT NULL AND ANREDE NOT IN ('H', 'F', 'D', 'X'))                     AS _dq_anrede_unknown,

  (EMAIL IS NOT NULL AND NOT REGEXP_LIKE(
    REGEXP_REPLACE(TRIM(LOWER(EMAIL)), ';+\\s*$', ''),
    '^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}$'
  ))                                                                                AS _dq_email_invalid,

  (TELEFON IS NOT NULL AND acme_utils.to_e164(TELEFON) IS NULL)                   AS _dq_phone_failed,

  _source_file,
  _ingested_at

FROM STREAM(LIVE.bronze_atlas_kunden)
-- Only natural persons (VKZ='P') become Salesforce Contacts.
-- VKZ='F' (Firma) rows feed the separate Account pipeline.
WHERE VKZ = 'P';

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Gold — `sf_contact` Export Wide Table
-- MAGIC
-- MAGIC Reverse ETL data product. Wide table shaped exactly to the Salesforce Contact
-- MAGIC Bulk API v2 payload. This is the handoff point to the SF load job.
-- MAGIC
-- MAGIC Only rows with no critical DQ failures (`_dq_email_invalid = false`
-- MAGIC and `_dq_phone_failed = false`) flow here. Flagged rows go to
-- MAGIC `sf_contact_remediation` instead.
-- MAGIC
-- MAGIC **Consent inversion** — deliberate, reviewed by DPO (2026-06-19):
-- MAGIC `WERBUNG_OK = 'J'` (consented) → `HasOptedOutOfEmail = false`
-- MAGIC `WERBUNG_OK = 'N'` or null (no consent) → `HasOptedOutOfEmail = true`

-- COMMAND ----------

CREATE OR REFRESH LIVE TABLE sf_contact (
  -- Salesforce Contact API fields (SF API naming)
  LastName              STRING    COMMENT "Required by SF Contact. Mapped from NACHNAME (ATLAS NAME1 where VKZ=P). PII.",
  FirstName             STRING    COMMENT "Optional. Mapped from VORNAME (ATLAS NAME2 where VKZ=P). NULL when not present. PII.",
  Salutation            STRING    COMMENT "SF picklist: Herr|Frau|Divers|Familie. Mapped from ANREDE: H→Herr, F→Frau, D→Divers, X→Familie (2003 couples campaign, confirmed sales ops 2026-06-19), null→Divers.",
  Email                 STRING    COMMENT "RFC 5322 validated, lowercase, semicolons stripped. Encrypted AES-256-GCM in Salesforce. PII.",
  Phone                 STRING    COMMENT "E.164 normalised. PII.",
  HasOptedOutOfEmail    BOOLEAN   COMMENT "GDPR opt-out. Inverted from WERBUNG_OK: J→false, N/null→true. Inversion deliberate — no consent means opted OUT. DPO reviewed 2026-06-19.",
  -- ACME operational / lineage fields (mapped to custom SF fields on Contact)
  acme_kd_nr            INT       COMMENT "ATLAS customer number. Upsert key — maps to ExternalId__c in Salesforce.",
  acme_angelegt_am      TIMESTAMP COMMENT "Source record creation timestamp. Retained for migration audit trail.",
  acme_source_file      STRING    COMMENT "Source CSV file path — full lineage back to ATLAS export."
)
COMMENT "Salesforce Contact export wide table — reverse ETL data product. Shaped to SF Contact Bulk API v2. Valid rows only (no critical DQ failures). Owner: crm-platform. Steward: sabine.keller@acme.example. GDPR retention: 7 years after account closure; email erasure within 30 days of Art. 17 request."
TBLPROPERTIES (
  "owner"                         = "crm-platform",
  "steward"                       = "sabine.keller@acme.example",
  "classification"                = "CONFIDENTIAL",
  "compliance"                    = "GDPR",
  "retention"                     = "7y",
  "pipeline.layer"                = "gold",
  "pipeline.pattern"              = "reverse_etl_wide_table",
  "pipeline.data_product"         = "kunden_to_sf_contact",
  "pipeline.target_system"        = "salesforce_sales_cloud",
  "pipeline.target_object"        = "Contact",
  "pipeline.load_strategy"        = "upsert",
  "pipeline.upsert_key"           = "acme_kd_nr",
  "pii.columns"                   = "LastName,FirstName,Email,Phone",
  "pii.Email.treatment"           = "encrypt:AES-256-GCM,mask:partial_email",
  "pii.Phone.treatment"           = "mask"
)
AS SELECT
  NACHNAME                                    AS LastName,
  VORNAME                                     AS FirstName,

  -- Salutation picklist map (spec: acme_vorbild.stm kunden_to_contact mapping)
  CASE ANREDE
    WHEN 'H' THEN 'Herr'
    WHEN 'F' THEN 'Frau'
    WHEN 'D' THEN 'Divers'
    WHEN 'X' THEN 'Familie'    -- 2003 couples campaign; confirmed by sales ops 2026-06-19
    ELSE          'Divers'     -- null or undocumented value: default per spec
  END                                         AS Salutation,

  EMAIL_CLEAN                                 AS Email,
  TELEFON_E164                                AS Phone,

  -- GDPR consent inversion (spec: "GDPR: absence of consent means opted OUT. Inversion reviewed by DPO.")
  CASE WERBUNG_OK
    WHEN 'J' THEN false
    ELSE          true         -- 'N', null, or any unexpected value → opted OUT
  END                                         AS HasOptedOutOfEmail,

  KD_NR                                       AS acme_kd_nr,
  ANGELEGT_AM                                 AS acme_angelegt_am,
  _source_file                                AS acme_source_file

FROM LIVE.silver_kunden_contacts
-- Route only clean rows here; DQ failures go to sf_contact_remediation
WHERE _dq_email_invalid = false
  AND _dq_phone_failed  = false;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Gold — `sf_contact_remediation` DQ Quarantine Table
-- MAGIC
-- MAGIC Captures rows that could not be fully normalised and require manual
-- MAGIC review before loading to Salesforce.
-- MAGIC
-- MAGIC **Do not drop these rows** — identifier integrity is a hard requirement.
-- MAGIC Route to the data quality team; do not silently discard.
-- MAGIC
-- MAGIC Expected volumes (based on source profiling):
-- MAGIC - Email failures: ~4.1% of `VKZ='P'` rows
-- MAGIC - Phone failures: ~2% of `VKZ='P'` rows (some rows may have both failures)

-- COMMAND ----------

CREATE OR REFRESH LIVE TABLE sf_contact_remediation (
  KD_NR              INT       COMMENT "ATLAS customer number (PK) — key for manual remediation workflow.",
  NACHNAME           STRING    COMMENT "Surname. PII.",
  VORNAME            STRING    COMMENT "First name. PII.",
  EMAIL_CLEAN        STRING    COMMENT "Cleaned email, or NULL if validation failed. PII.",
  TELEFON_E164       STRING    COMMENT "E.164 phone, or NULL if normalisation failed. PII.",
  ANREDE             STRING    COMMENT "Source salutation code.",
  WERBUNG_OK         STRING    COMMENT "Source consent flag.",
  ANGELEGT_AM        TIMESTAMP COMMENT "Source record creation timestamp.",
  _dq_email_invalid  BOOLEAN   COMMENT "True when email could not be validated — primary remediation reason.",
  _dq_phone_failed   BOOLEAN   COMMENT "True when phone could not be normalised to E.164 — secondary remediation reason.",
  _dq_anrede_unknown BOOLEAN   COMMENT "True when salutation required fallback mapping.",
  _source_file       STRING    COMMENT "Source file path for lineage.",
  _ingested_at       TIMESTAMP COMMENT "Source ingestion timestamp."
)
COMMENT "DQ quarantine for sf_contact pipeline. Rows with email or phone normalisation failures that cannot be auto-loaded to Salesforce. Requires manual remediation before re-ingestion. Owner: sales-it. Do not drop — identifier integrity requirement."
TBLPROPERTIES (
  "owner"                     = "sales-it",
  "steward"                   = "sabine.keller@acme.example",
  "classification"            = "CONFIDENTIAL",
  "compliance"                = "GDPR",
  "pipeline.layer"            = "gold",
  "pipeline.data_product"     = "kunden_to_sf_contact",
  "pipeline.purpose"          = "dq_remediation",
  "pii.columns"               = "NACHNAME,VORNAME,EMAIL_CLEAN,TELEFON_E164"
)
AS SELECT
  KD_NR,
  NACHNAME,
  VORNAME,
  EMAIL_CLEAN,
  TELEFON_E164,
  ANREDE,
  WERBUNG_OK,
  ANGELEGT_AM,
  _dq_email_invalid,
  _dq_phone_failed,
  _dq_anrede_unknown,
  _source_file,
  _ingested_at
FROM LIVE.silver_kunden_contacts
WHERE _dq_email_invalid = true
   OR _dq_phone_failed  = true;

-- COMMAND ----------

-- MAGIC %md
-- MAGIC ## Post-Pipeline: Unity Catalog Column Tags
-- MAGIC
-- MAGIC DLT does not support column-level tag DDL within the pipeline notebook.
-- MAGIC Run the following **once after the first successful pipeline execution**
-- MAGIC (e.g. as a post-pipeline job step or via the Asset Bundle `post_pipeline` hook):
-- MAGIC
-- MAGIC ```sql
-- MAGIC -- sf_contact PII column tags
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact
-- MAGIC   ALTER COLUMN LastName   SET TAGS ('pii' = 'true');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact
-- MAGIC   ALTER COLUMN FirstName  SET TAGS ('pii' = 'true');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact
-- MAGIC   ALTER COLUMN Email      SET TAGS ('pii' = 'true', 'pii_treatment' = 'encrypt:AES-256-GCM,mask:partial_email');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact
-- MAGIC   ALTER COLUMN Phone      SET TAGS ('pii' = 'true', 'pii_treatment' = 'mask');
-- MAGIC
-- MAGIC -- sf_contact_remediation PII column tags
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact_remediation
-- MAGIC   ALTER COLUMN NACHNAME     SET TAGS ('pii' = 'true');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact_remediation
-- MAGIC   ALTER COLUMN VORNAME      SET TAGS ('pii' = 'true');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact_remediation
-- MAGIC   ALTER COLUMN EMAIL_CLEAN  SET TAGS ('pii' = 'true');
-- MAGIC ALTER TABLE ${pipeline_env}_gold.salesforce_crm_export.sf_contact_remediation
-- MAGIC   ALTER COLUMN TELEFON_E164 SET TAGS ('pii' = 'true');
-- MAGIC ```

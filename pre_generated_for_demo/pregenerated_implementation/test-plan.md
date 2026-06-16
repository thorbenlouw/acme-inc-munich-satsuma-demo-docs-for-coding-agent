# Manual E2E Test Plan: ATLAS Kunden → Salesforce Mapping

**Scope:** `kunden_to_contact` and `billing to assets` mappings  
**Priority:** Compliance risk > Complex logic > Data quality  
**Execution:** QA + Data Steward + DPO review gates

---

## Top 10 Test Cases (Prioritized)

### 1. 🔴 CRITICAL: GDPR Consent Inversion (WERBUNG_OK → HasOptedOutOfEmail)

**Why first:** Inverted logic, DPO-reviewed, legal exposure if reversed.

**Setup:**
- Load 100 kunden rows with WERBUNG_OK = {J, N, null}
- Map to sf_contact

**Expected:**
- WERBUNG_OK = J → HasOptedOutOfEmail = false (CAN send marketing)
- WERBUNG_OK = N → HasOptedOutOfEmail = true (OPT OUT)
- WERBUNG_OK = null → HasOptedOutOfEmail = true (default: opted OUT)

**Validation:**
- [ ] No rows have inverted values
- [ ] DPO attestation that field note "GDPR: absence of consent means opted OUT" is visible in sf_contact.HasOptedOutOfEmail metadata
- [ ] Spot-check 3 rows in SF: verify toggling sf_contact.HasOptedOutOfEmail sends/blocks emails as documented

**Risk if failed:** GDPR Art. 7 violation (unlawful marketing to non-consented contacts)

---

### 2. 🔴 CRITICAL: Email Erasure SLA (Art. 17 Right to Erasure)

**Why:** Retention policy: "erasure within 30 days of Art. 17 request"

**Setup:**
- Create a test Contact in SF with Email = 'jane.test@example.com'
- Simulate GDPR erasure request (flag in audit system or mock SLA timer)
- After 30 days, verify erasure execution

**Expected:**
- Email field is blanked (or Contact is soft-deleted)
- Audit log shows erasure timestamp ≤ 30 days from request
- Downstream (no transactional email sent to erasure-requested contact)

**Validation:**
- [ ] Erasure workflow exists and is tested before go-live
- [ ] 30-day SLA is monitored (Grafana alert if pending > 30d)
- [ ] Spot-check 3 historical erasure requests: all completed within SLA

**Risk if failed:** GDPR Art. 17 breach; regulatory fines up to €20M or 4% of turnover

---

### 3. 🔴 CRITICAL: GEB_DATUM Suppression (Art. 5(1)(c) Purpose Limitation)

**Why:** B2B sales system should not hold personal DOB; flagged as `//?` open question.

**Setup:**
- Load 50 kunden rows with GEB_DATUM populated (1950–2010 dates, various months/days)
- Run kunden_to_contact mapping

**Expected:**
- GEB_DATUM does NOT appear in sf_contact (no LastModifiedDate, no Birthdate field, etc.)
- GEB_DATUM is NOT exported to any downstream system from this mapping
- sf_contact schema has NO field accepting or storing GEB_DATUM

**Validation:**
- [ ] Query sf_contact table; confirm zero rows have GEB_DATUM
- [ ] Verify mapping file has explicit note: "GEB_DATUM suppressed for GDPR Art. 5(1)(c) compliance"
- [ ] DPO sign-off: "GEB_DATUM storage in atlas_kunden is out-of-scope for this remediation; future audit required"

**Risk if failed:** GDPR Art. 5(1)(c) purpose-limitation breach; "Data minimization" violation

---

### 4. 🟠 HIGH: ANREDE='X' Couples Mapping (Undocumented Enum, Sales Confirmed)

**Why:** 312 rows with undocumented 'X'; confirmed in 2026-06-19 workshop by sales ops.

**Setup:**
- Load 30 kunden rows with:
  - ANREDE ∈ {H, F, D, X}
  - NAME1 = 'Familie [Lastname]', ANREDE='X'
- Map to sf_contact

**Expected:**
- H → Salutation = "Herr"
- F → Salutation = "Frau"
- D → Salutation = "Divers"
- X → Salutation = "Familie" (not "unknown", not null)

**Validation:**
- [ ] Query sf_contact where Salutation = "Familie"; count = 30 (or actual 'X' rows)
- [ ] Spot-check 5 rows: NAME1 contains "Familie", Salutation = "Familie"
- [ ] Confirm mapping file has explicit note: "X: Familie (2003 couples campaign — confirmed by sales ops, 2026-06-19 workshop)"
- [ ] Email alert sent to sales@acme.example if unmapped ANREDE value appears

**Risk if failed:** Incorrect customer communication (e.g., "Dear Herr Familie" instead of "Dear Familie")

---

### 5. 🟠 HIGH: Email RFC 5322 Validation & Cleaning (2011 Import Artifact)

**Why:** 4.1% of emails fail RFC 5322; ~312 have trailing semicolons from 2011 import.

**Setup:**
- Load 100 kunden rows with EMAIL sampled across:
  - Valid: 'john@example.de'
  - Trailing semicolon: 'jane@example.de;'
  - Trailing @: 'bob@'
  - Missing domain: 'carol@.de'
  - Whitespace: '  dave@example.de  '
  - Mixed case: 'EVE@EXAMPLE.DE'

**Expected:**
- Valid emails normalized: trim, lowercase
- Trailing semicolon stripped: 'jane@example.de;' → 'jane@example.de'
- Invalid emails (no domain, trailing @, etc.) → Email = null
- Whitespace trimmed and case normalized

**Validation:**
- [ ] Count of Email = null in sf_contact ≈ expected invalid %
- [ ] Spot-check 5 valid rows: Email is lowercase, no whitespace
- [ ] Spot-check 3 trailing-semicolon rows: Email is valid, no `;`
- [ ] Spot-check 2 invalid rows: Email = null
- [ ] Data-quality report: "Email validation results: X valid, Y invalid (null), Z manually reviewed"

**Risk if failed:** Invalid emails sent to SF; CRM bounces; consent tracking fails

---

### 6. 🟠 HIGH: Phone Format Conversion (19 Observed Formats, 2% Remediation Queue)

**Why:** `to_e164` must handle 19 format variants; spec warns "expect ~2% manual remediation."

**Setup:**
- Load 100 kunden rows with TELEFON sampled across observed formats:
  - '089/12 34 56-0' (Munich local)
  - '+49 89 552014' (int'l + country code)
  - '0171-9988776' (mobile)
  - '+49 (0)89 / 76 54 32' (parentheses)
  - '+4915123456789' (mobile int'l)
  - 'invalid' (unparseable)
  - null

**Expected:**
- All valid formats convert to E.164 (leading +49, no spaces/dashes)
- Invalid/unparseable → Phone = null OR flagged for manual review
- ~2% fail and route to remediation queue (monitoring alert)

**Validation:**
- [ ] Count of Phone = null or flagged in remediation ≈ 2 (2% of 100)
- [ ] Spot-check 5 converted phones: match E.164 regex `^\+49\d{9,11}$`
- [ ] Spot-check 1 invalid: Phone = null or status = "REMEDIATION_PENDING"
- [ ] Remediation queue report: "100 records processed; 2 flagged for manual review (phone format)"

**Risk if failed:** Invalid phone numbers in SF; SMS/call campaigns fail; data quality degradation

---

### 7. 🟠 HIGH: VKZ Filter (Only 'P' Persons to sf_contact; 'F' Companies Routed Elsewhere)

**Why:** Mapping has explicit source filter "VKZ = 'P'"; company rows must be excluded.

**Setup:**
- Load 50 kunden rows:
  - 30 with VKZ = 'P' (Privat/person)
  - 20 with VKZ = 'F' (Firma/company)

**Expected:**
- sf_contact receives 30 rows (VKZ = 'P' only)
- 20 rows with VKZ = 'F' are NOT in sf_contact
- Note in mapping states: "Only natural persons become Contacts; VKZ='F' rows feed the Account mapping"

**Validation:**
- [ ] Count sf_contact rows = 30 (or verify against kunden source count)
- [ ] Query sf_contact; confirm zero rows have VKZ = 'F'
- [ ] Confirm mapping source block includes filter: `atlas_kunden (filter "VKZ = 'P'")`
- [ ] Account mapping (future): receives 20 'F' rows (spot-check 3)

**Risk if failed:** Companies mapped as Contacts; duplicate/incorrect records in CRM; reporting corruption

---

### 8. 🟡 MEDIUM: Billing Cross-Ref Orphan Handling (0.4% Orphan Rate)

**Why:** `billing to assets` mapping uses KD-REF crosswalk; spec warns ~0.4% are orphans.

**Setup:**
- Load billing_api_customer with 250 records:
  - 249 with valid customer_ref (can join to atlas_kunden via KD-REF crosswalk)
  - 1 orphan (no match in KD-REF)

**Expected:**
- 249 subscriptions map to sf_asset successfully
- 1 orphan routes to remediation queue
- Audit log: "Processed 250 billing records; 1 orphan (0.4%) routed to remediation"

**Validation:**
- [ ] sf_asset record count = 249 (or total subscriptions across 249 customers)
- [ ] Orphan record(s) appear in remediation/exception log with timestamp
- [ ] Remediation queue SLA monitored (e.g., resolve within 5 business days)
- [ ] Spot-check 2 successful joins: sf_asset.AccountId (or parent) correctly linked

**Risk if failed:** Orphan subscriptions lost; revenue data incomplete; churn tracking broken

---

### 9. 🟡 MEDIUM: Nested Iteration (Billing Subscriptions → SF Assets)

**Why:** `each subscriptions -> sf_asset` is complex nesting; requires careful cardinality testing.

**Setup:**
- Load billing_api_customer with:
  - Customer A: 2 active subscriptions + 1 cancelled
  - Customer B: 1 active subscription
  - Customer C: 0 subscriptions
  - Customer D: 5 subscriptions (stress test)

**Expected:**
- Customer A → 3 sf_asset rows (one per subscription)
- Customer B → 1 sf_asset row
- Customer C → 0 sf_asset rows (no mapping, no error)
- Customer D → 5 sf_asset rows
- Status mapping: cancelled_on = null → Status='Active'; cancelled_on ≠ null → Status='Cancelled'

**Validation:**
- [ ] sf_asset row count = 3 + 1 + 0 + 5 = 9 (or actual sum of subscriptions)
- [ ] Spot-check Customer A: 3 rows in sf_asset, all with same AccountId/ContactId
- [ ] Spot-check Status field: Active rows have cancelled_on=null in source; Cancelled rows have cancelled_on date
- [ ] Verify no duplicate sf_asset rows (SerialNumber should be unique per contract_no)

**Risk if failed:** Duplicate assets created; cardinality explosion; financial reporting broken

---

### 10. 🟡 MEDIUM: PII Encryption & Audit Trail (Email, Phone, Names)

**Why:** EMAIL, TELEFON, NAME1, NAME2 are all tagged `(pii)`; sf_contact.Email has `(encrypt AES-256-GCM)`.

**Setup:**
- Map 20 kunden rows to sf_contact
- Monitor data in transit and at rest

**Expected:**
- Email field in sf_contact encrypted with AES-256-GCM (visible in field metadata)
- Phone field tagged (pii) (visible in field metadata)
- NAME1/NAME2 tagged (pii) in atlas_kunden
- Audit trail logs access to any PII field by user/system
- GEB_DATUM (classified "RESTRICTED") is not accessible in sf_contact

**Validation:**
- [ ] sf_contact.Email metadata includes `encrypt AES-256-GCM`
- [ ] sf_contact.Phone metadata includes `(pii)`
- [ ] Query SIEM/audit log for access to Email, Phone, LastName; verify legitimate user/system only
- [ ] Attempt to query GEB_DATUM from sf_contact; confirm access denied or field does not exist
- [ ] Data-classification report: PII fields marked correctly in both source and target

**Risk if failed:** Unauthorized PII access; GDPR Art. 32 breach (inadequate encryption); audit failure

---

## Execution Plan

| Case | Risk | Owner | Duration | Gate |
|------|------|-------|----------|------|
| 1 | 🔴 GDPR Art. 7 | QA + DPO | 1h | DPO sign-off before go-live |
| 2 | 🔴 GDPR Art. 17 (30d SLA) | QA + Ops | 2h | SLA monitoring setup confirmed |
| 3 | 🔴 GDPR Art. 5(1)(c) | Data Steward + DPO | 1h | DPO attestation |
| 4 | 🟠 Data quality (ANREDE) | QA + Sales | 1h | Sales ops spot-check |
| 5 | 🟠 Data quality (Email) | QA | 1.5h | Validation report reviewed |
| 6 | 🟠 Data quality (Phone) | QA | 1.5h | Remediation queue SLA set |
| 7 | 🟠 Schema filtering (VKZ) | QA + DBA | 1h | Filter logic audit |
| 8 | 🟡 Cardinality (orphans) | QA + DBA | 1.5h | Remediation SLA set |
| 9 | 🟡 Nesting (subscriptions) | QA | 1.5h | Deduplication logic verified |
| 10 | 🟡 PII encryption & audit | QA + InfoSec | 2h | Encryption key mgmt + SIEM logs verified |

**Total effort:** ~15 hours (1 QA + 1 DPO + 1 Data Steward, spread over 3–4 sprints before go-live)

---

## Success Criteria

- [ ] All 10 cases pass with documented evidence (screenshots, data extracts, audit logs)
- [ ] DPO sign-off on cases 1–3 (GDPR compliance gates)
- [ ] Sales ops sign-off on case 4 (ANREDE='X' confirmation)
- [ ] InfoSec sign-off on case 10 (encryption + PII handling)
- [ ] SLA monitoring configured for cases 6, 8 (remediation queues)
- [ ] Test-case summaries added to go-live runbook

---

## Out of Scope

- Unit tests (developer responsibility)
- Load testing (separate perf test plan)
- Rollback procedures (separate runbook)
- Account mapping (VKZ='F'; future phase)

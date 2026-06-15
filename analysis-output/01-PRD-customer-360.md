# PRD — Acme Inc Customer 360 on Salesforce

| | |
|---|---|
| **Document** | Product Requirements — "Customer 360" migration, Phase 1 |
| **Status** | Approved for discovery; scope baselined |
| **Version** | 1.3 (supersedes the spreadsheet-only baseline) |
| **Owner** | Markus Brandt (Solution Architect) |
| **Last review** | 2026-06-08 |
| **Classification** | INTERNAL |

> This PRD states *what* Acme wants and *why*, and fixes the scope of Phase 1.
> It deliberately does **not** specify field-level mapping rules — those live in
> the Satsuma workspace, which is derived from this PRD plus the source-system
> analyses (docs 03–05) and the governance register (doc 06).

---

## 1. Background

Acme Inc designs and sells industrial sensors across the DACH region. The
company is 25 years old. Its system of record for customers and sales is
**ATLAS**, an in-house PostgreSQL OLTP application built in 1998 (tables and
columns are named in German). Billing runs on a separate internal platform
exposed only through a **REST API**. Support tickets live in a third system,
also API-only.

The board has purchased Salesforce Sales Cloud and mandated a **Customer 360**:
a single Salesforce Account per customer, with its Contacts, its order history,
its billing health, and its open support tickets visible in one place.

### Why now / why this is hard

- The de-facto specification today is a spreadsheet,
  `Customer_Migration_Mapping_v17_FINAL_(2).xlsx` — 1,407 rows, six tabs, three
  undocumented colour conventions. It is owned by no running system.
- Institutional knowledge of ATLAS is thin. The original DBA (Gerhard L.)
  retired in 2019. Several columns have meanings nobody currently at Acme can
  explain (see doc 03).
- The migration touches personal data at scale and introduces a new cloud
  data recipient → triggers DPO involvement and a DPIA (see doc 06).

---

## 2. Goals & success criteria

| # | Goal | Success criterion (measurable) |
|---|---|---|
| G1 | Single customer view in Salesforce | Every active ATLAS customer resolvable to exactly one SF Account |
| G2 | Contacts migrated for natural persons | All `VKZ = 'P'` customers become SF Contacts; companies (`VKZ = 'F'`) become Accounts |
| G3 | Billing health visible | Each active billing subscription appears as an SF Asset linked to its customer |
| G4 | No silent data-quality loss | Every known source defect (bad emails, phone formats, orphan refs) has a *documented* handling decision before go-live |
| G5 | Demonstrable governance | PII inventory, retention, and consent handling are queryable artifacts, not a one-off Word doc |
| G6 | Auditable change control | Every change to the mapping is a reviewed, attributable diff |

---

## 3. Scope

### In scope — Phase 1

1. **Customers → Accounts/Contacts.** ATLAS `KUNDEN` is the source. Split by
   `VKZ`: companies become Accounts, natural persons become Contacts.
2. **Billing subscriptions → Assets.** Billing API `GET /v2/customers/{id}`;
   each subscription becomes one SF Asset, linked to the customer.
3. **Consent & salutation normalisation.** German marketing-consent flag and
   salutation codes mapped to Salesforce equivalents.
4. **Governance metadata.** PII tagging, retention, masking/encryption posture
   captured *with* the schema.

### Out of scope — Phase 1 (named so it is not forgotten)

- **Order history** (`AUFTRAEGE` / `AUFTRAGSPOSITIONEN`). Wanted for the full
  360 but deferred to Phase 2. The ATLAS ER diagram (doc 03) shows these tables
  so the target model can anticipate them.
- **Support tickets** (Support API). Phase 3.
- **Entity resolution / de-duplication / survivorship.** ATLAS is treated as
  authoritative for identity in Phase 1; matching across systems beyond the
  documented `KD-REF` crosswalk is explicitly **not** attempted here.
- **Delta / incremental loads and cutover reconciliation.** Phase 1 is a
  one-shot historical migration; ongoing sync is a separate workstream.

> **Note for the architect:** items in "out of scope" are the parts that
> traditionally kill migrations. Satsuma does not execute them, but the spec is
> the *input contract* where their policies (e.g. the crosswalk and its orphan
> rate) get written down — see doc 04.

---

## 4. The delivery team (the cast)

| Role | Person | Responsibility on this migration |
|---|---|---|
| Business Analyst | **Sabine Keller** | Owns the source-to-target knowledge; runs the workshops that resolve open questions; data steward for the SF target |
| Solution Architect | **Markus Brandt** | Target model, integration patterns, this PRD |
| Data Engineer | **Priya Nair** | Source profiling, pipeline build against the spec |
| QA Lead | **Jonas Frei** | Test coverage; every mapping rule yields a test |
| DPO / Governance | **Dr. Weber** | GDPR Art. 30 record, DPIA, retention, consent |
| Security | **Leyla Demir** | Encryption, masking, access control, secrets |

**Absent but load-bearing:** *Gerhard L.*, original ATLAS DBA, retired 2019.
Several open questions in doc 03 are addressed "to Gerhard" in the legacy
spreadsheet. His knowledge is the canonical example of context that was never
written down.

---

## 5. Constraints

- **C1 — Works council (Betriebsrat).** Tooling decisions are co-determined.
  Any AI assistance must demonstrably not be employee monitoring.
- **C2 — Data protection.** Customer personal data must not leave Acme's
  network to a model provider. Discovery runs on *metadata and aggregates*
  (DDL, schemas, column statistics), never on customer rows. See doc 06 §2.
- **C3 — EU AI Act readiness.** The organisation must be able to show, for any
  AI-in-the-loop process: where the human oversight is, and where the record
  is. (Engineering position only; legal interpretation is counsel's.)
- **C4 — Single currency.** The billing platform is EUR-only; no FX handling in
  Phase 1.
- **C5 — Target org reality.** Salesforce picklist values and custom fields
  must exist in the target org before load; the spec may *declare* them but
  org-side validation is a deployment-time check.

---

## 6. Source systems (pointer)

| System | Kind | Access | Analysis doc |
|---|---|---|---|
| ATLAS | PostgreSQL OLTP | Direct DDL + read replica for profiling | [03](03-atlas-source-analysis.md) |
| Billing platform | Internal REST API | `GET /v2/customers/{id}` (JSON) | [04](04-billing-api-analysis.md) |
| Support platform | Internal REST API | (Phase 3 — not analysed yet) | — |
| Salesforce | Target SaaS | Metadata API | [05](05-salesforce-target-model.md) |

---

## 7. Acceptance — what "done" looks like for Phase 1

1. Every Phase-1 source field is either **mapped** to a target field, or
   explicitly **not mapped** with a recorded reason (data minimisation counts).
2. Every target required field is covered by a mapping or has a documented
   default. Unmapped required target fields are a **build failure**, not a
   go-live surprise.
3. Every PII field carries a governance decision (mask/encrypt/retention).
4. Every business rule (salutation map, consent inversion, status derivation)
   is enumerable and testable.
5. The whole of the above is one reviewable workspace under version control.

> The mechanical form of criteria 1–5 is exactly what `satsuma validate`,
> `satsuma lint`, and `satsuma fields --unmapped-by` check. That is not a
> coincidence: the acceptance criteria were written to be machine-checkable.

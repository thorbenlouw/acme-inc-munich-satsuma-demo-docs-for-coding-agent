# Data Governance & DPIA Notes — Customer 360 Migration

| | |
|---|---|
| **Owners** | Dr. Weber (DPO) + Leyla Demir (Security) |
| **Status** | Discovery-stage governance register (pre-DPIA sign-off) |
| **Last review** | 2026-06-11 |
| **Classification** | CONFIDENTIAL |

> This is the governance lens on the migration: what personal data exists, how
> it is classified, what is masked/encrypted, how long it is kept, and which
> fields raise a data-minimisation question. It yields the `compliance`,
> `retention`, `mask`, `encrypt`, and `classification` metadata on the schemas,
> the consent-inversion rationale, and — most importantly — the **decision not
> to migrate `GEB_DATUM`**.
>
> The whole point of capturing this *with the schema* (rather than in a separate
> Word document) is **Art. 5(2) accountability**: compliance becomes a property
> of the artifact the engineers build from, regenerated on every change.

---

## 1. Legal & regulatory frame (engineering summary — not legal advice)

- **GDPR anchors:** Art. 5(1)(c) data minimisation; Art. 5(2) accountability;
  Art. 17 erasure; Art. 28 processors; Art. 30 records of processing; Art. 35
  DPIA. *(Confirm exact obligations and the current AI Act timeline with counsel
  before the talk — the regulatory dates have moved.)*
- **DPIA trigger:** large-scale processing of customer personal data + a new
  cloud recipient (Salesforce) ⇒ DPIA required (Art. 35).
- **Processor:** Salesforce as Art. 28 processor; DPA in place.
- **AI usage:** discovery uses a general-purpose model on **metadata only**
  (see §2). The deployer (Acme) does not fine-tune. The relevant question for
  any AI-in-the-loop step is *"where is the human oversight and where is the
  record?"* — answered structurally: the AI emits a spec, a named human
  approves every change in review, and the record is the git history.

---

## 2. Data-minimisation boundary for discovery (constraint C2, made concrete)

What the AI may see, and what it may not:

| Allowed to cross to the model | **Never** crosses |
|---|---|
| DDL / schema definitions | Customer rows |
| Column statistics & distributions (with min-count thresholds) | Individual PII values |
| Value *sets* of low-cardinality coded columns (`H/F/D/X`) | Email/phone/DOB contents |
| Format *exemplars* (synthetic or masked) | Re-identifiable small-group aggregates |

Profiling is **deterministic tooling running inside Acme's network**; only the
aggregates above leave it. (Known sharp edge: column statistics on an email
column can themselves leak — the profiler applies minimum-count thresholds and
masks exemplars. Be ready to describe this if challenged.)

---

## 3. PII register (Phase 1)

| Field | Category | Classification | Mask | Encrypt | Migrated? |
|---|---|---|---|---|---|
| `atlas_kunden.NAME1` | identity (name/company) | CONFIDENTIAL | — | in transit | yes → LastName/Account |
| `atlas_kunden.NAME2` | identity (name) | CONFIDENTIAL | — | in transit | yes → FirstName |
| `atlas_kunden.EMAIL` | contact | CONFIDENTIAL | partial_email | AES-256-GCM | yes → Email |
| `atlas_kunden.TELEFON` | contact | CONFIDENTIAL | — | in transit | yes → Phone |
| `atlas_kunden.GEB_DATUM` | **special-category-adjacent** (DOB) | **RESTRICTED** | — | — | **NO — see §4** |
| `sf_contact.Email` | contact | CONFIDENTIAL | partial_email | AES-256-GCM | target |
| `sf_contact.Phone` | contact | CONFIDENTIAL | — | in transit | target |

→ Spec: `pii` tags, `classification` overrides, `mask partial_email`,
`encrypt AES-256-GCM` on `sf_contact.Email`.

---

## 4. The `GEB_DATUM` decision — data minimisation as a queryable fact

**Finding (doc 03 Q2):** ATLAS holds a date-of-birth column on a B2B sales
system. It is populated for only ~12% of rows and no current business purpose
justifies it.

**DPO decision (week 1):** `GEB_DATUM` is **not migrated**. It has no downstream
target. The source field is flagged for a separate retention/erasure assessment
(deletion at source needs its own legal-basis check — retention duties can
forbid erasure, so disposal is the DPO's call, not the pipeline's).

**Why this matters for the demo:** the spec *proves the absence*. There is no
arrow out of `atlas_kunden.GEB_DATUM`, and lineage confirms it:

```
$ satsuma field-lineage atlas_kunden.GEB_DATUM --downstream
::atlas_kunden.GEB_DATUM
  └─ (no downstream arrows)
```

In the old world this field reaches Salesforce in sprint 2 because it was in the
spreadsheet, and is found in an audit 18 months later. Here, minimisation is a
**queryable fact**, decided up front.

---

## 5. Consent handling — the inversion, with rationale

| ATLAS `WERBUNG_OK` | SF `HasOptedOutOfEmail` | Basis |
|---|---|---|
| `J` (consented) | `false` (not opted out) | explicit consent recorded |
| `N` (not consented) | `true` (opted out) | no consent ⇒ no marketing |
| null (unknown) | `true` (opted out) | **absence of consent = opted out** (conservative, GDPR-aligned) |

The null→opted-out default is a deliberate, DPO-reviewed decision. It is
**visible** in the spec (`// GDPR: absence of consent means opted OUT.
Inversion is deliberate — reviewed by DPO.`) rather than buried as an implicit
`else` branch in pipeline code. Getting this wrong emails people who opted out —
the one-line bug the diff makes reviewable.

---

## 6. Retention

| Object | Retention | Anchor | Erasure override |
|---|---|---|---|
| `sf_contact` | 7 years | after Account closure (close date) | Email erasable within 30 days of Art. 17 request |

→ Spec: `retention "7y"` + the retention `note` on `sf_contact`.

---

## 7. Security posture (Leyla)

- **In transit:** mTLS to billing API; TLS to Salesforce Bulk API.
- **At rest:** `Email` encrypted AES-256-GCM (Salesforce Shield / platform
  encryption); masking `partial_email` for non-privileged views.
- **Secrets:** service tokens in the secrets manager; none in the spec, the
  pipeline config, or git.
- **Access:** RESTRICTED-classified fields (`GEB_DATUM`) gated even at source;
  moot for the target since the field is not migrated.

→ The security audit becomes a **query**, not a meeting: *"show every
classified field missing `encrypt`/`mask`"* runs against the spec.

---

## 8. Art. 30 record — generated, not transcribed

Because purpose, categories, recipients, retention, and safeguards are all
**on the schemas**, the Art. 30 record of processing is generated from the spec
and regenerated on every change. The accountability obligation (Art. 5(2))
stops being a documentation project and becomes a property of the build.

| Art. 30 element | Where it lives in the spec |
|---|---|
| Categories of personal data | `pii` tags + classifications |
| Purpose / lawful basis | schema/field `note`s + consent map |
| Recipients | target schemas (`sf_contact`, `sf_asset` → Salesforce) |
| Retention | `retention` metadata |
| Safeguards | `mask`, `encrypt` metadata |
| Minimisation evidence | absence of lineage on `GEB_DATUM` |

---

## 9. What this document contributes to the spec

- `compliance {GDPR}`, `classification`, `retention` on the schemas.
- `pii`, `mask partial_email`, `encrypt AES-256-GCM` on PII fields.
- The consent-inversion `map { }` and its DPO rationale comment.
- The **non-migration of `GEB_DATUM`** — provable via field-lineage.

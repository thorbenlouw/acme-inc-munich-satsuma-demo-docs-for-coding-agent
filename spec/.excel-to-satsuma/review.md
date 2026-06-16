# Review — Customer 360 Satsuma spec

Generated from `Customer_Migration_Mapping_v17_FINAL_(2).xlsx`. Workspace entry:
`customer360.stm`. `satsuma validate` / `lint` / `fmt --check` all clean across 7 files.

## Critique checklist

| Category | Check | Result | Notes |
| --- | --- | --- | --- |
| Coverage | Every real mapping row has an arrow | PASS | Filler (RESERVE/FILLER/KENNZ/ARTIKEL+) intentionally excluded; documented in discovery report. |
| Coverage | Source fields declared in source schemas | PASS | KUNDEN incl. deliberately-dropped fields (GEB_DATUM, IBAN/BIC, TELEFAX) carried for governance intent. |
| Coverage | Target fields declared | PASS | Account/Contact/Opportunity/Asset modelled. |
| Coverage | Target fields mapped | PASS* | Contact covered by union of `kunden_to_contact` + `ansprechpartner_to_contact`. Account.Payment_Status__c via `billing_to_account`. `Opportunity.Name` has no source → `//?`. |
| Coverage | Lookup tabs → `map { }` | PASS | salutation, country ISO, order status, dunning → named transforms. |
| Types | Source/target types match Excel | PASS | CHAR/VARCHAR/DECIMAL/DATE/TIMESTAMP preserved; SF custom fields typed. |
| Transforms | Logic matches Excel | PASS | Consent inversion, NAME1/VKZ split, email cleanse, E.164, crosswalk all captured. |
| Transforms | Value maps cover lookup codes | PASS* | Known codes mapped; unresolved codes (ANREDE 'X', STATUS_KZ 77/88, blank) kept as `//?` rather than guessed. |
| Transforms | Complex transforms use NL, not invented fns | PASS | NL strings with `@ref` for joins, crosswalk, concatenation, status derivation. |
| Idiom | Repeated patterns shared | PASS | 7 reusable transforms in `lookups.stm`; salutation/email/phone/consent reused across KUNDEN + ANSPRECHPARTNER. |
| Idiom | Multi-file imports | PASS | `salesforce.stm` + `lookups.stm` imported selectively; `customer360.stm` entry. |
| Documentation | DQ warnings as `//!` | PASS | 5 `//!` (consent ×2, DM currency, KD-REF orphans). |
| Documentation | Ambiguities as `//?` | PASS | 16 `//?` tracing the 'Offene Punkte' tab. |
| Structure | Parse clean | PASS | `satsuma validate`: 0 errors. |
| Structure | No orphaned target schemas | PASS | Removed read-only `Contact.Name`; every schema participates in ≥1 mapping. |
| Governance | PII tagged | PASS | 45 `pii`-tagged fields; ACME convention satisfied. |
| Governance | PII schemas carry `retention` | PASS | All source + target schemas have `retention` meta. |
| Governance | Schemas have `note` | PASS | Every schema documented. |

## Confidence

| Dimension | Rating |
| --- | --- |
| Structural coverage | High |
| Transform accuracy | High |
| Type fidelity | High |
| Ambiguity level | 16 `//?` markers (mirrors the workbook's open points) |
| Fragment / transform reuse | High |
| Critique result | Clean (0 validate, 0 lint) |
| Exit condition | CLEAN |

## Deliberate decisions (not defects)

- **Filler excluded.** ~160 KUNDEN RESERVE_/FILLER_/KENNZ_ columns, 130 AUFTRAEGE
  "ARTIKEL+" placeholder groups, and ANSPRECHPARTNER RESERVE_/NOTIZ are noise around
  the real fields — excluded, recorded in the discovery report.
- **Unresolved tables as stubs.** `kunden_adr` (1:n addresses), `auftrag_pos` (1:n line
  items), and the half-finished billing model are kept as documented `//?` stubs.
- **Unknown codes not guessed.** ANREDE 'X'/blank, STATUS_KZ 77/88, 'EU' country, and
  UMSATZ_KZ meaning are left as `//?` — defaulting them would hide governance decisions.
- **Governance preserved.** Consent inversion `//!` flagged; data-minimisation drops
  (GEB_DATUM, IBAN/BIC, deleted rows) modelled as no-migrate with reasons; billing
  orphans routed to remediation, never dropped.

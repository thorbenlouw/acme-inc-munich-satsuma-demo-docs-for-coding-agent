# Discovery Report — Customer_Migration_Mapping_v17_FINAL_(2).xlsx

Source-to-target mapping for the Acme "Customer 360" migration:
**ATLAS PostgreSQL + Billing REST API → Salesforce**. Author: S. Keller (extern),
stand 14.03.2025. The workbook is mid-flight working material — lots of open
questions, dropped legacy columns, and deliberately tricky business rules.

## Tab classification

| Tab | Classification | Confidence | Rows | Notes |
| --- | --- | --- | --- | --- |
| Mapping KUNDEN | Mapping | high | 214 | KUNDEN → Account/Contact. Also embeds KUNDEN_ADR (1:n, unresolved), KUNDEN_HIST (not migrated), and an ANREDE value list. |
| Mapping ANSPRECHP. | Mapping | high | 54 | ANSPRECHPARTNER → Contact. |
| Mapping AUFTRAEGE | Mapping | high | 1078 | AUFTRAEGE → Opportunity; AUFTRAG_POS (unresolved 1:n); rows 31–1078 are "ARTIKEL+" placeholders "noch nicht gesichtet" (not yet reviewed) — **filler, excluded**. |
| Billing_API_NEU | Mapping (prose / nested JSON) | high | 24 | Billing REST API `GET /v2/customers/{id}` → Asset. Nested `subscriptions[]` list. Half-finished (laptop wiped). |
| Wertelisten | Reference/Lookup | high | 21 | ANREDE, LAND, STATUS_KZ lookups. BRANCHE (84 codes) is in a missing external file. |
| Offene Punkte | Guidance/Open issues | high | 16 | 15 open governance/scope questions — captured as a workspace `note` + `//?`. |

## Column roles (mapping tabs — header on row 4)

| Col | Header | Role |
| --- | --- | --- |
| A | Nr. | row number (ignored) |
| B | Quelle Tabelle | source table |
| C | Quelle Feld | source field |
| D | Typ | source type (INT, CHAR(n), VARCHAR(n), DECIMAL(p,s), DATE, TIMESTAMP) |
| E | Pflicht | required (ja/nein) |
| F | Ziel Objekt (Salesforce) | target object (Account / Contact / Opportunity / Asset / — = drop) |
| G | Ziel Feld | target field |
| H | Transformation / Regel | transform rule (NL, German) |
| I | PII (DSGVO) | PII flag (ja / nein / JA!! / evtl. / z.T.) |
| J | Status | erledigt / in Klärung / offen / KLÄREN!!! / warten auf IT |
| K | Verantwortl. | owner |
| L | Bemerkung | comment |
| M | geklärt am | clarified-on date |

## Formatting semantics (legend from row 1)

- **GELB / yellow** (`#FFF2A8`) = offen (open)
- **GRÜN / green** (`#C6EFCE`) = fertig (done)
- **ROT / red** (`#FFC7CE`) = kritisch (critical)
- **Orange** (`#FFD8A8`) = ??? (unclear)
- **strikethrough** (65 cells) = dropped/deprecated fields

Colour is advisory only; the authoritative signal is the **Status** column,
which we carry into Satsuma metadata + `//?` markers.

## Real (non-filler) field mappings

- **KUNDEN** (rows 1–36): ~30 real fields. Drops: NAME3, VKZ (control field),
  POSTFACH, TELEFAX, GEB_DATUM (data minimisation), IBAN/BIC (security), GELOESCHT_KZ
  (filter). RESERVE_/FILLER_/KENNZ_ columns (37–199) = filler, excluded.
- **KUNDEN_ADR** (69–78): 1:n delivery addresses — data-model unresolved → `//?`.
- **KUNDEN_HIST** (87–93): not migrated (CSV archive, 7-yr retention).
- **ANSPRECHPARTNER** (1–14): ~13 real fields. GEBURTSTAG dropped (minimisation).
  RESERVE_/NOTIZ (15–49) = filler.
- **AUFTRAEGE** (1–10): 10 real fields → Opportunity. KOND_ (11–22) filler.
- **AUFTRAG_POS** (23–30): unresolved 1:n line items → `//?`.
- **Billing API**: customer_ref, payment_status, subscriptions[] → Asset (1 per
  subscription via `each`).

## High-risk business rules to preserve (not smooth away)

1. **Consent inversion** — WERBUNG_OK / NEWSLETTER_KZ: `J → false`, `N → true`,
   `leer → true` (= opt-out). Built wrong twice. Flag loudly.
2. **PII governance** — email/phone/notes/birthdate are PII; GEB_DATUM and
   GEBURTSTAG deliberately **not** migrated (no purpose / data minimisation);
   IBAN/BIC stay out of CRM (security); NOTIZ1–5 need DSGVO screening (health data found).
3. **KD-REF crosswalk** — Billing `customer_ref` ("KD-0048113") ↔ KUNDEN.KD_NR;
   ~0.4% orphans route to remediation, never silently dropped.
4. **NAME1 overload** — split by VKZ (F=company→Account.Name, P=person→Contact.LastName).
5. **GELOESCHT_KZ <> 'J' filter** (~28k deleted records excluded — Löschkonzept).
6. **Lookups** — salutation (incl. unknown 'X' ×312, blank ×34k), country D/A/CH→ISO,
   order STATUS_KZ (77/88 undocumented), dunning stages.

## Planned output layout

| File | Contents |
| --- | --- |
| `salesforce.stm` | Target schemas — `sf::account`, `sf::contact`, `sf::opportunity`, `sf::asset` |
| `lookups.stm` | Shared named transforms (salutation, country, order status, dunning, email cleanse, phone E.164, consent inversion) + value-list notes |
| `kunden.stm` | `atlas::kunden` (+ adr/hist) → Account/Contact mapping |
| `ansprechpartner.stm` | `atlas::ansprechpartner` → Contact mapping |
| `auftraege.stm` | `atlas::auftraege` (+ auftrag_pos) → Opportunity mapping |
| `billing.stm` | `billing::customer` (nested subscriptions) → Asset mapping (`each`) |
| `customer360.stm` | Entry file: scenario `note` + open-points + imports of all mappings |

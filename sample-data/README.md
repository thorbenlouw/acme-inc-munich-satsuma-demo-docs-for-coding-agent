# Sample Data for Satsuma Migration

This directory contains realistic sample data for testing the ATLAS → Salesforce migration pipelines.

## Files

### `atlas_kunden.csv`
Source data from ATLAS Postgres KUNDEN table (12 rows).

**Edge cases covered:**
- **ANREDE = 'X'** (rows 100004, 100009): 2003 couples campaign — maps to "Familie"
- **ANREDE = NULL** (row 100006): Defaults to "Divers" in mapping
- **VKZ = 'F'** (company, rows 100001, 100006, 100010): Filtered out in kunden→contact mapping
- **VKZ = 'P'** (person): Main mapping targets
- **EMAIL with trailing semicolon** (rows 100002, 100008, 100012): 2011 import artifact; mapping strips and validates
- **Various TELEFON formats** (rows 100001, 100003, 100004, 100009, 100011): 5 different formats to test to_e164 handling
  - E.164: `+49 89 123 4567`
  - Spaces with slash: `089/12 34 56-0`
  - Parentheses: `+49 (89) 9876543`
  - Dashes: `+49-89-445566-77`
  - No separators: `08912345678`, `089-123-456`
- **GEB_DATUM = NULL** (rows 100001, 100006, 100010): Non-person types
- **WERBUNG_OK variations** (J, N, NULL): Tests consent mapping (N/NULL = opted OUT)
- **Salutation diversity**: H, F, D, X, NULL across all rows

### `billing_api_customer.json`
Sample responses from billing platform `/v2/customers/{id}` endpoint (9 customers).

**Edge cases covered:**
- **Payment statuses**: "ok", "dunning_1", "dunning_2", "legal" (all 4 enum values)
- **Multiple subscriptions** (rows 100001, 100004): Tests Asset creation per subscription
- **Cancelled subscriptions** (rows 100004, 100006): `cancelled_on` != null — maps to Status = "Cancelled"
- **Active subscriptions** (most rows): `cancelled_on` = null — maps to Status = "Active"
- **Long contract histories** (row 100004): Lifecycle change 2024-06-30 → 2024-07-01
- **Different product codes**: SaaS-Basic, SaaS-Pro, SaaS-Enterprise, Support-Prem
- **MRR variance**: 500 EUR to 5000 EUR to test decimal precision

## Usage

### Testing the `kunden_to_contact` mapping:
```bash
# Filter to VKZ = 'P' only; expect 10 rows
grep -v "^100001,\|^100006,\|^100010," atlas_kunden.csv
```

Expect:
- 10 contacts with mapped EMAIL (stripped semicolons), TELEFON (to E.164), ANREDE → Salutation
- EMAIL validation on rows with trailing `;` should succeed after strip
- ANREDE = 'X' should map to "Familie"
- ~2% of phone numbers (1–2 rows) may require manual remediation if to_e164 fails

### Testing the `billing_to_assets` mapping:
Use `billing_api_customer.json` with the KD-REF crosswalk (customer_ref → KD_NR):
- Expect 9 Assets for active subscriptions
- Expect 2 Assets with Status = "Cancelled" (rows 100004 (old), 100006)
- Verify MRR__c is CURRENCY(10,2) and EUR-only
- Verify orphans are not present (all customer_ref values have ATLAS KD_NR matches)

## Data Generation Notes

- **GEB_DATUM**: PII marked RESTRICTED. Dates are fictitious and used for testing GDPR handling only.
- **EMAIL**: Semicolons present in rows 100002, 100008, 100012 simulate the 2011 import artifact (~4.1% in prod).
- **TELEFON**: Formats selected from the 19 observed formats in production.
- **VKZ**: Deliberately includes both F and P to test filtering.
- **ANREDE = 'X'**: Confirmed mapping via 2026-06-19 workshop; previously undocumented.

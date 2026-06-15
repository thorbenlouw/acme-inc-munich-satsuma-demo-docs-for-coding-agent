Add mappings

```satsuma
schema atlas_kunden (
  owner "sales-it",
  classification "CONFIDENTIAL",
  compliance {GDPR},
  note "ATLAS Postgres, table KUNDEN. System of record since 1998.
        331,408 rows. Customer numbers have gaps from the 2009 archive purge."
) {
  KD_NR        INT          (pk, required)
  ANREDE       CHAR(1)      (enum {H, F, D, X})
    //! 'X' appears in 312 rows and is documented nowhere
    //? What does ANREDE = 'X' mean? Spreadsheet v17 row 214 says "ask Gerhard"
  NAME1        VARCHAR(60)  (pii, note "Company name OR surname — overloaded, see VKZ")
  NAME2        VARCHAR(60)  (pii)
  VKZ          CHAR(1)      (enum {F, P}, note "F = Firma (company), P = Privat (person)")
  EMAIL        VARCHAR(120) (pii)
    //! 4.1% of values fail RFC 5322 — mostly trailing semicolons from a 2011 import
  TELEFON      VARCHAR(40)  (pii, note "Free text. 19 observed formats incl. '089/12 34 56-0'")
  GEB_DATUM    DATE         (pii, classification "RESTRICTED")
    //? Why does a B2B sales system hold dates of birth? Purpose unclear — GDPR Art. 5(1)(c)
  WERBUNG_OK   CHAR(1)      (enum {J, N}, note "Marketing consent flag — J/N, default N")
  ANGELEGT_AM  TIMESTAMP    (required)
}

schema sf_contact (
  owner "crm-platform",
  steward "sabine.keller@acme.example",
  compliance {GDPR},
  retention "7y",
  note "Salesforce Contact — Customer 360 target",
  note "Retention: 7 years after account closure, anchored to Account close date.
        Email override: erasure within 30 days of Art. 17 request."
) {
  Email STRING(80) (pii, format email, mask partial_email, encrypt AES-256-GCM)
  FirstName   STRING(40)
  LastName    STRING(80)   (required)
  Salutation  PICKLIST     (enum {Herr, Frau, Divers, Familie})
  Phone       STRING(40)   (pii, note "E.164")
  HasOptedOutOfEmail BOOLEAN (required)
}

mapping `kunden_to_contact` {
  source {
    atlas_kunden (filter "VKZ = 'P'")
    "Only natural persons become Contacts; VKZ = 'F' rows feed the Account mapping."
  }
  target { sf_contact }

  ANREDE -> Salutation {
    map {
      H: "Herr"
      F: "Frau"
      D: "Divers"
      X: "Familie"   // 2003 couples campaign — confirmed by sales ops, 2026-06-19 workshop
      null: "Divers"
    }
  }

  EMAIL -> Email { trim | lowercase | "strip trailing semicolons (2011 import artifact)" | validate_email | null_if_invalid }

  TELEFON -> Phone { to_e164 }  //! 19 source formats; expect ~2% manual remediation queue

  WERBUNG_OK -> HasOptedOutOfEmail {
    map { J: false, N: true, null: true }
    // GDPR: absence of consent means opted OUT. Inversion is deliberate — reviewed by DPO.
  }
}


schema billing_api_customer (note "GET /v2/customers/{id} — billing platform") {
  customer_ref   STRING(20)  (required)
  payment_status STRING(12)  (enum {ok, dunning_1, dunning_2, legal})
  subscriptions list_of record {
    contract_no  STRING(15)  (pk)
    product_code STRING(10)
    mrr_eur      DECIMAL(10,2)
    started_on   DATE
    cancelled_on DATE        (note "null while active")
  }
}

schema sf_asset (
  owner "crm-platform",
  steward "sabine.keller@acme.example",
  note "Salesforce Asset — one record per billing subscription.
        Custom fields carry the billing-platform contract attributes."
) {
  Id            ID           (pk)
  Name          STRING(255)  (required, note "SF requires Name; derive from product + contract no")
  AccountId     ID           (ref sf_account.Id, note "SF requires Account or Contact parent")
    //? Account mapping (VKZ = 'F') not in this file yet — where do Assets parent to?
  ContactId     ID           (ref sf_contact.Id)
  Product2Id    ID           (note "Lookup to Product2; resolve via Product_Code__c crosswalk")
  SerialNumber  STRING(80)
  Status        PICKLIST     (enum {Active, Cancelled}, note "Org overrides the standard
                              Shipped/Installed/... values with billing lifecycle states")
  PurchaseDate  DATE
  UsageEndDate  DATE         (note "Set from cancelled_on when subscription ends")
  Price         CURRENCY(18,2)
  Quantity      DOUBLE(12,2)
  `Product_Code__c` STRING(10)
  `MRR__c`          CURRENCY(10,2) (note "EUR only; org currency must match billing platform")
}

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
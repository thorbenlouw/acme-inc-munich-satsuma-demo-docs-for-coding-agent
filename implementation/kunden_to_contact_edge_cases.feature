Feature: ATLAS Kunden to Salesforce Contact mapping — edge cases

  Background:
    Given the mapping "kunden_to_contact" is active
    And the source filter "VKZ = 'P'" is applied (only natural persons)
    And the target is sf_contact

  # ANREDE mapping: H/F/D/X -> Herr/Frau/Divers/Familie
  Scenario: Standard ANREDE values map correctly
    Given a kunden row with ANREDE = 'H'
    When mapped to sf_contact
    Then Salutation = "Herr"

  Scenario: ANREDE = 'F' (Frau)
    Given a kunden row with ANREDE = 'F'
    When mapped to sf_contact
    Then Salutation = "Frau"

  Scenario: ANREDE = 'D' (Divers)
    Given a kunden row with ANREDE = 'D'
    When mapped to sf_contact
    Then Salutation = "Divers"

  Scenario: ANREDE = 'X' maps to Familie (2003 couples campaign)
    Given a kunden row with ANREDE = 'X', NAME1 = 'Familie Hoffmann', VKZ = 'P'
    And this mapping was confirmed in the 2026-06-19 workshop by sales ops
    When mapped to sf_contact
    Then Salutation = "Familie"

  Scenario: ANREDE = null defaults to Divers
    Given a kunden row with ANREDE = null
    When mapped to sf_contact
    Then Salutation = "Divers"

  # EMAIL mapping: trim | lowercase | strip trailing semicolons | validate | null_if_invalid
  Scenario: Valid email is normalized
    Given a kunden row with EMAIL = '  John.Doe@EXAMPLE.DE  '
    When mapped to sf_contact
    Then Email = 'john.doe@example.de'
    And Email has format email constraint

  Scenario: Email with trailing semicolon (2011 import artifact) is cleaned
    Given a kunden row with EMAIL = 's.krueger@arcor.de;'
    And this is documented as a 2011 import artifact affecting ~4.1% of records
    When mapped to sf_contact
    Then Email = 's.krueger@arcor.de'
    And validation passes

  Scenario: Email that fails RFC 5322 becomes null
    Given a kunden row with EMAIL = 'juergen.wagner@'
    When mapped to sf_contact
    Then Email = null

  Scenario: Null email stays null
    Given a kunden row with EMAIL = null
    When mapped to sf_contact
    Then Email = null

  # TELEFON mapping: to_e164
  Scenario: Standard formatted phone (089/12 34 56-0) converts to E.164
    Given a kunden row with TELEFON = '089/12 34 56-0'
    When mapped to sf_contact
    Then Phone matches E.164 format
    And Phone = '+498912345600' (or similar valid E.164)

  Scenario: Phone with +49 prefix converts correctly
    Given a kunden row with TELEFON = '+49 89 552014'
    When mapped to sf_contact
    Then Phone = '+498955201400' (or similar valid E.164)

  Scenario: Mobile format (0171-9988776) converts to E.164
    Given a kunden row with TELEFON = '0171-9988776'
    When mapped to sf_contact
    Then Phone matches E.164 format

  Scenario: Phone format with parentheses (+49 (0)89 / 76 54 32) converts
    Given a kunden row with TELEFON = '+49 (0)89 / 76 54 32'
    When mapped to sf_contact
    Then Phone matches E.164 format
    And Phone = '+498976543200' (or similar valid E.164)

  Scenario: International format +4915123456789 stays valid
    Given a kunden row with TELEFON = '+4915123456789'
    When mapped to sf_contact
    Then Phone = '+4915123456789'

  Scenario: Invalid/unrecognizable phone format routes to remediation
    Given a kunden row with TELEFON = 'invalid format'
    And the spec warns "expect ~2% manual remediation queue"
    When mapped to sf_contact
    Then Phone is flagged for manual review OR Phone = null

  Scenario: Null phone stays null
    Given a kunden row with TELEFON = null
    When mapped to sf_contact
    Then Phone = null

  # WERBUNG_OK mapping: J/N -> HasOptedOutOfEmail (inverted logic)
  Scenario: WERBUNG_OK = 'J' (consented) -> HasOptedOutOfEmail = false
    Given a kunden row with WERBUNG_OK = 'J'
    And DPO confirms the inversion is deliberate (GDPR Art. 7)
    When mapped to sf_contact
    Then HasOptedOutOfEmail = false
    And field note states "GDPR: absence of consent means opted OUT"

  Scenario: WERBUNG_OK = 'N' (not consented) -> HasOptedOutOfEmail = true
    Given a kunden row with WERBUNG_OK = 'N'
    When mapped to sf_contact
    Then HasOptedOutOfEmail = true

  Scenario: WERBUNG_OK = null defaults to true (opted OUT)
    Given a kunden row with WERBUNG_OK = null
    And the schema specifies "default N" in ATLAS
    When mapped to sf_contact
    Then HasOptedOutOfEmail = true

  # NAME mapping: NAME1 (overloaded F/P) and NAME2
  Scenario: Natural person (VKZ='P'): NAME1 -> LastName, NAME2 -> FirstName
    Given a kunden row with VKZ = 'P', NAME1 = 'Schneider', NAME2 = 'Thomas'
    When mapped to sf_contact
    Then LastName = 'Schneider'
    And FirstName = 'Thomas' (if applicable; mapping does not define FirstName arrow)

  Scenario: Couple entry (VKZ='P', ANREDE='X'): NAME1 = 'Familie X' has no NAME2
    Given a kunden row with VKZ = 'P', ANREDE = 'X', NAME1 = 'Familie Hoffmann', NAME2 = null
    When mapped to sf_contact
    Then LastName = 'Familie Hoffmann'
    And FirstName can be null or empty

  # VKZ filter: only P (Privat) should appear in sf_contact
  Scenario: Company (VKZ='F') is filtered OUT by source condition
    Given a kunden row with VKZ = 'F', NAME1 = 'ACME Logistik GmbH'
    And the mapping source filter is "VKZ = 'P'"
    And the note states "Only natural persons become Contacts; VKZ='F' rows feed the Account mapping"
    When the mapping runs
    Then this row is NOT included in sf_contact
    And it is instead routed to the (future) Account mapping

  Scenario: Natural person (VKZ='P') is included
    Given a kunden row with VKZ = 'P'
    When the mapping runs
    Then the row is processed and included in sf_contact

  # Data quality edge cases
  Scenario: Incomplete record (multiple nulls)
    Given a kunden row with:
      | KD_NR      | 221051           |
      | ANREDE     | X                |
      | NAME1      | null             |
      | NAME2      | null             |
      | VKZ        | P                |
      | EMAIL      | null             |
      | TELEFON    | null             |
      | WERBUNG_OK | N                |
    When mapped to sf_contact
    Then LastName = null (but SF requires LastName — validation fails OR defaults to KD_NR)
    And Email = null
    And Phone = null
    And HasOptedOutOfEmail = true

  Scenario: Umlaut and special characters in names are preserved
    Given a kunden row with NAME1 = 'Krüger', NAME2 = 'Jürgen'
    When mapped to sf_contact
    Then LastName = 'Krüger'
    And FirstName = 'Jürgen'

  Scenario: Row with GEB_DATUM (date of birth) – not mapped to sf_contact
    Given a kunden row with GEB_DATUM = '1971-03-12' and DPO question "//? Why does B2B system hold DOB?"
    When mapped to sf_contact
    Then GEB_DATUM is NOT mapped to sf_contact (suppressed for GDPR compliance)
    And it remains in audit trail under (classification "RESTRICTED")

  # PII handling
  Scenario: PII fields are tagged and encrypted in transit
    Given a kunden row with EMAIL (pii), TELEFON (pii), NAME1 (pii)
    When mapped to sf_contact
    Then Email field in sf_contact has (encrypt AES-256-GCM)
    And Phone field in sf_contact has (pii) tag
    And encryption key management follows org security policy

  # Completeness
  Scenario: LastName is required in sf_contact
    Given a kunden row with NAME1 = null
    When mapped to sf_contact
    Then validation fails OR row routes to data remediation queue
    And error message cites sf_contact.LastName (required)

-- Phase 3, Part A: tag-driven masking and row filtering (ABAC policies).
-- Policies attach ON CATALOG prod_commerce, so silver and gold inherit them when Phase 4
-- creates them. Everyone is masked EXCEPT commerce_data_owners (documented break-glass).
--
-- UI prerequisites (as the primary), each value added ONE PER ENTRY:
--   * Governed tag `filter_key`, allowed value: region            -> page shows "1 value"
--   * Account group `analyst_eu` (Admin access OFF). Groups carry NO description field
--     (Group Information shows only ID and Name), so the name has to carry the meaning and
--     the runbook is the registry: `analyst` grants access, `analyst_eu` narrows it to EU rows.
--
-- Limits that shape this design:
--   * Only ONE mask may resolve per column per user - two matching policies block access
--     instead of choosing, so every policy below matches a DISJOINT pii_type.
--   * Time travel and cloning fail on tables carrying ABAC policies (note it in the runbook).

-- 1. Mark the row-filter column with the governed tag
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN region SET TAGS ('filter_key' = 'region');

-- 2. Masking + filter functions (governance schema: policy logic lives apart from the data).
--    Simple, deterministic, built-in functions only - per Databricks' UDF guidance.
CREATE OR REPLACE FUNCTION prod_commerce.governance.mask_full(val STRING)
  RETURNS STRING DETERMINISTIC RETURN '***';

CREATE OR REPLACE FUNCTION prod_commerce.governance.mask_email(val STRING)
  RETURNS STRING DETERMINISTIC
  RETURN CASE WHEN val IS NULL OR val = '' THEN val
              ELSE concat(left(val, 1), '***@', split_part(val, '@', 2)) END;

CREATE OR REPLACE FUNCTION prod_commerce.governance.mask_last4(val STRING)
  RETURNS STRING DETERMINISTIC RETURN concat('****', right(val, 4));

-- Deterministic pseudonymization: same input -> same hash, so joins and counts still work.
-- The version argument supports key rotation without rewriting history.
CREATE OR REPLACE FUNCTION prod_commerce.governance.pseudonymize(val STRING, version INT)
  RETURNS STRING DETERMINISTIC RETURN sha2(concat(val, cast(version AS STRING)), 256);

-- Generalization rather than removal: age analysis survives, the identifier does not.
CREATE OR REPLACE FUNCTION prod_commerce.governance.mask_dob(val STRING)
  RETURNS STRING DETERMINISTIC RETURN concat(left(val, 4), '-**-**');

CREATE OR REPLACE FUNCTION prod_commerce.governance.filter_by_region(region STRING, allowed STRING)
  RETURNS BOOLEAN DETERMINISTIC RETURN array_contains(split(allowed, ','), lower(region));

-- 3. Policies. Each matches a different pii_type, so no column gets two masks.
CREATE OR REPLACE POLICY mask_name_address ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_full
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS (has_tag_value('pii_type','name') OR has_tag_value('pii_type','address')) AS m
  ON COLUMN m;

CREATE OR REPLACE POLICY mask_email ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_email
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','email') AS m
  ON COLUMN m;

CREATE OR REPLACE POLICY mask_phone ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_full
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','phone') AS m
  ON COLUMN m;

CREATE OR REPLACE POLICY mask_payment_card ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_last4
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','payment_card') AS m
  ON COLUMN m;

CREATE OR REPLACE POLICY mask_dob ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_dob
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','dob') AS m
  ON COLUMN m;

-- ARGUMENTS (settled Sep 22 2026, two errors deep):
--  (a) CLAUSE ORDER: for a COLUMN MASK, USING COLUMNS goes AFTER ON COLUMN. The reverse fails:
--      [PARSE_SYNTAX_ERROR] Syntax error at or near 'USING'. SQLSTATE: 42601
--  (b) ASYMMETRY between the two policy kinds:
--      COLUMN MASK  - ON COLUMN passes the matched column as the FIRST argument, so
--                     USING COLUMNS lists only the EXTRA arguments -> USING COLUMNS (1).
--                     Passing (m, 1) gives three arguments to a two-argument function:
--                     INVALID_PARAMETER_VALUE "policy definition requires 3 argument(s),
--                     but the referred function 'pseudonymize' takes 2".
--      ROW FILTER   - has no ON COLUMN, so USING COLUMNS lists ALL arguments including the
--                     matched column -> USING COLUMNS (rgn, 'eu').
CREATE OR REPLACE POLICY mask_national_id ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.pseudonymize
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','national_id') AS m
  ON COLUMN m
  USING COLUMNS (1);

-- ---------------------------------------------------------------------------
-- TYPE-SPECIFIC DOB MASK (added Sep 25 2026, after the persona round).
-- A mask function binds to the column TYPE; a tag describes its MEANING. The two disagree
-- the moment a layer changes types, which is what a silver layer is for.
--   bronze.customers.date_of_birth            STRING -> mask_dob      (above)
--   silver.quarantine_customers.date_of_birth STRING -> mask_dob      (above)
--   silver.customers.date_of_birth            DATE   -> mask_dob_date (here)
-- Applying the STRING mask to the DATE column does NOT produce a masked value - it makes the
-- column unreadable: [CAST_INVALID_INPUT] The value '1951-**-**' of the type "STRING" cannot
-- be cast to "DATE" ... SQLSTATE: 22018. A privacy control becomes an availability outage.
-- IT IS INVISIBLE TO THE OWNER, who is EXCEPT-ed from the mask, so every owner-run check in
-- Phase 4 passed while silver.customers could not be read by the analyst persona at all.
--
-- SEQUENCE - three of these four fail if the first has not propagated:
--   1. UI: Catalog > Govern > Governed Tags > pii_type > Add value > `dob_date`  (-> 8 values)
--   2. wait for propagation
--   3. create the function and the policy (below)
--   4. re-tag the column
-- A governed tag validates its allowed values at POLICY-COMPILATION time, not only on
-- SET TAGS: CREATE POLICY with an unlisted value fails with
-- INVALID_PARAMETER_VALUE.UC_INVALID_POLICY_CONDITION: Invalid tag value `dob_date` for key `pii_type`.
CREATE OR REPLACE FUNCTION prod_commerce.governance.mask_dob_date(val DATE)
  RETURNS DATE DETERMINISTIC RETURN make_date(year(val), 1, 1);

CREATE OR REPLACE POLICY mask_dob_date ON CATALOG prod_commerce
  COLUMN MASK prod_commerce.governance.mask_dob_date
  TO `account users` EXCEPT `commerce_data_owners`
  FOR TABLES
  MATCH COLUMNS has_tag_value('pii_type','dob_date') AS m
  ON COLUMN m;

-- SET TAGS replaces pii_type, so mask_dob stops matching this column - which is what keeps
-- the two masks DISJOINT, as ABAC requires (two matching masks block access rather than
-- choosing one).
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN date_of_birth
  SET TAGS ('classification' = 'confidential', 'pii_type' = 'dob_date');

-- The masked value now LOOKS like a real date, where '1951-**-**' was self-evidently
-- redacted. Anyone counting January birthdays against silver gets a wrong answer with no
-- warning, so the description has to say so at the point of use.
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN date_of_birth COMMENT
  'Date of birth as a DATE. Analysts see 1 January of the birth year - a generalization, NOT the real date: the year is accurate, the day and month are not. Age brackets stay usable for segmentation while the exact date, a strong re-identification key when combined with postcode, does not leave this layer.';

-- NOTE the better long-term answer is to not store a maskable date in silver at all
-- (birth_year or an age band), which removes the mask from the read path entirely. Deferred
-- to the anonymization workflow, backlog item 8, as its worked example.

-- ---------------------------------------------------------------------------
-- Row filter: only analyst_eu is filtered; everyone else is unaffected by this policy.
CREATE OR REPLACE POLICY regional_access_eu ON CATALOG prod_commerce
  ROW FILTER prod_commerce.governance.filter_by_region
  TO `analyst_eu`
  FOR TABLES
  MATCH COLUMNS has_tag_value('filter_key','region') AS rgn
  USING COLUMNS (rgn, 'eu');

-- 4. Inventory + after-state
-- SHOW FUNCTIONS IN prod_commerce.governance fails with CROSS_CATALOG_SCHEMA_REFERENCE_NOT_
-- SUPPORTED ("Run 'USE CATALOG prod_commerce' first"). information_schema needs no session
-- state, so scripts should prefer it:
SELECT routine_name FROM prod_commerce.information_schema.routines
WHERE routine_schema = 'governance' ORDER BY routine_name;   -- expect the six functions

-- As the owner: values UNMASKED - CONFIRMED Sep 22 2026 (real names, emails, phones,
-- national IDs, dates and cities), so the EXCEPT break-glass path works
SELECT current_user() AS who, first_name, email, phone, national_id, date_of_birth, city
FROM prod_commerce.bronze.customers LIMIT 5;

SELECT current_user() AS who, card_number FROM prod_commerce.bronze.orders LIMIT 5;

-- Policy inventory - exact syntax unverified; if this errors, look for the Policies tab on
-- the catalog in Catalog Explorer instead.
SHOW POLICIES ON CATALOG prod_commerce;

-- ---------------------------------------------------------------------------
-- PERSONA TEST (run as the test user, in analyst + analyst_eu).
-- analyst grants the read; analyst_eu narrows the rows. Both are needed.
SELECT current_user() AS who,
       is_account_group_member('analyst')    AS in_analyst,
       is_account_group_member('analyst_eu') AS in_analyst_eu;

SELECT current_user() AS who, first_name, email, phone, national_id, date_of_birth, city, region
FROM prod_commerce.silver.customers LIMIT 10;

SELECT current_user() AS who, region, COUNT(*) AS rows_visible
FROM prod_commerce.silver.customers GROUP BY region ORDER BY region;

-- CONFIRMED Sep 22 2026, analyst + analyst_eu:
--   first_name / phone / city -> ***
--   email                     -> r***@hotmail.de   (domain preserved)
--   national_id               -> 64-char SHA-256   (deterministic: joins still work)
--   date_of_birth             -> 1951-**-**        (year preserved)
--   rows                      -> EU only, 1713 rows (owner sees 5000 across NA/EU/LATAM;
--                                1713 is exactly the EU count in the generated data)
-- The masks come from the catalog-level policies; the row filter only from analyst_eu.

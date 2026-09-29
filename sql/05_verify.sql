-- Phase 1, Part E: verification suite. Run after Parts A-D.
-- Every check lists its expected result (as observed on Sep 22 2026) and why it matters.
-- A check that returns "no rows" is only trusted after checks 5-6 prove it can see the
-- columns and can fail.
--
-- THIRD LEG, ADDED Sep 28 2026 - not a correction, an OVERCLAIM created retroactively by a
-- later finding. `information_schema` is PERMISSION-FILTERED (established in Phase 5): it
-- returns only objects the RUNNING IDENTITY can access. So every "0 rows" below means
-- "nothing unclassified THAT I CAN SEE", and "no rows" is indistinguishable from "no
-- visibility". These checks were correct when written and nothing rewrote them when the
-- mechanism was found - which is the failure mode this note exists to stop.
--   * ALL results below were produced by the PRIMARY (catalog owner), Sep 22 2026.
--   * Check 5's hard counts - customers 17, orders 9, 26 tags - ARE the visibility control,
--     but only for a reader who knows whose view they describe. That is what was missing.
--   * Re-running any of this as a narrower identity should return FEWER objects in check 5.
--     If check 5 still reads 26 under a persona, the persona is over-privileged.
-- See 18_state_suite.sql, control A1: a coverage check must assert how many objects it
-- EXPECTED to inspect, so seeing fewer fails loudly instead of passing quietly.

-- 1. Structure: only designed schemas, no auto-created `default`
SHOW SCHEMAS IN prod_commerce;   -- bronze, gold, governance, information_schema, landing, silver
SHOW SCHEMAS IN dev_commerce;    -- same list
SHOW VOLUMES IN prod_commerce.landing;   -- raw_files
-- Upload (UI, volume Overview): 808.98 KB and 1.21 MB = 828,395 and 1,266,368 bytes,
-- byte-identical to the local files.

-- 2. Completeness of ingestion
SELECT 'customers' AS tbl, COUNT(*) AS n_rows FROM prod_commerce.bronze.customers
UNION ALL SELECT 'orders', COUNT(*) FROM prod_commerce.bronze.orders;
-- 5000 / 20000: every source row landed

-- 3. Fidelity: raw values not altered by type inference
SELECT COUNT_IF(postcode LIKE '0%')    AS postcodes_leading_zero,
       COUNT_IF(national_id LIKE '0%') AS ids_leading_zero
FROM prod_commerce.bronze.customers;
-- 409 / 447, equal to the count taken from the local CSV: no leading zero lost

SELECT 'customers' AS tbl, COUNT_IF(_rescued_data IS NOT NULL) AS rescued_rows FROM prod_commerce.bronze.customers
UNION ALL SELECT 'orders', COUNT_IF(_rescued_data IS NOT NULL) FROM prod_commerce.bronze.orders;
-- 0 / 0: every source row fitted the schema

-- 4. Classification and documentation coverage
-- 4a. Columns with no classification tag
SELECT c.table_name, c.column_name
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON  t.schema_name = c.table_schema
  AND t.table_name  = c.table_name
  AND t.column_name = c.column_name
  AND t.tag_name    = 'classification'
WHERE c.table_schema = 'bronze' AND t.tag_name IS NULL;
-- 0 rows

-- 4b. Columns with no description
SELECT table_name, column_name
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'bronze' AND (comment IS NULL OR comment = '');
-- 0 rows

-- 5. Positive control: the checks above really see the columns
SELECT table_name, COUNT(*) AS n_columns
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'bronze'
GROUP BY table_name;
-- customers 17, orders 9 (26 in total)

SELECT tag_name, COUNT(*) AS n_tagged
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'bronze'
GROUP BY tag_name;
-- classification 26 (= every column), pii_type 10 (the personal-data columns)

-- 6. Negative control: check 4a can fail. Remove one tag, re-run 4a, restore.
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment UNSET TAGS ('classification');
-- re-run 4a: exactly one row, customers | segment
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment SET TAGS ('classification' = 'internal');
-- re-run 4a: 0 rows again

-- 7. Governed tag definitions (UI: Catalog > Govern > Governed Tags)
-- classification shows "3 values", pii_type shows "7 values". One combined value such as
-- "internal, confidential, restricted" makes every SET TAGS fail with
-- UC_TAG_POLICY_VALUE_NOT_ALLOWED.

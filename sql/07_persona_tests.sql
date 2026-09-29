-- Phase 2, Part B: persona tests.
-- Run these AS THE SECOND (test) USER, in a private window, one persona at a time.
-- The owner account cannot test grants: an owner sees everything whatever the matrix says.
--
-- Procedure per persona (as the PRIMARY, in the normal window):
--   Settings > Identity and access > Groups > <group> > Add members > the test user.
--   Remove it from the previous group first: one persona at a time, or the results mix.
--   Membership is not instant, AND it reaches each gate at a different time: after adding the
--   test user to data_engineer, the warehouse permission was live (queries ran) while
--   is_account_group_member still said false. Running a round then produces a DENIAL that
--   looks correct but only means the membership had not landed. Re-run test 0 until the flag
--   reads true (sign out and in again if it stays false) before running anything else.

-- Practical: give the two browser sessions DIFFERENT THEMES (here: primary = dark,
-- test user = light). The SQL editor looks identical otherwise, and a screenshot then
-- carries no clue which account produced it.
-- 0. Identity and membership (run first in every round; needs no privileges).
-- A DENIAL alone proves nothing: it looks identical whether the persona is correctly denied
-- or its membership has not landed yet. Gate each round on a POSITIVE CONTROL - a permission
-- only that persona has (analyst: SHOW TABLES IN prod_commerce.silver; data_engineer: the
-- dev CREATE TABLE; auditor: SELECT on governance.audit_log) - and treat the flags as a hint.
-- The identity (`who`) is the part that must always be right.
-- STOP RULE: if `who` is not the test user, you are in the wrong browser window. Every
-- result after that point is the owner's and proves nothing (Sep 22 2026: a whole pass ran
-- this way - counts succeeded, the prod UPDATE returned num_affected_rows = 0 instead of
-- PERMISSION_DENIED, and bronze was readable, all because the owner bypasses the matrix).
SELECT current_user() AS who,
       is_account_group_member('data_engineer') AS in_data_engineer,
       is_account_group_member('analyst')       AS in_analyst,
       is_account_group_member('auditor')       AS in_auditor;

-- ---------------------------------------------------------------------------
-- ROUND 1 - no group at all (baseline)
-- CONFIRMED Sep 22 2026: with no group, the test user cannot run SQL at all. SQL Editor
-- refuses before any query is parsed:
--   "No SQL Warehouse available - You do not have an available SQL Warehouse to which this
--    query can be attached. Please go to the 'SQL Warehouses' page to create a SQL Warehouse
--    or contact your administrator."
-- Removing the warehouse's `All workspace users | Can use` default is what produces this.
-- Compute and data are separate gates, and this user is stopped at the first one - so even
-- test 0 above cannot run in this round. Do Round 1 in the UI:
--   * Catalog Explorer lists dev_commerce (account users keep BROWSE there) and NOT
--     prod_commerce (BROWSE revoked); metadata only, no rows.
--   * Opening SQL Editor and running anything fails for lack of warehouse access.
-- Record the exact error text; it is the evidence that compute is governed separately
-- from data.

-- ---------------------------------------------------------------------------
-- ROUND 2 - data_engineer: reads prod, writes nothing in prod, owns dev
SELECT COUNT(*) AS customers FROM prod_commerce.bronze.customers;   -- 5000
SELECT COUNT(*) AS orders    FROM prod_commerce.bronze.orders;      -- 20000
LIST '/Volumes/prod_commerce/landing/raw_files';                    -- both CSVs (READ VOLUME)

-- Write to prod must be refused (MODIFY was never granted). This changes nothing even
-- if it were allowed: the WHERE matches no rows.
UPDATE prod_commerce.bronze.orders SET status = status WHERE 1 = 0;  -- expect PERMISSION_DENIED

-- Dev is theirs: create and drop a scratch table
CREATE TABLE dev_commerce.bronze.tmp_persona_test AS SELECT 1 AS x;  -- expect success
DROP TABLE dev_commerce.bronze.tmp_persona_test;

-- ---------------------------------------------------------------------------
-- ROUND 3 - analyst: curated layers only
-- Persona signature (identity + effect in ONE row; run in both sessions for the contrast):
SELECT current_user() AS who, concat_ws(', ', collect_list(schema_name)) AS visible_schemas
FROM prod_commerce.information_schema.schemata
WHERE schema_name IN ('bronze','silver','gold','landing','governance');
-- owner   -> gold, bronze, governance, silver, landing
-- analyst -> gold, silver          (CONFIRMED Sep 22 2026)
-- data_engineer -> + bronze, landing;  auditor -> ? (record what BROWSE shows)
SELECT current_user() AS who, COUNT(*) AS customers FROM prod_commerce.bronze.customers;
-- CONFIRMED Sep 22 2026, with silver/gold visible (so the membership was active):
--   [INSUFFICIENT_PERMISSIONS] Insufficient privileges:
--   User does not have USE SCHEMA on Schema 'prod_commerce.bronze'. SQLSTATE: 42501
-- Note the denial is at SCHEMA level (USE SCHEMA), not SELECT on the table - and an error
-- carries no identity, so a denial is attributable only via the signature query run just
-- before it in the same tab.
SHOW TABLES IN prod_commerce.silver;                   -- allowed; holds `customers` since Phase 3
SHOW TABLES IN prod_commerce.gold;                     -- allowed; empty until Phase 4
-- Note: the analyst's read path is only fully testable once Phase 4 creates silver/gold
-- tables. Re-run this round then, and again after Phase 3 to see masked values.

-- ---------------------------------------------------------------------------
-- ROUND 4 - auditor: sees what exists and who did what, never the data
-- CONFIRMED Sep 22 2026 (after adding USE CATALOG; BROWSE alone denied everything):
--   signature  -> gold, bronze, governance, silver, landing   (ALL five: BROWSE is catalog-wide
--                 metadata discovery - the auditor sees MORE metadata than the analyst)
--   audit view -> 1344 events                                  (view runs with its owner's rights)
--   bronze     -> INSUFFICIENT_PERMISSIONS: USE SCHEMA on 'prod_commerce.bronze'  (no data at all)
SELECT COUNT(*) FROM prod_commerce.bronze.customers;   -- expect PERMISSION_DENIED
SELECT COUNT(*) AS events FROM prod_commerce.governance.audit_log;  -- > 0 (view, owner's rights)
SELECT event_time, action_name FROM prod_commerce.governance.audit_log
ORDER BY event_time DESC LIMIT 10;                     -- readable
-- In the UI: Catalog Explorer shows prod_commerce's schemas, tables, column descriptions
-- and classification tags (BROWSE), while Sample Data / SELECT stay denied.

-- ---------------------------------------------------------------------------
-- After the rounds: remove the test user from every persona group, so the account
-- carries no standing access between sessions. Group membership is managed in the UI or
-- through SCIM - there is no SQL for account groups (legacy ALTER GROUP covers only
-- workspace-local groups, which Unity Catalog cannot use).
-- CONFIRMED Sep 22 2026: after removal the test user is back to "No SQL Warehouse available",
-- i.e. the Round 1 baseline - a closing control that the removal took effect.

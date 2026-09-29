-- Phase 5, Part C: pipeline EXPECTATIONS - the TRIAGE and OBSERVATION answers to bad data.
-- Run as a member of commerce_data_owners.
--
-- Part A did PREVENTION (CHECK constraints: the write fails, nothing enters). Phase 4 built
-- PRESERVATION (quarantine tables: kept, labelled with a reason). This part does the other
-- two, which only exist inside a pipeline:
--   EXPECT (default)             OBSERVATION - "Invalid records are written to the target"
--   EXPECT ... DROP ROW          TRIAGE      - "Invalid records are dropped before data is written"
--   EXPECT ... FAIL UPDATE       STOP        - "Invalid records prevent the update from succeeding.
--                                              Manual intervention is required before reprocessing."
-- (Quoted from docs.databricks.com/aws/en/ldp/expectations, Sep 28 2026.)
--
-- WHY THIS IS A SEPARATE OBJECT AND NOT A REBUILD OF SILVER
-- The obvious demonstration would be to rebuild silver.orders as a pipeline so expectations
-- have somewhere to live. That was REJECTED. Databricks documents that ABAC policies cannot
-- be applied to views, and for materialized views and streaming tables it describes policies
-- being EVALUATED during a refresh without ever saying they can be ATTACHED:
--   "When a pipeline refreshes a materialized view or streaming table, it evaluates policies
--    using the pipeline owner's or run-as identity."
-- So whether a governed tag on a materialized view attracts a mask is UNKNOWN, and migrating
-- a table that carries real masks and a row filter onto an object type with unconfirmed ABAC
-- support would risk silently losing the protection - the exact failure this POC has now
-- documented five times. **Prove the mechanism on a new object; leave the governed tables
-- alone until Part D answers the question.**
--
-- SAFETY: this target carries NO personal data. Only order_id, order_date, amount, currency
-- and status are selected - deliberately no card_number, no customer_id. If it turns out
-- that masks do not reach this object type, nothing sensitive was ever exposed by finding out.

-- ---------------------------------------------------------------------------
-- HOW TO RUN - TWO PATHS, BOTH WORTH KNOWING
--
-- PATH 1, the UI (Lakeflow declarative pipeline). Verified against the docs Sep 28 2026:
--   1. Sidebar > the plus icon (**New**) > **ETL Pipeline**. The pipeline editor opens with
--      a default name.
--   2. Set the **Pipeline Name**, then use the **Catalog & Schema** dropdowns to the right of
--      the name to set the defaults (here: prod_commerce / silver).
--   3. In the `my_transformation` file, set the language dropdown to **SQL** and paste the
--      CREATE OR REFRESH statement below. (**Use sample code** populates starter code if you
--      want to see the shape first.)
--   4. **Run pipeline** runs everything; **Run file** runs only the current source file.
--   5. Results: the **pipeline graph** appears in the right sidebar; the **update summary**
--      at the top of the asset browser; and **expectation results - constraint violations and
--      data-quality metrics - inside the table details in the BOTTOM pane**, per table.
--   This path is what a data engineer actually operates, and it is the only one that shows
--   per-expectation pass/fail counts without writing a query.
--
-- PATH 2, the SQL editor. **CONFIRMED WORKING Sep 28 2026** - the statement below ran with
-- "The operation was successfully executed." So `CONSTRAINT ... EXPECT` is NOT pipeline-only;
-- a materialized view declared in plain SQL accepts expectations, and Databricks creates the
-- backing pipeline itself. Faster to demonstrate, reproducible in a script, and reviewable in
-- a repo - but it hides the machinery, which section 3 shows is the point worth not hiding.

-- ---------------------------------------------------------------------------
-- 1. THE THREE BEHAVIOURS, ON ONE OBJECT
-- Each rule is deliberately calibrated against the known defect counts in bronze.orders, so
-- the numbers can be predicted before the run rather than explained after it.
CREATE OR REFRESH MATERIALIZED VIEW prod_commerce.silver.orders_quality_demo(
  -- OBSERVATION. Roughly 57 orders carry a negative amount. They will LAND in the target and
  -- be counted as failures. The business use: measure a problem before deciding to act on it,
  -- so the size of the fix is known before anyone is asked to approve one.
  CONSTRAINT amount_non_negative EXPECT (amount >= 0),

  -- TRIAGE. An unrecognised status makes a row uncountable for revenue, so it is dropped
  -- rather than published - but the pipeline continues, because one bad row is not a reason
  -- to stop a nightly load. Expect 0 drops: the vocabulary was verified against the data.
  CONSTRAINT status_known EXPECT (status IN ('completed','refunded','cancelled')) ON VIOLATION DROP ROW,

  -- STOP. An order with no identifier is not a data-quality problem, it is evidence the
  -- ingestion itself is broken, and continuing would write a target nobody can reconcile.
  -- Expect 0 violations, so the pipeline should complete - this rule is here to be DECLARED,
  -- and Part D tests it by seeding a violation deliberately.
  CONSTRAINT order_id_present EXPECT (order_id IS NOT NULL) ON VIOLATION FAIL UPDATE
)
COMMENT 'Demonstration of pipeline data-quality expectations over bronze.orders. Carries NO personal data by design - no customer identifier, no payment card - because it exists to test whether governance controls reach pipeline-managed objects, and that question must be answered without exposing anything. Not a production table.'
AS SELECT
     order_id,
     try_cast(order_date AS DATE)      AS order_date,
     try_cast(amount AS DECIMAL(12,2)) AS amount,
     upper(trim(currency))             AS currency,
     lower(trim(status))               AS status
   FROM prod_commerce.bronze.orders;

-- ---------------------------------------------------------------------------
-- 2. WHAT LANDED. The observation rule keeps its bad rows, so they are countable here.
SELECT COUNT(*) AS rows_in_target FROM prod_commerce.silver.orders_quality_demo;
-- expect 20000 minus any DROP ROW violations. With status_known dropping 0, expect 20000 -
-- note this is MORE than silver.orders (19,565), because this object applies no referential
-- or date rules and keeps the negative amounts.

SELECT COUNT_IF(amount < 0) AS negative_amounts_retained
FROM prod_commerce.silver.orders_quality_demo;
-- expect ~57. These are the rows the OBSERVATION rule flagged and deliberately KEPT - the
-- difference between "we measured it" and "we stopped it", visible as data.

-- ---------------------------------------------------------------------------
-- 3. WHERE THE METRICS LIVE - and this is the part that differs from every other control here.
-- Expectation results are NOT in information_schema and NOT in table properties. They are
-- reported in the pipeline UI's "Data quality" tab and in the pipeline EVENT LOG. So this is
-- a FOURTH storage location for governance-relevant metadata, after information_schema
-- (tags, comments), table properties (constraints) and system.access.audit (access).
-- UI: open the pipeline > Data quality tab > per-expectation pass/fail counts per run.
-- Record the exact event-log query that works here; the docs say "Query the event log to
-- view expectation metrics" without one form that applies to every pipeline type.

-- ---------------------------------------------------------------------------
-- 4. THE GOVERNANCE QUESTION THIS SETS UP (Part D)
-- The object now exists as a materialized view inside a catalog carrying seven ABAC policies.
-- Part D asks whether governed tags can be applied to it at all, and whether a mask attracted
-- by a tag actually resolves on it. Do NOT add a personal-data column here to find out - Part
-- D runs that test in prod_commerce.governance, the one schema no persona can read.
SELECT table_name, table_type
FROM prod_commerce.information_schema.tables
WHERE table_schema = 'silver' ORDER BY table_name;
-- CONFIRMED Sep 28 2026 - and the result is a finding in its own right. ONE statement
-- created THREE objects in a governed schema:
--   orders_quality_demo                                    MATERIALIZED_VIEW
--   __materialization_mat_<id>_orders_quality_demo_1       MANAGED   <- backing table
--   event_log_<id>                                         MANAGED   <- pipeline event log
-- Neither of the last two was declared, named or chosen. **CORRECTED TWICE Sep 28 2026 -
-- read both corrections, the sequence is the lesson.**
--   (i) The alarming half - "these are analyst-readable" - was WRONG. There was no exposure.
--   (ii) The first correction was ALSO wrong, and in a way worth naming: it attributed the
--        PERMISSION_DENIED to the CATALOG OWNER. It was the ANALYST's denial, read off a
--        light-themed screenshot as if it were the owner's. Re-verified the same day with a
--        positive control, both identities, one variable:
--            OWNER   (dark)  - information_schema.columns: 7 tables, both platform objects
--                              DESCRIBE TABLE on event_log: SUCCEEDS, 10 columns
--            ANALYST (light) - information_schema.columns: 5 tables
--                              DESCRIBE TABLE on event_log: PERMISSION_DENIED
-- So these objects are NOT locked down beyond their owner. The owner can inspect them and
-- (Sep 28) drop them. What is true is the permission FILTERING: the analyst sees neither the
-- objects nor their columns, which is why a coverage check silently narrows to whatever the
-- running identity can see. There is no owner-can-destroy-but-not-inspect asymmetry; that
-- hypothesis came from this line and dies with it.
--
-- What survives: **one statement creates objects you did not declare.** What does not: any
-- claim that they are readable. `information_schema` is permission-filtered, which is
-- also why the coverage check below stops listing them once
-- the owner loses SELECT, without anything reporting that it stopped.
--
-- THE STANDING CHECK CAUGHT IT, unprompted - 21 unclassified columns across the three:
SELECT c.table_name, COUNT(*) AS unclassified_columns
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON t.schema_name = c.table_schema AND t.table_name = c.table_name
 AND t.column_name = c.column_name AND t.tag_name = 'classification'
WHERE c.table_schema = 'silver' AND t.tag_name IS NULL
GROUP BY c.table_name ORDER BY c.table_name;
-- CONFIRMED at the time: __materialization_... 6, event_log_... 10, orders_quality_demo 5.
-- First time in this POC a standing control surfaced something before anyone looked for it -
-- the argument for schema-wide checks over per-table ones, since a per-table check can only
-- cover tables somebody thought to list.
--
-- **BUT RE-RUN IT AND THE TWO PLATFORM TABLES ARE GONE FROM THE RESULT** while still present
-- in information_schema.TABLES. `information_schema` is PERMISSION-FILTERED - you see only
-- objects you can access - so this check reports what the RUNNING IDENTITY can see, and
-- "no unclassified columns" is indistinguishable from "you cannot see them". A coverage
-- check needs a VISIBILITY POSITIVE CONTROL: assert how many objects it expected to inspect,
-- so seeing fewer fails instead of passing more quietly.

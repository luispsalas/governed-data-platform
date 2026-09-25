-- Phase 4, Part B: silver -> gold (business aggregates) and lineage verification.
-- Run as a member of commerce_data_owners, for the reason given in Part A: a masked
-- identity would aggregate masked values and store the result.
SELECT current_user() AS who,
       is_account_group_member('commerce_data_owners') AS may_read_unmasked;

-- ---------------------------------------------------------------------------
-- WHAT GOLD IS FOR, IN GOVERNANCE TERMS
-- Silver holds one row per person and is protected by masking every sensitive column.
-- Gold holds no person at all: it answers business questions about GROUPS. That changes
-- the control that matters. Masks stop being the protection (there is nothing to mask) and
-- GROUP SIZE becomes the protection - because an aggregate over one customer is that
-- the data of that one customer wearing a different hat. Small groups are suppressed below.
--
-- Two rules the layer enforces, both business decisions rather than platform mechanics:
--   * Revenue counts COMPLETED orders only. Applied here, once, so every
--     report that reads gold uses the same definition of revenue.
--   * Amounts are NOT converted between currencies. Reporting per currency is honest;
--     summing across them with a made-up rate is not.

-- ---------------------------------------------------------------------------
-- 1. Revenue by region, month and currency.
-- FIRST: read the vocabulary out of the data. The status values were ASSUMED on the first
-- attempt (placed/shipped/delivered/cancelled/returned) and every one of those but cancelled
-- was invented, so the revenue filter matched 0 rows. Never write a business rule against a
-- categorical column without listing its values.
SELECT status, COUNT(*) AS n_orders,
       ROUND(COUNT(*) / (SELECT COUNT(*) FROM prod_commerce.silver.orders), 4) AS share
FROM prod_commerce.silver.orders GROUP BY status ORDER BY n_orders DESC;
-- expect: completed ~0.90, refunded ~0.06, cancelled ~0.04
SELECT DISTINCT currency FROM prod_commerce.silver.orders ORDER BY currency;
SELECT DISTINCT segment  FROM prod_commerce.silver.customers ORDER BY segment;

CREATE TABLE prod_commerce.gold.revenue_by_region_month
COMMENT 'Monthly revenue and order volume by sales region and currency, counting completed orders only (refunded and cancelled are excluded). Contains no personal data: every row describes a group, and groups of fewer than 5 distinct customers are suppressed so an aggregate cannot identify an individual. Amounts are never converted between currencies. Source: silver.orders joined to silver.customers.'
AS
SELECT c.region,
       date_trunc('MONTH', o.order_date)  AS order_month,
       o.currency,
       COUNT(*)                           AS orders,
       COUNT(DISTINCT o.customer_id)      AS customers_active,
       SUM(o.amount)                      AS revenue,
       ROUND(AVG(o.amount), 2)            AS avg_order_value,
       current_timestamp()                AS _gold_built_at
FROM prod_commerce.silver.orders o
JOIN prod_commerce.silver.customers c ON c.customer_id = o.customer_id
WHERE o.status = 'completed'                     -- the agreed definition of revenue
GROUP BY c.region, date_trunc('MONTH', o.order_date), o.currency
HAVING COUNT(DISTINCT o.customer_id) >= 5;       -- k-anonymity: no group small enough to identify anyone

-- 2. Customer profile by region and segment. Same suppression rule.
CREATE TABLE prod_commerce.gold.customer_segment_profile
COMMENT 'Customer counts and marketing-consent rates by sales region and segment. Contains no personal data; groups of fewer than 5 customers are suppressed. consent_rate is the share of customers in the group who may lawfully be contacted, and is the number a campaign is sized against. Source: silver.customers.'
AS
SELECT region,
       segment,
       COUNT(*)                                              AS customers,
       COUNT_IF(marketing_consent)                           AS customers_consented,
       ROUND(COUNT_IF(marketing_consent) / COUNT(*), 4)      AS consent_rate,
       ROUND(AVG(datediff(current_date(), date_of_birth) / 365.25), 1) AS avg_age_years,
       current_timestamp()                                   AS _gold_built_at
FROM prod_commerce.silver.customers
GROUP BY region, segment
HAVING COUNT(*) >= 5;

-- 3. What the suppression actually cost. A control that never suppresses anything is not
-- protecting anyone, and one that suppresses most of the data is not reporting anything -
-- so the number belongs in the runbook either way.
SELECT COUNT(*) AS groups_published FROM prod_commerce.gold.revenue_by_region_month;

SELECT COUNT(*) AS groups_before_suppression FROM (
  SELECT c.region, date_trunc('MONTH', o.order_date) AS m, o.currency
  FROM prod_commerce.silver.orders o
  JOIN prod_commerce.silver.customers c ON c.customer_id = o.customer_id
  WHERE o.status = 'completed'
  GROUP BY 1, 2, 3);
-- the difference is the number of groups too small to publish

-- 4. Reconciliation against silver: gold must not invent or lose revenue.
-- READ THIS BEFORE QUOTING THE NUMBER. Both sides sum across currencies, which the currency
-- description explicitly warns against - so these totals are a CHECKSUM, valid only because
-- both sides are computed the same way, and are NOT a revenue figure. Never quote either one
-- as money. A query can be correct as a control and meaningless as a business number.
SELECT (SELECT ROUND(SUM(revenue), 2) FROM prod_commerce.gold.revenue_by_region_month) AS gold_revenue,
       (SELECT ROUND(SUM(amount), 2)  FROM prod_commerce.silver.orders
         WHERE status = 'completed')                                      AS silver_revenue;
-- These will NOT match, and that is correct: the difference is exactly the suppressed
-- groups. Record the gap rather than tuning it away - a suppression control that costs
-- nothing has not been applied.

-- 4b. PROOF OF THE GAP for gold - run BEFORE section 5, then never again. Same as Part A:
-- the two tables exist now, built from masked-sensitive sources, and carry no classification.
-- Gold holds no direct identifiers so nothing is exposed here, but the ROW FILTER is also
-- tag-driven: until region is tagged, a regional analyst sees EVERY region in gold. The
-- aggregate is the way around the row filter, and this is the window in which it is open.
SELECT table_name, COUNT(*) AS tagged_columns
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'gold' GROUP BY table_name;
-- expect no rows

-- Observed Sep 23 2026: 336 groups before suppression, 304 published - 32 withheld (9.5%),
-- costing 6,069.04 of 1,194,802.32 (0.51%). The control bites and is nearly free, which is
-- the pair of numbers to put in front of whoever approves the k threshold.

-- ---------------------------------------------------------------------------
-- 5. RE-TAGGING gold. Same step, same reason: a CTAS arrives with no classification.
-- Gold carries no direct identifiers, so nothing here takes a pii_type and no mask applies.
-- region still takes filter_key: a regional analyst must be restricted in gold exactly as
-- in silver, or the aggregate becomes the way around the row filter.
ALTER TABLE prod_commerce.gold.revenue_by_region_month SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN region           SET TAGS ('classification' = 'internal', 'filter_key' = 'region');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN order_month      SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN currency         SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN orders           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN customers_active SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN revenue          SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN avg_order_value  SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN _gold_built_at   SET TAGS ('classification' = 'internal');

ALTER TABLE prod_commerce.gold.customer_segment_profile SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN region              SET TAGS ('classification' = 'internal', 'filter_key' = 'region');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN segment             SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN customers           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN customers_consented SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN consent_rate        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN avg_age_years       SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN _gold_built_at      SET TAGS ('classification' = 'internal');

-- 6. Descriptions for the MEASURES. The projection rule from Part A survives aggregation:
-- region, currency and segment are bare column references used as GROUP BY keys, so they
-- are direct projections and inherit their silver descriptions. Everything aggregated or
-- derived arrives blank. Gold therefore inherits its DIMENSIONS and must be told about its
-- MEASURES - which is the right division of labour anyway, since a measure carries a
-- business definition (what counts as revenue) that a dimension does not.
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN revenue COMMENT
  'Sum of order amounts in this group, in the currency of the currency column. Completed orders only: refunded orders returned the money and cancelled orders never shipped, so neither is revenue. Not comparable across currencies without conversion.';
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN customers_active COMMENT
  'Distinct customers who placed a counted order in this group. Also the k in the suppression rule: groups below 5 are not published, because an aggregate over a handful of people describes those people.';
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN order_month COMMENT
  'First day of the calendar month the orders were placed in, derived from silver.orders.order_date. Monthly is the finest grain published here; a finer one would shrink the groups and defeat the suppression rule.';
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN consent_rate COMMENT
  'Share of customers in this group who have opted in to marketing contact, between 0 and 1. The number a campaign is sized against: reach is the customer count multiplied by this, never the customer count alone.';
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN avg_age_years COMMENT
  'Mean age of the group in years, computed from date_of_birth. An average is published where the birth date itself is masked, because a group mean is a property of the group while a birth date identifies a person - this is the generalization that makes age usable for segmentation.';

-- 6b. The measures section 6 left blank.
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN orders COMMENT
  'Count of completed orders in this group. The volume figure beside revenue: the two move together in a healthy month and apart when average order value shifts, which is why both are published rather than revenue alone.';
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN avg_order_value COMMENT
  'Mean value of a completed order in this group, in the currency of the currency column. Revenue divided by orders, published so the split between more orders and bigger orders is visible without recomputing it.';
ALTER TABLE prod_commerce.gold.revenue_by_region_month ALTER COLUMN _gold_built_at COMMENT
  'Timestamp of the gold build that produced this row. Pins any published figure to the run that generated it, so a number in a report can always be traced to the state of the data behind it.';
-- The suppression rule is invisible to a reader unless a column says so: a MISSING
-- region/segment combination means withheld, not empty. Nothing else carries that warning.
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN customers COMMENT
  'Count of customers in this region and segment, from silver.customers. Groups below 5 are not published, so the smallest value that can appear here is 5 - an absent combination means it was suppressed, not that it has no customers.';
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN customers_consented COMMENT
  'Customers in this group who have opted in to marketing contact. The lawful reachable population: a campaign may be sized against this number, never against the customers column.';
ALTER TABLE prod_commerce.gold.customer_segment_profile ALTER COLUMN _gold_built_at COMMENT
  'Timestamp of the gold build that produced this row. Pins any published figure to the run that generated it, so a number in a report can always be traced to the state of the data behind it.';

SELECT table_name, column_name FROM prod_commerce.information_schema.columns
WHERE table_schema = 'gold' AND comment IS NULL ORDER BY table_name, column_name;
-- expect 0 rows  (CONFIRMED Sep 23 2026)

-- 7. Verification
SELECT c.table_name, c.column_name
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON  t.schema_name = c.table_schema AND t.table_name = c.table_name
  AND t.column_name = c.column_name  AND t.tag_name   = 'classification'
WHERE c.table_schema = 'gold' AND t.tag_name IS NULL;
-- expect 0 rows

SELECT table_name, COUNT(*) AS n_columns, COUNT_IF(comment IS NULL) AS undescribed
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'gold' GROUP BY table_name;
-- Observed Sep 23 2026: 3 undescribed per table (revenue_by_region_month: orders,
-- avg_order_value, _gold_built_at; customer_segment_profile: customers,
-- customers_consented, _gold_built_at). NOT the 5 per table a naive reading predicts -
-- region, currency and segment inherited from silver through the GROUP BY.

SELECT * FROM prod_commerce.gold.revenue_by_region_month ORDER BY region, order_month LIMIT 20;
SELECT * FROM prod_commerce.gold.customer_segment_profile ORDER BY region, segment;

-- ---------------------------------------------------------------------------
-- 8. LINEAGE. Unity Catalog captures it automatically from the SQL - nothing above
-- declared a dependency. Shape of the tables first, since scripts should not guess columns:
DESCRIBE TABLE system.access.table_lineage;
DESCRIBE TABLE system.access.column_lineage;

-- 8a. Table lineage into gold: which silver tables feed each gold table.
SELECT DISTINCT source_table_full_name, target_table_full_name
FROM system.access.table_lineage
WHERE target_table_catalog = 'prod_commerce' AND target_table_schema = 'gold'
ORDER BY target_table_full_name, source_table_full_name;
-- expect silver.orders + silver.customers -> revenue_by_region_month
--        silver.customers                -> customer_segment_profile

-- 8b. The whole chain. NOTE what this query HIDES (confirmed Sep 23 2026):
--   * FILE-TO-TABLE lineage has a NULL source table. bronze.customers and bronze.orders
--     came from read_files over a volume, so there is no source TABLE - the volume path is
--     in source_path. Selecting only source_table_full_name drops the landing->bronze edge
--     and makes the chain look like it begins at bronze, which is precisely where a
--     provenance question begins. Coalesce the two.
--   * LINEAGE IS CUMULATIVE, NOT CURRENT. The superseded bronze.customers -> silver.orders
--     edge from the first (defective) build is still here beside the corrected
--     silver.customers -> silver.orders. table_lineage is an append-only history of
--     operations, not a picture of today's dependencies, and nothing marks which rows are
--     stale. "What feeds this table?" needs an event_time filter, and the auditor has to
--     KNOW that - reading it raw returns every answer the table has ever had.
SELECT DISTINCT coalesce(source_table_full_name, concat('FILE: ', source_path)) AS source,
       target_table_full_name, source_type
FROM system.access.table_lineage
WHERE target_table_catalog = 'prod_commerce'
ORDER BY target_table_full_name, source;

-- 8b-ii. Current dependencies only: the most recent write to each target. This is the query
-- an auditor actually wants, and it is not the obvious one.
SELECT target_table_full_name,
       coalesce(source_table_full_name, concat('FILE: ', source_path)) AS source,
       max(event_time) AS last_seen
FROM system.access.table_lineage
WHERE target_table_catalog = 'prod_commerce'
GROUP BY target_table_full_name, source
ORDER BY target_table_full_name, last_seen DESC;
-- Compare with 8b: the superseded bronze.customers -> silver.orders edge carries an OLDER
-- last_seen than silver.customers -> silver.orders. That timestamp is the only thing
-- distinguishing a live dependency from a retired one.

-- 8c. Column lineage - the level that matters for a PII question. This is how you answer
-- "where did this personal data come from, and everywhere it went" without reading any SQL,
-- which is the question a regulator or a deletion request actually asks.
SELECT source_table_full_name, source_column_name,
       target_table_full_name, target_column_name
FROM system.access.column_lineage
WHERE source_table_catalog = 'prod_commerce'
  AND source_column_name IN ('national_id', 'email', 'date_of_birth')
ORDER BY source_column_name, target_table_full_name;
-- Governance point: this traces the PROPAGATION of an identifier. date_of_birth should
-- appear reaching gold.avg_age_years - a derived, non-identifying value - which is exactly
-- the kind of flow a privacy review needs to see and approve rather than discover.

-- 8d. Lineage carries an actor. Redact created_by before publishing anything from here.
-- CONFIRMED Sep 23 2026: entity_type = DBSQL_QUERY for everything built in the SQL editor.
-- The column's OWN comment lists "NOTEBOOK, JOB, PIPELINE, DASHBOARD_V3" and does not
-- mention DBSQL_QUERY - the platform's documentation of its own field is incomplete. Third
-- instance today of the same rule: read a categorical column's values out of the DATA, not
-- out of its description, and that includes vendor documentation.
-- The governance point stands either way: lineage is captured from the SQL regardless of
-- what ran it, but entity_id / entity_run_id only identify a NAMED process. Ad-hoc editor
-- work is traceable as data flow and not as a repeatable, scheduled, reviewable job - which
-- is the argument for running production transformations as jobs, from evidence.
SELECT source_table_full_name, target_table_full_name, event_time
FROM system.access.table_lineage
WHERE target_table_catalog = 'prod_commerce'
ORDER BY event_time DESC LIMIT 20;

-- CAVEAT to record: lineage is captured asynchronously and can take minutes to appear.
-- An empty result right after a build is a wait, not a missing dependency - re-run before
-- concluding anything. (Same class as every propagation delay in this POC.)

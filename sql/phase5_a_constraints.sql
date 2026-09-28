-- Phase 5, Part A: CHECK constraints - the PREVENTION answer to bad data.
-- Run as a member of commerce_data_owners.
--
-- Four mechanisms answer "what do you do with bad data", and they are different BUSINESS
-- decisions rather than a ranking:
--   CHECK constraint         PREVENTION   - the write fails, nothing enters
--   EXPECT ... DROP ROW      TRIAGE       - bad rows dropped, pipeline continues
--   EXPECT (warn)            OBSERVATION  - recorded, nothing dropped
--   quarantine tables        PRESERVATION - kept, labelled with a reason   (built in Phase 4)
-- This script does the first. Phase 5 Part B does the middle two. A real design uses several.
--
-- VERIFIED against docs.databricks.com, Sep 27 2026:
--   * CHECK is genuinely ENFORCED: "When a constraint is violated, the transaction fails with
--     an error." (Contrast Snowflake, which enforces only NOT NULL - a design habit carried
--     across platforms would under-use this.)
--   * PRIMARY KEY / FOREIGN KEY / UNIQUE are "informational only and aren't enforced".
--     We therefore do NOT declare a foreign key for the order->customer rule: an unenforced
--     key is metadata asserting a guarantee nothing provides, which is the single most
--     dangerous pattern this POC has found. It stays a verification query.
--   * A CHECK expression may use "any SQL functions in Spark that always return the same
--     result given the same argument values", excluding user-defined functions, aggregates,
--     window functions and functions returning multiple rows. **So current_date() is NOT
--     allowed**, and "an order date must not be in the future" cannot be a constraint.
--   * Adding a constraint VALIDATES EXISTING ROWS first: "Databricks verifies that all
--     existing rows satisfy the constraint before adding" it.

-- ---------------------------------------------------------------------------
-- RESULT, Sep 27 2026: ALL 10 CONSTRAINTS ADDED CLEANLY. Because Databricks validates
-- existing rows first, that is simultaneously a proof about every row already stored -
-- 4,940 customers, 19,565 orders, 313 gold rows. The two k-anonymity constraints
-- INDEPENDENTLY RE-PROVED the suppression rule the gold build had asserted with a HAVING
-- clause: same claim, two mechanisms, the second evaluated by the engine rather than by the
-- query that wrote the data.
-- Constraints do NOT appear in information_schema - they are table properties
-- (`delta.constraints.<name>`), so every coverage check written against information_schema
-- is structurally blind to them.

-- ---------------------------------------------------------------------------
-- WHY ADDING A CONSTRAINT IS ALSO A TEST
-- Because existing rows are validated first, a successful ADD is simultaneously a proof
-- about every row already in the table. Each statement below that succeeds is an assertion
-- that all 4,940 customers / 19,565 orders / 304 gold groups already satisfy it. A failure
-- here is not a broken statement - it is a data quality finding, and the error names the
-- constraint that caught it.

-- 1. SILVER CUSTOMERS
-- A customer we cannot contact is not a valid record. Silver already filters these to
-- quarantine; the constraint makes it impossible for a future build to forget.
ALTER TABLE prod_commerce.silver.customers
  ADD CONSTRAINT email_present CHECK (email IS NOT NULL AND email <> '');

-- Region decides who can see the row, so an unrecognised value is an ACCESS control defect,
-- not a tidiness one: a typo of 'eu' would silently remove the customer from every regional
-- analyst's results with no error anywhere.
ALTER TABLE prod_commerce.silver.customers
  ADD CONSTRAINT region_known CHECK (region IN ('na', 'eu', 'latam'));

-- 2. SILVER ORDERS
-- Money is never negative here; a refund is a status, not a sign.
ALTER TABLE prod_commerce.silver.orders
  ADD CONSTRAINT amount_non_negative CHECK (amount >= 0);

-- The revenue rule reads this column. An unrecognised status would be silently excluded from
-- every revenue figure - the failure mode that already cost this project once, when a status
-- vocabulary was assumed rather than read from the data.
ALTER TABLE prod_commerce.silver.orders
  ADD CONSTRAINT status_known CHECK (status IN ('completed', 'refunded', 'cancelled'));

-- Amounts are never converted between currencies, so an unrecognised code means a figure
-- that cannot be interpreted at all.
ALTER TABLE prod_commerce.silver.orders
  ADD CONSTRAINT currency_known CHECK (currency IN ('USD', 'CAD', 'EUR', 'MXN', 'BRL', 'COP'));

-- A sanity bound on dates, NOT the business rule. The real rule is "not in the future",
-- which needs current_date() and is therefore not expressible as a constraint; it stays a
-- quarantine rule. This catches only the absurd - a parsing error, a century typo. Stating
-- the difference matters: a reader must not mistake this for the rule they think it is.
ALTER TABLE prod_commerce.silver.orders
  ADD CONSTRAINT order_date_plausible CHECK (order_date >= DATE'2015-01-01' AND order_date <= DATE'2035-01-01');

-- 3. GOLD - where a constraint stops being about data quality and becomes a PRIVACY control.
-- Groups below five customers are suppressed, because an aggregate over four people
-- describes those four people. Until now that was a HAVING clause in one query - a
-- convention any future rewrite could drop silently. As a constraint it is a property the
-- table CANNOT violate: a build that forgets the threshold fails on write instead of
-- quietly publishing a group of three.
ALTER TABLE prod_commerce.gold.customer_segment_profile
  ADD CONSTRAINT k_anonymity_min_group CHECK (customers >= 5);

ALTER TABLE prod_commerce.gold.revenue_by_region_month
  ADD CONSTRAINT k_anonymity_min_customers CHECK (customers_active >= 5);

-- A rate is a share of a whole; outside 0-1 it is an arithmetic error, and one that would
-- otherwise be published as a campaign sizing number.
ALTER TABLE prod_commerce.gold.customer_segment_profile
  ADD CONSTRAINT consent_rate_is_a_rate CHECK (consent_rate >= 0 AND consent_rate <= 1);

ALTER TABLE prod_commerce.gold.revenue_by_region_month
  ADD CONSTRAINT revenue_non_negative CHECK (revenue >= 0);

-- ---------------------------------------------------------------------------
-- 4. INVENTORY. Constraints do NOT appear in information_schema the way tags do - they live
-- in table properties, so the lookup is different from every other metadata check here.
SHOW TBLPROPERTIES prod_commerce.silver.orders;
SHOW TBLPROPERTIES prod_commerce.gold.customer_segment_profile;
DESCRIBE DETAIL prod_commerce.silver.customers;

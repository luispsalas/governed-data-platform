-- Phase 5, Part B: prove each constraint actually rejects.
-- Run as a member of commerce_data_owners.
--
-- WHY THIS SCRIPT EXISTS
-- All 10 constraints added cleanly in Part A. That proves the EXISTING rows satisfy them.
-- It does NOT prove the constraints would stop anything, and a constraint nobody has seen
-- reject a row is indistinguishable from one that was never added. Each test below feeds the
-- table the exact fault its constraint exists to catch.
--
-- HOW TO RUN: ONE STATEMENT AT A TIME ("Run selected"). Every INSERT here is SUPPOSED to
-- fail, and a Run-all stops at the first one - so the run status is meaningless in this
-- script. A test suite containing intended failures cannot be judged by its own run status.
--
-- SAFETY: if a constraint is broken, its INSERT will SUCCEED and leave a bad row behind.
-- Section 0 takes the before-counts and section 3 compares them; any change is both a
-- failed test and a row to delete.

-- ---------------------------------------------------------------------------
-- RESULT, Sep 27 2026: 8 of 8 rejected, each naming its own constraint via
-- [DELTA_VIOLATE_CONSTRAINT_WITH_VALUES] with the constraint name, its full expression AND
-- the offending value. Row counts identical before and after.
-- THE DISABLE TEST WAS CONCLUSIVE: with k_anonymity_min_group dropped, the identical insert
-- returned num_inserted_rows = 1 and a group of three people sat published in gold - so the
-- constraint was what had been doing the work, not something else in the write path.
-- Nothing anywhere signalled that a privacy threshold had been removed and then violated;
-- `num_affected_rows: 1` was the only output.
-- Contrast the Phase 4 mask failure (CAST_INVALID_INPUT), which named a symptom three layers
-- from its cause and mentioned no column, policy or mask: SAME PLATFORM, TWO GOVERNANCE
-- CONTROLS, OPPOSITE DIAGNOSABILITY - which should decide how much runbook text each needs.

-- ---------------------------------------------------------------------------
-- 0. BEFORE
SELECT 'silver.customers' AS tbl, COUNT(*) AS n FROM prod_commerce.silver.customers
UNION ALL SELECT 'silver.orders', COUNT(*) FROM prod_commerce.silver.orders
UNION ALL SELECT 'gold.customer_segment_profile', COUNT(*) FROM prod_commerce.gold.customer_segment_profile
UNION ALL SELECT 'gold.revenue_by_region_month', COUNT(*) FROM prod_commerce.gold.revenue_by_region_month;
-- expect 4940 / 19565 / 9 / 304

-- ---------------------------------------------------------------------------
-- 1. EACH FAULT, ONE AT A TIME. Every one must fail, naming its own constraint.

-- Negative money. The most obvious rule, and the one most likely to be assumed rather than
-- enforced.
INSERT INTO prod_commerce.silver.orders (order_id, customer_id, order_date, amount, currency, status)
VALUES ('TEST-NEG', 'C00001', DATE'2024-06-01', -1.00, 'EUR', 'completed');
-- expect failure naming amount_non_negative

-- An unrecognised status. Deliberately uses 'shipped' - a value INVENTED earlier in this
-- project and written into a column description before anyone read the real vocabulary out
-- of the data. The constraint is what would have caught that.
INSERT INTO prod_commerce.silver.orders (order_id, customer_id, order_date, amount, currency, status)
VALUES ('TEST-STATUS', 'C00001', DATE'2024-06-01', 10.00, 'EUR', 'shipped');
-- expect failure naming status_known

-- A currency the business does not trade in. Amounts are never converted, so an
-- unrecognised code produces a figure nobody can interpret.
INSERT INTO prod_commerce.silver.orders (order_id, customer_id, order_date, amount, currency, status)
VALUES ('TEST-CCY', 'C00001', DATE'2024-06-01', 10.00, 'GBP', 'completed');
-- expect failure naming currency_known

-- An implausible date. Note this tests the SANITY bound, not the business rule: "not in the
-- future" needs current_date(), which a constraint may not use.
INSERT INTO prod_commerce.silver.orders (order_id, customer_id, order_date, amount, currency, status)
VALUES ('TEST-DATE', 'C00001', DATE'1999-01-01', 10.00, 'EUR', 'completed');
-- expect failure naming order_date_plausible

-- A customer with no way to reach them.
INSERT INTO prod_commerce.silver.customers (customer_id, first_name, last_name, email, region, segment)
VALUES ('TEST-NOEMAIL', 'Test', 'Row', NULL, 'eu', 'retail');
-- expect failure naming email_present

-- A region nobody granted access for. This is an ACCESS defect wearing a data-quality
-- costume: the row would be invisible to every regional analyst, silently.
INSERT INTO prod_commerce.silver.customers (customer_id, first_name, last_name, email, region, segment)
VALUES ('TEST-REGION', 'Test', 'Row', 'test@example.org', 'apac', 'retail');
-- expect failure naming region_known

-- THE PRIVACY ONE. A group of three people published as an aggregate. Before Part A this
-- would have been accepted by the table and stopped only by a HAVING clause in whichever
-- query happened to write it.
INSERT INTO prod_commerce.gold.customer_segment_profile (region, segment, customers, customers_consented, consent_rate)
VALUES ('eu', 'business', 3, 2, 0.6667);
-- expect failure naming k_anonymity_min_group

-- A rate outside 0-1: an arithmetic error that would otherwise be published as a campaign
-- sizing number.
INSERT INTO prod_commerce.gold.customer_segment_profile (region, segment, customers, customers_consented, consent_rate)
VALUES ('eu', 'premium', 100, 150, 1.5);
-- expect failure naming consent_rate_is_a_rate

-- ---------------------------------------------------------------------------
-- 2. THE DISABLE TEST - run on the most important claim only.
-- Firing proves the check works. Only disabling it proves the check is what was DOING the
-- work: without this step, a rejection could have come from a type error, a policy, or
-- anything else in the write path, and the test would look identical.
ALTER TABLE prod_commerce.gold.customer_segment_profile DROP CONSTRAINT k_anonymity_min_group;

-- The SAME insert that just failed. It must now SUCCEED - that success is the evidence.
INSERT INTO prod_commerce.gold.customer_segment_profile (region, segment, customers, customers_consented, consent_rate)
VALUES ('eu', 'business', 3, 2, 0.6667);
-- expect SUCCESS. A failure here means something ELSE was blocking and the constraint was
-- never the control - which would invalidate the test above, not confirm it.

SELECT region, segment, customers FROM prod_commerce.gold.customer_segment_profile
WHERE customers < 5;   -- expect exactly the one row just inserted: eu | business | 3

-- Remove the evidence and restore the control. Both statements matter: leaving the row
-- publishes a group of three, and leaving the constraint off removes the privacy control
-- while every other check still reports clean.
DELETE FROM prod_commerce.gold.customer_segment_profile WHERE customers < 5;

ALTER TABLE prod_commerce.gold.customer_segment_profile
  ADD CONSTRAINT k_anonymity_min_group CHECK (customers >= 5);
-- This re-add also RE-VALIDATES every row, so its success confirms the cleanup was complete.

-- ---------------------------------------------------------------------------
-- 3. AFTER - the counts must be identical to section 0.
SELECT 'silver.customers' AS tbl, COUNT(*) AS n FROM prod_commerce.silver.customers
UNION ALL SELECT 'silver.orders', COUNT(*) FROM prod_commerce.silver.orders
UNION ALL SELECT 'gold.customer_segment_profile', COUNT(*) FROM prod_commerce.gold.customer_segment_profile
UNION ALL SELECT 'gold.revenue_by_region_month', COUNT(*) FROM prod_commerce.gold.revenue_by_region_month;
-- expect 4940 / 19565 / 9 / 304 again. Any difference is a rejected test that was not
-- rejected, and the row is still in the table.

-- Constraints still present and complete after the disable test:
SHOW TBLPROPERTIES prod_commerce.gold.customer_segment_profile;
-- expect delta.constraints.k_anonymity_min_group AND delta.constraints.consent_rate_is_a_rate

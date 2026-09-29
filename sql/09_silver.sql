-- Phase 4, Part A: bronze -> silver (typed, quality-gated, re-tagged).
-- IDENTITY SCOPE (added Sep 28 2026): every verification result recorded in this script was
-- produced by the PRIMARY (catalog owner). `information_schema` is permission-filtered, so a
-- coverage check here reports what the owner can see, not what exists. Re-running as a
-- persona returns a smaller universe and a clean result means less. Not a correction to any
-- result below - a scope statement that was missing when they were written.
--
-- WHO RUNS THIS, AND WHY IT MATTERS MORE THAN IT LOOKS
-- Run as a member of `commerce_data_owners` - the group the Phase 3 policies except.
-- A column mask applies to whoever RUNS the query, including a query that writes a table.
-- If the build ran as a masked identity, every CTAS below would read '***' and store it, and
-- silver would be permanently redacted with no error raised anywhere. In production this is
-- why the service principal for the pipeline belongs to the exempted group by design, and why that
-- membership is an audited control rather than a convenience.
SELECT current_user() AS who,
       is_account_group_member('commerce_data_owners') AS may_read_unmasked;
-- must read true before running anything below

-- ---------------------------------------------------------------------------
-- THE GAP THIS SCRIPT HAS TO CLOSE
-- Column tags do not survive CREATE TABLE AS SELECT, and every Phase 3 policy matches on
-- tags. So between the CTAS and the SET TAGS statements, the new silver table holds real
-- names, emails and national IDs that NO mask applies to - and the analyst group already
-- holds SELECT on this schema. The window is real; section 5 closes it and section 7 proves
-- it was closed. Never split this script across two sessions.

-- ---------------------------------------------------------------------------
-- A GOVERNED TABLE CANNOT BE REBUILT IN PLACE (confirmed Sep 23 2026).
-- `CREATE OR REPLACE TABLE prod_commerce.silver.customers` - the table Phase 3 created and
-- tagged by hand - is REFUSED:
--   [INVALID_PARAMETER_VALUE.CANNOT_DROP_TAGGED_COLUMN] Column cannot be dropped because it
--   has one or more governed tags assigned. Please remove the tag(s) before dropping the
--   column.  (https://docs.databricks.com/aws/en/database-objects/tags#drop)
-- Replacing a table drops its columns, and a column carrying a GOVERNED tag cannot be
-- dropped. Note where that guardrail does and does not fire: it blocks the rebuild that
-- would have KEPT the tags, and it does not block `CREATE TABLE <new name> AS SELECT`,
-- which has no tags to protect - so the path that silently produces an unmasked copy is the
-- one that still succeeds. Partial protection, aimed at the less dangerous case.
--
-- The design it forces is the right one anyway: SEPARATE THE DDL FROM THE DML.
--   First run  - CREATE TABLE (section 1-2), then tag and describe it (sections 5-6).
--   Every run after - INSERT OVERWRITE (section 8). Column definitions are untouched, so
--   tags and descriptions persist and there is never an untagged window to exploit.
-- Tag the contract once; refill it forever.
--
-- ONE-TIME MIGRATION: the hand-built Phase 3 silver.customers has a different column set,
-- so INSERT OVERWRITE cannot target it. Drop it and let section 1 create the real one:
--   DROP TABLE prod_commerce.silver.customers;
-- CONFIRMED Sep 23 2026: DROP TABLE succeeds - "OK", one second, no warning of any kind.
--
-- So the guard covers exactly one of three paths, and it is the safe one:
--   CREATE OR REPLACE TABLE  (rebuild in place)  -> REFUSED   - tags would have SURVIVED
--   DROP TABLE               (remove outright)   -> OK        - tags gone with the table
--   CREATE TABLE <new> AS SELECT (build a copy)  -> OK        - tags never applied, copy unmasked
-- CANNOT_DROP_TAGGED_COLUMN is a COLUMN-level integrity rule, not a table-level safety net,
-- and it is easy to read as the second thing. The sting is the direction it pushes you: the
-- obvious way to make the error go away is DROP then CREATE, so the error itself ROUTES the
-- author onto the path that discards the classification. Nothing reports that afterwards.
-- Guide point: never let CANNOT_DROP_TAGGED_COLUMN be answered with a DROP. It is the signal
-- to switch to INSERT OVERWRITE (section 8), which is the only path that keeps the governance.

-- ---------------------------------------------------------------------------
-- 1. SILVER CUSTOMERS - types applied, defects quarantined, business rules named.
-- Bronze keeps everything as text so ingestion cannot corrupt a postcode; silver is where
-- the business meaning is asserted: a birth date is a date, a consent flag is true or false.
-- try_cast returns NULL instead of failing, so one bad value cannot abort the build.
-- COLUMN ORDER WARNING (Phase 3b). `birth_year` is LAST in both the CREATE and the
-- INSERT OVERWRITE below, because ALTER TABLE ADD COLUMN appended it to the END of the live
-- table. INSERT OVERWRITE matches columns BY POSITION, so listing birth_year where
-- date_of_birth used to sit (position 13) would write years into `marketing_consent`. That
-- is the silent-corruption shape: a schema change made in place, and a build script edited
-- in the obvious place, disagreeing about order with nothing reporting it. Worth testing
-- `INSERT OVERWRITE ... BY NAME`, which removes the positional dependency entirely - NOT
-- verified here, so it is a recommendation and not an instruction.
--
-- PHASE 3b CHANGED THIS BUILD (Sep 28 2026). silver.customers no longer carries
-- `date_of_birth`; it carries `birth_year` INT instead. The full date was removed from this
-- layer because a type-mismatched mask had DENIED the column rather than masking it, and the
-- control is now STRUCTURAL - the sensitive precision is never written, so there is nothing
-- to mask and no mask to fail. Non-owners lose nothing: the retired mask returned year-only
-- anyway (make_date(year,1,1)), and the full date remains in bronze.customers.
-- IF YOU RESTORE THE OLD EXPRESSION, YOU SILENTLY UNDO PHASE 3b - the column returns with no
-- tag and no policy matching it, and every coverage check still reports clean because an
-- untagged column is only visible to a check that looks for MISSING tags.
CREATE TABLE prod_commerce.silver.customers
COMMENT 'Customer master, one row per customer, types applied and quality rules enforced. Rows failing a rule are in silver.quarantine_customers, not dropped. Source: bronze.customers. Carries direct identifiers - masked for everyone except commerce_data_owners by the catalog ABAC policies.'
AS
SELECT customer_id,
       first_name,
       last_name,
       lower(trim(email))              AS email,          -- one spelling per address, so counts are honest
       phone,
       national_id,
       street_address,
       city,
       postcode,
       country,
       lower(trim(region))             AS region,         -- the row filter compares on this, so normalize it
       segment,
       try_cast(marketing_consent AS BOOLEAN) AS marketing_consent,
       try_cast(created_at AS TIMESTAMP)      AS created_at,
       _ingested_at,
       current_timestamp()             AS _silver_built_at,
       -- Phase 3b. LAST ON PURPOSE - see the ordering note at the head of this file.
       year(try_cast(date_of_birth AS DATE)) AS birth_year
FROM prod_commerce.bronze.customers
WHERE email IS NOT NULL AND trim(email) <> '';            -- a customer we cannot contact is not a valid record

-- The rejected rows are kept, not discarded: someone has to be able to answer "what did we
-- throw away and why", and a deleted row cannot answer that.
CREATE TABLE prod_commerce.silver.quarantine_customers
COMMENT 'Customer rows rejected by the silver quality rules, with the reason. Reviewed rather than deleted: the count is a data-quality signal and the rows are evidence for the source system owner. Carries the same direct identifiers as bronze.'
AS
SELECT *, 'missing_email' AS reject_reason, current_timestamp() AS _quarantined_at
FROM prod_commerce.bronze.customers
WHERE email IS NULL OR trim(email) = '';

-- ---------------------------------------------------------------------------
-- 2. SILVER ORDERS - four business rules, each rejected for its own stated reason.
-- An order must belong to a customer who is THEMSELVES valid, cost a non-negative amount,
-- and not be dated in the future.
--
-- REFERENTIAL INTEGRITY ACROSS THE LAYER (defect found and corrected Sep 23 2026).
-- The first version of this join read from bronze.customers, which let through every order
-- belonging to a customer that silver had quarantined: 237 orders pointing at customers not
-- present in silver.customers, while the column description claimed the opposite. Quality
-- rules COMPOSE - filtering a parent table orphans its children unless the child filters on
-- the OUTPUT of the parent. Join silver to silver, never silver to bronze.
CREATE TABLE prod_commerce.silver.orders
COMMENT 'Orders, one row per order, types applied and quality rules enforced. Every row joins to a customer present in silver.customers, has a non-negative amount and a date that is not in the future. Rejects are in silver.quarantine_orders. Source: bronze.orders, filtered against silver.customers.'
AS
SELECT o.order_id, o.customer_id,
       try_cast(o.order_date AS DATE)      AS order_date,
       try_cast(o.amount AS DECIMAL(12,2)) AS amount,   -- money is decimal, never float
       upper(trim(o.currency))             AS currency,
       lower(trim(o.status))               AS status,
       o.card_number, o._ingested_at,
       current_timestamp()                 AS _silver_built_at
FROM prod_commerce.bronze.orders o
INNER JOIN prod_commerce.silver.customers c ON c.customer_id = o.customer_id
WHERE try_cast(o.amount AS DECIMAL(12,2)) >= 0
  AND try_cast(o.order_date AS DATE) <= current_date();

-- Same rows from the other side, labelled. The two customer-related reasons are SEPARATE on
-- purpose: "we never knew this customer" is a source-system defect nobody here can fix,
-- while "we rejected this customer" is 237 orders that would return to reporting if 60
-- customer records were corrected. One shared bucket would hide that number completely.
-- The CASE assigns ONE primary reason in the order written, so the counts do not
-- double-count an order that breaks two rules at once.
CREATE TABLE prod_commerce.silver.quarantine_orders
COMMENT 'Order rows rejected by the silver quality rules, one primary reject_reason per row. orphan_customer means the customer was never in the source; customer_quarantined means the customer exists but failed their own quality rule, so their orders are held with them. Feeds the data-quality report; reviewed rather than deleted. Carries the raw payment card number.'
AS
SELECT o.*,
       CASE WHEN b.customer_id IS NULL                           THEN 'orphan_customer'
            WHEN s.customer_id IS NULL                           THEN 'customer_quarantined'
            WHEN try_cast(o.amount AS DECIMAL(12,2)) IS NULL     THEN 'unparseable_amount'
            WHEN try_cast(o.order_date AS DATE) IS NULL          THEN 'unparseable_date'
            WHEN try_cast(o.amount AS DECIMAL(12,2)) < 0         THEN 'negative_amount'
            WHEN try_cast(o.order_date AS DATE) > current_date() THEN 'future_order_date'
            ELSE 'unknown' END AS reject_reason,
       current_timestamp()     AS _quarantined_at
FROM prod_commerce.bronze.orders o
LEFT JOIN prod_commerce.bronze.customers b ON b.customer_id = o.customer_id
LEFT JOIN prod_commerce.silver.customers s ON s.customer_id = o.customer_id
WHERE s.customer_id IS NULL
   OR try_cast(o.amount AS DECIMAL(12,2)) < 0
   OR try_cast(o.order_date AS DATE) > current_date()
   OR try_cast(o.amount AS DECIMAL(12,2)) IS NULL
   OR try_cast(o.order_date AS DATE) IS NULL;

-- ---------------------------------------------------------------------------
-- 3. Reconciliation: nothing silently vanished between the two layers.
-- Kept + quarantined must equal what bronze held. A build that loses rows without saying so
-- is the failure this check exists to make impossible.
SELECT 'customers' AS tbl,
       (SELECT COUNT(*) FROM prod_commerce.bronze.customers)            AS bronze_rows,
       (SELECT COUNT(*) FROM prod_commerce.silver.customers)            AS silver_rows,
       (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_customers) AS quarantined,
       (SELECT COUNT(*) FROM prod_commerce.silver.customers)
         + (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_customers)
         - (SELECT COUNT(*) FROM prod_commerce.bronze.customers)        AS difference_must_be_zero
UNION ALL
SELECT 'orders',
       (SELECT COUNT(*) FROM prod_commerce.bronze.orders),
       (SELECT COUNT(*) FROM prod_commerce.silver.orders),
       (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_orders),
       (SELECT COUNT(*) FROM prod_commerce.silver.orders)
         + (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_orders)
         - (SELECT COUNT(*) FROM prod_commerce.bronze.orders);

-- Referential integrity ACROSS the layer: every order must point at a customer that
-- survived the silver rules. This check is what caught the bronze-join defect; before the
-- fix it returned 237, and 237 is the number the column description had denied existed.
SELECT COUNT(*) AS orders_with_no_silver_customer
FROM prod_commerce.silver.orders o
LEFT JOIN prod_commerce.silver.customers c ON c.customer_id = o.customer_id
WHERE c.customer_id IS NULL;
-- expect 0

-- Why each order was refused - the number the business actually asks for.
SELECT reject_reason, COUNT(*) AS n_rows
FROM prod_commerce.silver.quarantine_orders
GROUP BY reject_reason ORDER BY n_rows DESC;

-- Did typing lose anything? A try_cast that failed shows up here as a NULL that bronze did
-- not have. Expect zeros; anything else is a format the rules did not anticipate.
SELECT COUNT_IF(birth_year IS NULL)        AS birth_year_unparseable,
       COUNT_IF(created_at IS NULL)        AS created_at_unparseable,
       COUNT_IF(marketing_consent IS NULL) AS consent_unparseable
FROM prod_commerce.silver.customers;

-- One row per customer, still. A join that fans out is the classic silent silver defect.
SELECT COUNT(*) AS rows_total, COUNT(DISTINCT customer_id) AS customers_distinct
FROM prod_commerce.silver.customers;   -- the two numbers must match

-- ---------------------------------------------------------------------------
-- 4. PROOF OF THE GAP (run this BEFORE section 5, then never again).
-- At this moment the silver tables carry real PII and no classification, so no mask matches
-- them. Expect 0 tagged columns: that zero is the finding, and it is what section 5 fixes.
SELECT table_name, COUNT(*) AS tagged_columns
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'silver'
GROUP BY table_name;
-- Expect: no rows at all for the freshly built tables.

-- ---------------------------------------------------------------------------
-- 5. RE-TAGGING - the step that makes the policies apply again.
-- These are written out rather than generated so the classification is readable in the
-- script itself; for a wide table, generate them from the tags on the source table instead
-- (generator query at the end of this file). Carried columns keep the classification they
-- had in bronze: a value does not become less sensitive by being copied.
ALTER TABLE prod_commerce.silver.customers SET TAGS ('classification' = 'restricted');

ALTER TABLE prod_commerce.silver.customers ALTER COLUMN first_name     SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN last_name      SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN email          SET TAGS ('classification' = 'restricted', 'pii_type' = 'email');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN phone          SET TAGS ('classification' = 'restricted', 'pii_type' = 'phone');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN national_id    SET TAGS ('classification' = 'restricted', 'pii_type' = 'national_id');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN street_address SET TAGS ('classification' = 'restricted', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN customer_id    SET TAGS ('classification' = 'confidential');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN birth_year     SET TAGS ('classification' = 'confidential');   -- Phase 3b: NO pii_type - nothing masks it
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN city           SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN postcode       SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN country        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN segment        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN marketing_consent SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN created_at     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN _ingested_at   SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN _silver_built_at SET TAGS ('classification' = 'internal');

-- region carries BOTH tags: classification says who may see it, filter_key tells the row
-- filter which column decides which rows a regional analyst gets.
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN region SET TAGS ('classification' = 'internal', 'filter_key' = 'region');

ALTER TABLE prod_commerce.silver.orders SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN card_number      SET TAGS ('classification' = 'restricted', 'pii_type' = 'payment_card');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN customer_id      SET TAGS ('classification' = 'confidential');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN order_id         SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN order_date       SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN amount           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN currency         SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN status           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN _ingested_at     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN _silver_built_at SET TAGS ('classification' = 'internal');

-- The quarantine tables are the easiest thing in a lakehouse to forget, and they hold the
-- SAME identifiers as the table they were rejected from. Untagged, they are an unmasked
-- copy of exactly the records someone was already looking at.
ALTER TABLE prod_commerce.silver.quarantine_customers SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN first_name     SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN last_name      SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN email          SET TAGS ('classification' = 'restricted', 'pii_type' = 'email');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN phone          SET TAGS ('classification' = 'restricted', 'pii_type' = 'phone');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN national_id    SET TAGS ('classification' = 'restricted', 'pii_type' = 'national_id');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN street_address SET TAGS ('classification' = 'restricted', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN date_of_birth  SET TAGS ('classification' = 'confidential', 'pii_type' = 'dob');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN city           SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN postcode       SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN customer_id    SET TAGS ('classification' = 'confidential');

-- The remaining quarantine_customers columns. They arrive via SELECT * and are easy to miss
-- when tagging by hand: 19 columns in, 10 tagged, and the check in 7a reports the other 9.
-- _rescued_data is restricted wherever it appears - a malformed row can park raw PII in it.
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN country           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN region            SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN segment           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN marketing_consent SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN created_at        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN _ingested_at      SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN _rescued_data     SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN reject_reason     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN _quarantined_at   SET TAGS ('classification' = 'internal');

ALTER TABLE prod_commerce.silver.quarantine_orders SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN card_number SET TAGS ('classification' = 'restricted', 'pii_type' = 'payment_card');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN customer_id SET TAGS ('classification' = 'confidential');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN order_id        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN order_date      SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN amount          SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN currency        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN status          SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN _ingested_at    SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN _rescued_data   SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN reject_reason   SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN _quarantined_at SET TAGS ('classification' = 'internal');

-- ---------------------------------------------------------------------------
-- 6. Column descriptions. A tag says how a column is handled; a description says what it
-- MEANS, and the person deciding who gets access reads the second one. Populated values,
-- not placeholders - a column described as "the email column" has not been documented.
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN email COMMENT
  'Primary contact address, lowercased and trimmed so one person is one row. Never null in silver: rows without one are in quarantine_customers. Shown to analysts as first letter + domain (r***@hotmail.de) so campaign reach by provider stays answerable without exposing the address.';
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN national_id COMMENT
  'Government identifier as issued, leading zeros preserved (stored as text for that reason). Analysts see a SHA-256 pseudonym, identical for the same person every time, so records can still be counted and joined but not resolved to a person.';
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN birth_year COMMENT
  'Year of birth, stored instead of the full date so there is no date-level precision to protect. Quasi-identifier: not identifying alone, identifying in combination with region and segment, which is why the published aggregates suppress small groups. Carries no mask - the generalization is structural, applied when the row is written rather than when it is read. The full date remains in bronze.customers for anyone with that access.';
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN region COMMENT
  'Sales region, lowercase: na, eu or latam. Governs row-level access - a member of analyst_eu sees only rows where this reads eu. Change it and you change who can see the customer, so it is owned by Sales Operations, not by the pipeline.';
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN marketing_consent COMMENT
  'True where the customer has opted in to marketing contact. The lawful basis for any campaign use of this record; a false here means the row must not reach a campaign export even though it is present in gold.';
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN _silver_built_at COMMENT
  'Timestamp of the silver build that produced this row. Answers "how fresh is this table" and pins any figure in a report to the run that generated it.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN amount COMMENT
  'Order value in the currency of the currency column, as DECIMAL(12,2). Decimal rather than floating point because sums of money must reconcile to the cent against Finance. Negative values are rejected to quarantine_orders.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN card_number COMMENT
  'Payment card number as captured. Analysts see the last four digits only (****4321), which is enough to match a customer service enquiry to an order and not enough to transact.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN customer_id COMMENT
  'Customer this order belongs to. Guaranteed to exist in silver.customers, because the build joins against silver rather than bronze - orders whose customer is missing from the source are rejected as orphan_customer, and orders whose customer was itself quarantined are rejected as customer_quarantined. Verified by the referential-integrity check in section 3.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN status COMMENT
  'Order lifecycle state, lowercase. Values present in the data, confirmed by query rather than assumed: completed (~90%), refunded (~6%), cancelled (~4%). Revenue reporting counts completed only - refunded money was returned and cancelled orders never shipped - and the gold layer applies that rule so every report uses the same definition.';
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN reject_reason COMMENT
  'Which silver quality rule refused this row, one primary reason in precedence order: orphan_customer (never in the source), customer_quarantined (the customer failed their own rule, so their orders are held with them), unparseable_amount, unparseable_date, negative_amount or future_order_date. Grouped by this column, the table is the data-quality report sent to the source system owner.';

-- 6b. The columns the projection rule left blank. Every one of these is either computed
-- or new, which is exactly why it inherited nothing (see the note in section 4).
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN created_at COMMENT
  'When the customer record was created in the source system - the account opening date, used for cohort and tenure analysis. Distinct from _ingested_at (when we loaded it) and _silver_built_at (when we last rebuilt this table): only this one is a fact about the customer.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN order_date COMMENT
  'Date the order was placed, typed from the bronze text value. The date every revenue figure is grouped by, so it defines which period an order counts in. Orders dated in the future are rejected to quarantine_orders as future_order_date rather than allowed to inflate a forecast.';
-- The value list here is COPIED from 04_comments.sql, which verified it against
-- the data. Retyping it from memory dropped COP on the first attempt - a correct record
-- degraded by being rewritten rather than copied.
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN currency COMMENT
  'ISO 4217 currency code of the amount column, uppercase. Values present in the data: USD, CAD, EUR, MXN, BRL, COP. Amounts are NOT converted to a single currency in silver - summing across currencies without converting is the most common way this table is misread, which is why gold reports revenue per currency.';
ALTER TABLE prod_commerce.silver.orders ALTER COLUMN _silver_built_at COMMENT
  'Timestamp of the silver build that produced this row. Answers "how fresh is this table" and pins any figure in a report to the run that generated it.';
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN reject_reason COMMENT
  'Which silver quality rule refused this customer. Currently only missing_email: a customer with no contact address cannot be served or marketed to, so the record is held for correction rather than published. Grouped by this column, the table is the data-quality report for the source system owner.';
ALTER TABLE prod_commerce.silver.quarantine_customers ALTER COLUMN _quarantined_at COMMENT
  'When this row was last refused by a silver build. A row whose timestamp keeps advancing is a defect nobody has fixed upstream, which is the number that makes a quarantine table actionable rather than a place records go to be forgotten.';
ALTER TABLE prod_commerce.silver.quarantine_orders ALTER COLUMN _quarantined_at COMMENT
  'When this row was last refused by a silver build. A row whose timestamp keeps advancing is a defect nobody has fixed upstream. Orders held as customer_quarantined clear automatically once their customer record is corrected - no change to this table is needed.';

-- 6c. Undescribed-column check, the companion to the untagged one in 7a. A blank is the gap
-- nothing else flags, and after a CTAS the blanks are the COMPUTED columns specifically.
SELECT table_name, column_name
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'silver' AND comment IS NULL ORDER BY table_name, column_name;
-- expect 0 rows

-- ---------------------------------------------------------------------------
-- 7. VERIFICATION - the gap is closed and the controls work on the new tables.
-- 7a. Every column classified. Same standing check as Phase 1, now across silver.
SELECT c.table_name, c.column_name
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON  t.schema_name = c.table_schema AND t.table_name = c.table_name
  AND t.column_name = c.column_name  AND t.tag_name   = 'classification'
WHERE c.table_schema = 'silver' AND t.tag_name IS NULL;
-- expect 0 rows

-- 7b. Positive control for 7a: it can see the columns it is checking.
SELECT table_name, COUNT(*) AS n_columns
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'silver' GROUP BY table_name ORDER BY table_name;

SELECT tag_name, COUNT(*) AS n_tagged
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'silver' GROUP BY tag_name;
-- expect classification on every column, pii_type on the personal ones, filter_key = 1

-- 7c. The owner still reads real values - the build was not run masked.
SELECT current_user() AS who, first_name, email, national_id, birth_year
FROM prod_commerce.silver.customers LIMIT 5;
-- expect real names and addresses. '***' here means the build ran as a masked identity and
-- the table must be rebuilt, not re-tagged.

-- ---------------------------------------------------------------------------
-- 8. THE REPEATABLE REFILL - what every run after the first one does.
-- CONFIRMED Sep 23 2026 by the before/after diff below: INSERT OVERWRITE replaces the
-- CONTENTS and leaves the column definitions alone, so classification, descriptions and the
-- policies that depend on them all survive. The CREATE TABLE in section 1 happens once,
-- ever; this is what a scheduled pipeline runs. Tag the contract once, refill it forever -
-- and note this is the ONLY in-place path that works, since CREATE OR REPLACE is refused
-- on a governed table (see the note above section 1).
--
-- Why this test can be trusted: the same tag query returned ZERO against a fresh CTAS in
-- section 4, so it is a check that has been SEEN to fail. It also compares tag VALUES per
-- column, not counts - a count would pass if a tag were changed rather than dropped.

-- BEFORE: snapshot the metadata the refill must not disturb.
CREATE OR REPLACE TABLE dev_commerce.bronze.tmp_meta_before AS
SELECT c.column_name, c.comment AS comment_before,
       concat_ws(', ', sort_array(collect_list(concat(t.tag_name, '=', t.tag_value)))) AS tags_before
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON t.schema_name = c.table_schema AND t.table_name = c.table_name
 AND t.column_name = c.column_name
WHERE c.table_schema = 'silver' AND c.table_name = 'customers'
GROUP BY c.column_name, c.comment;

SELECT COUNT(*) AS columns_snapshotted, COUNT_IF(tags_before <> '') AS with_tags,
       COUNT_IF(comment_before IS NOT NULL) AS with_comment
FROM dev_commerce.bronze.tmp_meta_before;                      -- 17 / 17 / 17

SELECT MIN(_silver_built_at) AS built_before, COUNT(*) AS rows_before
FROM prod_commerce.silver.customers;                           -- 15:20:20 / 4940

-- THE REFILL. Column order must match the table, so the SELECT is written out, not SELECT *.
INSERT OVERWRITE prod_commerce.silver.customers
SELECT customer_id, first_name, last_name,
       lower(trim(email)) AS email,
       phone, national_id, street_address, city, postcode, country,
       lower(trim(region)) AS region,
       segment,
       try_cast(marketing_consent AS BOOLEAN) AS marketing_consent,
       try_cast(created_at AS TIMESTAMP)      AS created_at,
       _ingested_at,
       current_timestamp()                    AS _silver_built_at,
       year(try_cast(date_of_birth AS DATE))  AS birth_year   -- Phase 3b, LAST on purpose
FROM prod_commerce.bronze.customers
WHERE email IS NOT NULL AND trim(email) <> '';                 -- 4940 inserted

-- AFTER: the diff. Any row returned is metadata the refill destroyed or altered.
-- <=> is null-safe equality, so a NULL comment on both sides counts as equal.
WITH after AS (
  SELECT c.column_name, c.comment AS comment_after,
         concat_ws(', ', sort_array(collect_list(concat(t.tag_name, '=', t.tag_value)))) AS tags_after
  FROM prod_commerce.information_schema.columns c
  LEFT JOIN prod_commerce.information_schema.column_tags t
    ON t.schema_name = c.table_schema AND t.table_name = c.table_name
   AND t.column_name = c.column_name
  WHERE c.table_schema = 'silver' AND c.table_name = 'customers'
  GROUP BY c.column_name, c.comment)
SELECT b.column_name, b.tags_before, a.tags_after,
       left(b.comment_before, 40) AS comment_before, left(a.comment_after, 40) AS comment_after
FROM dev_commerce.bronze.tmp_meta_before b
FULL OUTER JOIN after a ON a.column_name = b.column_name
WHERE NOT (b.tags_before <=> a.tags_after) OR NOT (b.comment_before <=> a.comment_after);
-- CONFIRMED: 0 rows. Every tag and every comment identical, per column.

SELECT MIN(_silver_built_at) AS built_after, COUNT(*) AS rows_after,
       COUNT(DISTINCT customer_id) AS distinct_customers
FROM prod_commerce.silver.customers;                           -- 16:33:56 / 4940 / 4940

-- Masks still resolve, so the policies still match the tags after the refill.
SELECT current_user() AS who, first_name, email, national_id
FROM prod_commerce.silver.customers LIMIT 3;                   -- owner: raw values

DROP TABLE dev_commerce.bronze.tmp_meta_before;

-- ---------------------------------------------------------------------------
-- GENERATOR - for a table too wide to tag by hand, produce the ALTERs from the source
-- tags already on the source table rather than retyping them. Run it, then run its output.
SELECT concat('ALTER TABLE prod_commerce.silver.customers ALTER COLUMN ', column_name,
              ' SET TAGS (',
              concat_ws(', ', collect_list(concat("'", tag_name, "' = '", tag_value, "'"))),
              ');') AS stmt
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'bronze' AND table_name = 'customers'
GROUP BY column_name ORDER BY column_name;

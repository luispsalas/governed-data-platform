-- Phase 5, Part D: do governed tags and ABAC masks reach a MATERIALIZED VIEW?
-- Sections 0-3 and 5 as a member of commerce_data_owners. SECTION 4 IS THE TEST and must be
-- run as the SECOND IDENTITY - the owner is EXCEPT-ed from every mask, so an owner-run pass
-- here would prove nothing at all. That is the Phase 4 lesson; this is the first phase where
-- it was designed in from the start rather than learned.
--
-- WHY THIS IS UNKNOWN RATHER THAN LOOKED UP
-- The ABAC docs state policies cannot attach to views, and for materialized views and
-- streaming tables describe them only as EVALUATED on refresh:
--   "When a pipeline refreshes a materialized view or streaming table, it evaluates policies
--    using the pipeline owner's or run-as identity."
-- On governed TAGS on a materialized view the documentation says nothing. So this is tested,
-- not read.
--
-- THE DESIGN OF THE TEST: tag `status` - a column with no sensitivity at all - as
-- pii_type = 'name', which attracts mask_full and returns '***'. An unambiguous signal on a
-- harmless column: if the analyst sees '***' the mask reached the materialized view; if they
-- see 'completed' it did not. **No personal data is placed at risk to find out**, which is
-- why the test uses a nonsense classification rather than a realistic one.

-- ---------------------------------------------------------------------------
-- 0. OWNER GATE
SELECT current_user() AS who,
       is_account_group_member('commerce_data_owners') AS may_read_unmasked;

-- ---------------------------------------------------------------------------
-- 1. CAN A GOVERNED TAG BE APPLIED TO A MATERIALIZED VIEW AT ALL?
-- ANSWERED Sep 28 2026: ALTER TABLE works on a MATERIALIZED_VIEW. Returns OK; no
-- ALTER MATERIALIZED VIEW form is needed. The ordinary table DDL applies.
ALTER TABLE prod_commerce.silver.orders_quality_demo
  ALTER COLUMN status SET TAGS ('classification' = 'internal', 'pii_type' = 'name');

-- (The ALTER MATERIALIZED VIEW fallback drafted here was never needed.)

-- ---------------------------------------------------------------------------
-- 2. DOES THE CATALOG SEE THE TAG?
-- A statement succeeding is not the same as the tag being visible to the policy engine -
-- exactly the distinction that made the Phase 4 CTAS finding invisible for a whole phase.
SELECT table_name, column_name, tag_name, tag_value
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'silver' AND table_name = 'orders_quality_demo';
-- CONFIRMED: two rows, classification=internal and pii_type=name. The catalog sees tags on a
-- materialized view, so the statement succeeding was not the whole question.

-- ---------------------------------------------------------------------------
-- 3. CAN THE PLATFORM-CREATED OBJECTS BE TAGGED?
-- ANSWERED Sep 28 2026: **YES, they are fully classifiable.**
-- The <pipeline_id> below is not a placeholder you can guess: the platform names these
-- tables after the pipeline's own UUID, so read the real name out of
-- information_schema.tables (the STEP 1 query further down lists it) and paste it in.
ALTER TABLE prod_commerce.silver.`event_log_<pipeline_id>`
  ALTER COLUMN event_type SET TAGS ('classification' = 'internal');
-- Returned OK, and information_schema.column_tags shows it. Of the three possible outcomes -
-- classifiable / refused / succeeds-but-never-appears - this is the good one: no object type
-- in a governed schema is structurally impossible to classify, so the coverage check reports
-- gaps somebody can actually close.
--
-- Worth classifying rather than ignoring: the event log's `origin` struct carries user_id,
-- pipeline_id and cluster identifiers. A pipeline's own telemetry is data about people too.

-- ---------------------------------------------------------------------------
-- 4. THE TEST - RUN AS THE SECOND IDENTITY, IN THE OTHER BROWSER WINDOW.
-- STOP RULE: if `who` is not the test user, everything below is the owner's and proves
-- nothing. Wait for tag propagation before trusting a NEGATIVE - a mask that has not landed
-- yet looks exactly like a mask that does not apply.
SELECT current_user() AS who,
       is_account_group_member('analyst') AS in_analyst;

-- Positive control first: the analyst can reach the object at all.
SELECT COUNT(*) AS rows_visible FROM prod_commerce.silver.orders_quality_demo;

-- THE ANSWER:
SELECT status, COUNT(*) AS n
FROM prod_commerce.silver.orders_quality_demo
GROUP BY status ORDER BY n DESC;
-- ANSWERED Sep 28 2026: **'***' for all 20,000 rows, read as the analyst.** Masks DO reach
-- materialized views. The tag-driven model covers pipeline output, so a medallion layer could
-- be rebuilt as declarative pipelines without losing masking.
--
-- THE DISTINCTION TO TEACH: a MATERIALIZED VIEW is NOT a "view" for ABAC purposes, despite
-- the name. The docs say policies cannot attach to views; a materialized view is a separate
-- table_type that behaves like a table. Anyone reasoning "policies can't attach to views, a
-- materialized view is a view, therefore pipeline output cannot be protected" reaches a wrong
-- and expensive conclusion by a chain that looks sound at every step.

-- Same question for the ROW FILTER, which is a different mechanism on the same object.
-- (Only meaningful once the mask answer is known; region is not in this object, so this is a
--  note for a future test rather than a statement to run today.)

-- ---------------------------------------------------------------------------
-- 5. CLEANUP - DONE Sep 28 2026. The nonsense pii_type was removed and verified: status now
-- carries classification=internal only.
ALTER TABLE prod_commerce.silver.orders_quality_demo ALTER COLUMN status UNSET TAGS ('pii_type');

-- ---------------------------------------------------------------------------
-- 5b. DISPOSITION OF THE DEMO OBJECT - the last open item in Phase 5.
--
-- DECISION Sep 28 2026: DROP IT. The finding it bought is already recorded in 13_expectations.sql
-- (one statement created three objects in a governed schema, two of them undeclared,
-- unnamed and unchosen). The object is not needed to keep that finding, and it is one
-- statement to rebuild if a later phase wants it back. What keeping it WOULD cost is the
-- reason to drop it: 21 unclassified columns across the three objects, which the final
-- state-assertion scripts must then either flag on every run or carry as a permanent
-- hand-written exception - and a standing exception is the kind of thing that stops being
-- read. An object retained "for evidence" that permanently weakens a coverage check is a
-- bad trade when the evidence is already in the script.
--
-- Run in order. Step 1 is the BEFORE snapshot: without it, step 3 cannot distinguish
-- "the platform tables were removed" from "the platform tables were never listed to this
-- identity" - information_schema is permission-filtered, and this is the exact trap the
-- coverage check fell into above.

-- STEP 1 - BEFORE. Record the count AND the names; the names are what step 3 diffs against.
SELECT table_name, table_type
FROM prod_commerce.information_schema.tables
WHERE table_schema = 'silver' ORDER BY table_name;
-- EXPECT: the three demo objects present alongside the designed silver tables.
-- If the two platform-created tables are NOT in this list, STOP - you are running as an
-- identity that cannot see them, and nothing you observe after the drop means anything.
-- RESULT STEP 1, Sep 28 2026, run as the PRIMARY (dark session) - 7 objects, all three demo
-- objects VISIBLE, so the after-diff is readable:
--   customers, orders, quarantine_customers, quarantine_orders      MANAGED   <- designed (4)
--   orders_quality_demo                                   MATERIALIZED_VIEW   <- demo
--   __materialization_mat_<id>_orders_quality_demo_1                MANAGED   <- undeclared
--   event_log_<id>                                                  MANAGED   <- undeclared
-- The two undeclared tables carry the SAME pipeline id as each other - they are one
-- pipeline's footprint, not two separate accidents. (Real id redacted as <id>; a pipeline
-- UUID is workspace-internal and this script is destined for the public repo.)
-- EXPECTED AFTER: exactly the four designed tables.

-- STEP 2 - DROP.
DROP MATERIALIZED VIEW prod_commerce.silver.orders_quality_demo;

-- STEP 3 - AFTER. Same query, diffed against step 1 BY NAME, not by count.
SELECT table_name, table_type
FROM prod_commerce.information_schema.tables
WHERE table_schema = 'silver' ORDER BY table_name;
-- EXPECT: all three gone, and NOTHING ELSE CHANGED. A count-only comparison passes when
-- the right number of objects is present and the wrong ones are - diff the VALUES.
-- The open question this settles: does dropping the materialized view also remove the
-- backing table and the event log, or does it orphan them? An orphan in a governed schema
-- is an object nobody designed and nobody owns, and it would be a finding of its own.

-- STEP 4 - the standing coverage check, re-run as the closing state of Phase 5.
SELECT c.table_name, COUNT(*) AS unclassified_columns
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON t.schema_name = c.table_schema AND t.table_name = c.table_name
 AND t.column_name = c.column_name AND t.tag_name = 'classification'
WHERE c.table_schema = 'silver' AND t.tag_name IS NULL
GROUP BY c.table_name ORDER BY c.table_name;
-- EXPECT: ZERO ROWS. Every column in silver classified, no residue.
-- Note what this check still CANNOT tell you on its own - that zero rows means "nothing
-- unclassified" rather than "nothing visible". Step 1 is what licenses reading it as the
-- former, which is why it is a step and not a preamble.

-- RESULT STEPS 2-4, Sep 28 2026, PRIMARY (dark): **THE DROP IS NOT TRANSITIVE.**
--   orders_quality_demo  GONE (absent from the coverage check, which had it at 5)
--   __materialization_mat_<id>_orders_quality_demo_1   SURVIVES, 6 unclassified columns
--   event_log_<id>                                     SURVIVES, 9 unclassified columns
--
-- Dropping the materialized view removed the view and left both objects the platform
-- created to serve it. They are now ORPHANS in a governed schema: undeclared, unnamed,
-- serving an object that no longer exists, and still counted by every coverage check.
--
-- The 10 -> 9 column delta on event_log is EXPLAINED, not a mystery: section 3 above
-- tagged event_log.event_type with classification=internal, which is exactly one column
-- leaving the unclassified count. Recorded first as "unexplained" an hour after we caused
-- it - a reminder to check what THIS SESSION changed before reaching for a platform theory.
--
-- NEXT: attempt DROP TABLE on each directly, ONE AT A TIME so they can fail differently.
-- **The premise this paragraph originally rested on was FALSE** (corrected Sep 28 2026,
-- on the user's challenge): 13_expectations.sql claimed DESCRIBE TABLE returns PERMISSION_DENIED for
-- the CATALOG OWNER. It does not - that was the ANALYST's denial, mis-attributed from a
-- light-themed screenshot. The owner's DESCRIBE succeeds. See 13_expectations.sql for the
-- controlled both-identities comparison. So there was never a severity question to decide.
-- RESULT, Sep 28 2026, PRIMARY (dark): **BOTH DROPPED OK**, one statement each, no error.
-- So the severity is the milder branch: the orphans are REMOVABLE, just not automatically
-- removed. The platform creates objects you did not declare, leaves them behind when the
-- object they served is dropped, and lets you remove them by hand - IF you knew they existed.
-- For the assertion suite that means no permanent exception is needed; it means the suite
-- must enumerate what it EXPECTED to find, because residue here is invisible by name.
--
-- CLOSED, Sep 28 2026, WITHOUT further testing - the question was built on a false premise.
-- I proposed recreating the MV to test "the owner cannot inspect but can destroy". That
-- asymmetry does not exist: the PERMISSION_DENIED in 13_expectations.sql belonged to the ANALYST,
-- not the owner, and the owner's DESCRIBE succeeded in a both-identities run the same
-- day. The owner can inspect AND drop, which is unremarkable. No MV was recreated.
--
-- THE METHOD LESSON, which outlives the finding: a stale claim in a script was cited as
-- evidence for a NEW hypothesis, and the hypothesis then justified new work. A wrong record
-- does not sit still - it recruits. The residue sweep run earlier that day cleaned this
-- script and MISSED the line in 13_expectations.sql, because the sweep looked for settled
-- questions as open, not for scripts carrying answers that had since been overturned.
-- **A residue sweep must search for RETRACTED CLAIMS, not only for stale framing** - and the
-- tell here was available for free: the sentence contradicted itself, asserting a fact about
-- the ANALYST and a cause about the OWNER in consecutive clauses.

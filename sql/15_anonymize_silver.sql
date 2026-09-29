-- Phase 3b, Part A: STRUCTURAL anonymization in silver.
-- Replaces the maskable DATE `date_of_birth` with an INT `birth_year`, so the control moves
-- from DISPLAY-TIME (a mask applied when the column is read) to STRUCTURAL (there is nothing
-- to mask, because the sensitive precision was never stored).
--
-- WHY THIS COLUMN AND NO OTHER. This is the direct answer to the Phase 3 finding that a
-- type-mismatched mask DENIES a column instead of masking it, invisibly to the owner. The
-- scope is deliberately one column: silver keeps `city`, `postcode`, `country` and `segment`
-- at full precision, because generalizing those removes capability from the OWNER too, and
-- that belongs in Part B's anonymized gold table rather than in the governed serving layer.
--
-- THE EQUIVALENCE ARGUMENT, which is what makes this safe rather than destructive:
--   mask_dob_date returns make_date(year(val), 1, 1) - so every non-owner ALREADY saw only
--   the year. Storing birth_year gives them exactly what they had. The only identity that
--   loses information is the OWNER, and the raw value still exists in bronze.customers under
--   tighter classification. Structural anonymization here removes a RISK, not an answer.
--
-- THE TRADE-OFF TO STATE OUT LOUD, because it is the cost of the stronger control:
--   A display-time mask is INVISIBLE to consumers - the column keeps its name and type, and
--   a query written against it keeps working. A structural change is a BREAKING change: the
--   column is gone, and every query naming it fails. That is the real reason teams reach for
--   masking when structure would be safer, and a guide that recommends structure without
--   saying so is recommending an outage.
--
-- IDENTITY: run every section as the PRIMARY (dark session). Section 6 is the only part run
-- as the second account, and it is the only part that proves anything about access.

-- ===========================================================================
-- 0. BEFORE-STATE. Capture it; do not trust memory or scrollback for any of it.
--    Sections 3 and 7 diff against these, and a diff needs a recorded left side.
-- ===========================================================================
SELECT current_user() AS who,
       is_account_group_member('commerce_data_owners') AS is_owner;   -- expect TRUE

-- 0a. The column as it stands, with its tags.
SELECT c.column_name, c.data_type, t.tag_name, t.tag_value
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON t.schema_name = c.table_schema AND t.table_name = c.table_name
 AND t.column_name = c.column_name
WHERE c.table_schema = 'silver' AND c.table_name = 'customers'
  AND c.column_name IN ('date_of_birth','birth_year')
ORDER BY c.column_name, t.tag_name;
-- EXPECT: date_of_birth DATE, classification=confidential, pii_type=dob_date. No birth_year.
-- RESULT, Sep 28 2026, PRIMARY (dark): exactly that, two rows and no more.
--     date_of_birth  DATE  classification  confidential
--     date_of_birth  DATE  pii_type        dob_date
-- birth_year absent, so section 1 is adding rather than overwriting. Confirming pii_type is
-- `dob_date` and not `dob` matters: section 5 retires a policy BY TAG VALUE, and retiring
-- `dob` instead would strip the mask from bronze.customers and silver.quarantine_customers,
-- both of which still hold full dates.

-- 0b. The policy and function that are about to be retired.
SHOW POLICIES ON CATALOG prod_commerce;
-- EXPECT mask_dob_date present. Record the full row: it is the thing being deleted.

-- 0c. The row count and the value distribution we must preserve.
SELECT COUNT(*)                                  AS rows_total,
       COUNT(date_of_birth)                      AS rows_with_dob,
       COUNT(*) - COUNT(date_of_birth)           AS rows_null_dob,
       MIN(year(date_of_birth))                  AS earliest_year,
       MAX(year(date_of_birth))                  AS latest_year,
       COUNT(DISTINCT year(date_of_birth))       AS distinct_years
FROM prod_commerce.silver.customers;
-- RESULT, Sep 28 2026, PRIMARY (dark): rows_total 4940, rows_with_dob 4940, rows_null_dob 0,
-- earliest_year 1940, latest_year 2008, distinct_years 69. Every row has a birth date, so
-- section 3's null-safe comparison has no nulls to exercise - worth knowing, because a
-- null-handling bug would pass silently here and surface on the next load.

-- ===========================================================================
-- 1. ADD the replacement column and populate it. Nothing is removed yet, so
--    there is no exposure and no breaking change at this point.
-- ===========================================================================
ALTER TABLE prod_commerce.silver.customers ADD COLUMN birth_year INT;

UPDATE prod_commerce.silver.customers
SET birth_year = year(date_of_birth);
-- NULL date_of_birth yields NULL birth_year, which is correct: an unknown birth date must
-- not become an unknown-but-plausible year.
-- RESULT, Sep 28 2026, PRIMARY (dark): num_affected_rows 4940 - every row, matching 0c's
-- rows_total exactly. Tag and comment both returned OK.
--
-- WORTH NAMING, because it is a governance trap and not a footnote: this UPDATE reads
-- date_of_birth to compute the year, and the OWNER is EXCEPT-ed from the mask, so it read
-- real dates. The SAME statement run by a non-owner would read MASKED values and write
-- birth_year from them - succeeding, affecting 4940 rows, and producing silently wrong data
-- with no error anywhere. A mask protects a READ; it does not protect a WRITE that derives
-- from that read. Derivations must be run by an identity that can see the inputs, and who
-- ran a transformation is part of its correctness, not just its audit trail.

-- ===========================================================================
-- 2. CLASSIFY the new column BEFORE anyone can read it.
--    Note what it does NOT get: no pii_type. In this taxonomy pii_type answers
--    "how is it masked", and this column is not masked - that is the entire
--    point. classification=confidential still applies: a birth year is a
--    QUASI-IDENTIFIER, identifying in combination with region and segment.
--    A column that is safe alone and identifying in combination is exactly the
--    case a classification-only tag exists for.
-- ===========================================================================
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN birth_year
  SET TAGS ('classification' = 'confidential');

ALTER TABLE prod_commerce.silver.customers ALTER COLUMN birth_year COMMENT
  'Year of birth, stored instead of the full date so there is no date-level precision to protect. Quasi-identifier: not identifying alone, identifying in combination with region and segment, which is why the published aggregates suppress small groups. Carries no mask - the generalization is structural, applied when the row is written rather than when it is read. The full date remains in bronze.customers for anyone with that access.';

-- ===========================================================================
-- 3. PROVE THE EQUIVALENCE BEFORE DESTROYING THE EVIDENCE.
--    Diff VALUES, not counts: a count-based check passes when a value is
--    silently changed rather than dropped, which is the mutation that matters.
-- ===========================================================================
SELECT COUNT(*) AS mismatches
FROM prod_commerce.silver.customers
WHERE birth_year IS DISTINCT FROM year(date_of_birth);
-- EXPECT: 0. Null-safe on purpose - IS DISTINCT FROM treats NULL = NULL as equal, so rows
-- with no birth date compare clean instead of reading as mismatches.

SELECT COUNT(*)                     AS rows_total,
       COUNT(birth_year)            AS rows_with_year,
       MIN(birth_year)              AS earliest_year,
       MAX(birth_year)              AS latest_year,
       COUNT(DISTINCT birth_year)   AS distinct_years
FROM prod_commerce.silver.customers;
-- EXPECT: identical to 0c on every figure. If distinct_years differs, STOP.
-- RESULT, Sep 28 2026: mismatches 0, and 4940 / 4940 / 1940 / 2008 / 69 - identical to 0c
-- on every figure. Equivalence PROVEN while both columns still existed, which is the only
-- window in which it could be proven at all.
--
-- WHY BOTH CHECKS AND NOT JUST THE MISMATCH COUNT: `mismatches` compares birth_year against
-- year(date_of_birth) - the SAME expression that produced it. If year() misbehaved on some
-- rows, both sides would be wrong identically and the comparison would still report 0. It
-- is close to a tautology on its own. The distribution compared against 0c's INDEPENDENTLY
-- captured figures is what makes this a real check: distinct_years is the figure that would
-- expose a silent collapse, and it held at 69.

-- ===========================================================================
-- 4. THE EXPOSURE WINDOW - the part that is easy to get wrong and impossible
--    to notice afterwards.
--
--    A tagged column cannot be dropped (CANNOT_DROP_TAGGED_COLUMN), so the
--    only sequence available is UNSET the tag, THEN drop the column. The tag
--    is what the ABAC policy matches on. So between those two statements the
--    policy no longer matches and date_of_birth is READABLE IN FULL by every
--    persona. Running them quickly is not a control; nothing records that the
--    window was short, and an analyst querying in that moment sees real dates.
--
--    So take the table out of service for the change. This is an ordinary
--    maintenance pattern and it is what makes the window a decision rather
--    than an accident.
-- ===========================================================================
-- 4a-FIRST. WHAT THE GRANTS ACTUALLY ARE - run this BEFORE writing any revoke.
SHOW GRANTS ON TABLE prod_commerce.silver.customers;
-- RESULT, Sep 28 2026: exactly TWO rows, and BOTH are inherited:
--     analyst        SELECT   SCHEMA   prod_commerce.silver
--     data_engineer  SELECT   SCHEMA   prod_commerce.silver
-- TWO THINGS THIS CHANGED, both of which would have been defects:
--   (1) The first draft of this section revoked at TABLE level. Against a schema-level
--       grant that SUCCEEDS AND REMOVES NOTHING - the window stays wide open while the
--       statement reports success. A revoke that matched nothing is not a closed door.
--   (2) The first draft re-granted analyst, analyst_eu, data_engineer and auditor. Only
--       two of those hold anything here. Re-granting the other two would have INVENTED
--       grants that never existed - privilege drift introduced by a maintenance operation,
--       the same shape as the Sep 24 ownership defect. Restore what SHOW GRANTS showed,
--       never what the runbook says the matrix is.

-- 4b. CLOSE THE WINDOW AT THE LEVEL THE GRANT ACTUALLY NAMES.
--     This takes the WHOLE silver schema out of service, not just this table, because that
--     is where the privilege lives. Broader than wanted; it is the honest cost of the
--     change, and a maintenance window announced is better than an exposure nobody sees.
REVOKE SELECT ON SCHEMA prod_commerce.silver FROM `analyst`;
REVOKE SELECT ON SCHEMA prod_commerce.silver FROM `data_engineer`;
SHOW GRANTS ON TABLE prod_commerce.silver.customers;   -- EXPECT: 0 rows. Confirm, do not assume.

-- 4c. Delta column mapping - DROP COLUMN requires name-based mapping.
ALTER TABLE prod_commerce.silver.customers SET TBLPROPERTIES (
  'delta.columnMapping.mode' = 'name',
  'delta.minReaderVersion'   = '2',
  'delta.minWriterVersion'   = '5'
);

-- 4d. The statements the window lives between.
--     RUN AS ONE BATCH, Sep 28 2026. An experiment was available here and was NOT taken,
--     which is worth recording as a choice rather than an omission: with the door already
--     shut by 4b, unsetting ONLY pii_type and attempting the drop would have settled whether
--     CANNOT_DROP_TAGGED_COLUMN means "a policy-matched tag" or "any tag at all". Both tags
--     came off together, so the question is now unanswerable ON THIS COLUMN. It is cheap to
--     settle on any other tagged column later, and the answer would shorten this window by
--     one statement for everyone who follows this runbook.
--
--     ORDER NOTE THAT IS NOT OPTIONAL: verify the DROP SUCCEEDED before re-granting in 4e.
--     After the UNSET statements and before a successful DROP, date_of_birth is present and
--     NO LONGER MASKED - the tag the policy matched on is gone. Re-granting into that state
--     is strictly worse than never having started: it serves real birth dates to every
--     persona, with the control removed and nothing reporting it. Confirm the column is
--     ABSENT, not merely untagged, and only then restore access.
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN date_of_birth UNSET TAGS ('pii_type');
ALTER TABLE prod_commerce.silver.customers ALTER COLUMN date_of_birth UNSET TAGS ('classification');
ALTER TABLE prod_commerce.silver.customers DROP COLUMN date_of_birth;

-- 4e. BACK IN SERVICE - restoring EXACTLY the two grants 4a recorded, at SCHEMA level.
GRANT SELECT ON SCHEMA prod_commerce.silver TO `analyst`;
GRANT SELECT ON SCHEMA prod_commerce.silver TO `data_engineer`;
SHOW GRANTS ON TABLE prod_commerce.silver.customers;
-- EXPECT: the same two rows as 4a, same ActionType, same ObjectType=SCHEMA, same ObjectKey.
-- SECOND RESTORE, Sep 28 2026 after the incident above: SHOW GRANTS ON SCHEMA returns FOUR
-- rows - SELECT and USE SCHEMA for each principal. It was the SCHEMA-level view that exposed
-- the loss; the TABLE-level view had looked normal throughout.
--
-- RESULT, Sep 28 2026: restored exactly - analyst and data_engineer, SELECT, SCHEMA,
-- prod_commerce.silver. Identical to 4a on every field. No privilege drift, which is the
-- whole reason 4a was read and recorded before anything was revoked. Had the first draft's
-- four table-level GRANTs been run, this table would now carry two direct grants that never
-- existed and two principals that never had access - and SHOW GRANTS would have shown four
-- plausible-looking rows that no one would question.
-- Diff the VALUES against 4a's recorded output, not the count - two rows of the wrong thing
-- and two rows of the right thing look identical from a count.

-- THE ALTERNATIVE THIS SECTION REJECTED, recorded because both are worth knowing:
--   Build silver.customers_v2 without the column, then DROP the original and RENAME.
--   That has NO exposure window at all - the old table keeps its mask until the moment it
--   is dropped, and schema-level grants attach to the new table automatically. It was
--   rejected here because a CTAS does NOT carry tags (the Phase 4 finding), so all 17
--   columns would need re-tagging and re-describing, which trades a short announced window
--   for a long silent one where the new table sits unclassified. On a table with more
--   consumers, or one that cannot go out of service, the swap is the better trade.
-- ===========================================================================
-- !! INCIDENT, Sep 28 2026 - READ BEFORE RE-RUNNING ANY PART OF SECTION 4 !!
-- This section was accidentally re-run after the phase was complete. The revokes in 4b
-- executed; execution did not reach the re-grant in 4e.
--
-- THE ABORT POINT IS THE POINT: 4d's `ALTER COLUMN date_of_birth UNSET TAGS` failed with
-- UNRESOLVED_COLUMN, because date_of_birth had already been dropped by the first run. So the
-- section did not merely fail to finish - IT FAILED *BECAUSE* THE CHANGE HAD ALREADY BEEN
-- APPLIED, which means a re-run is GUARANTEED to strand access in the revoked state, every
-- time, for as long as the phase stays done. A script that is safe exactly once and harmful
-- on every subsequent run is worse than one that is never safe: the first success teaches
-- you it works. Result: `analyst` and
-- `data_engineer` were left holding USE SCHEMA and NOT SELECT on prod_commerce.silver -
-- a silent access outage for both personas across the WHOLE schema, not just this table.
--
-- Three things this teaches:
--  * WRITE THE RESTORE SO IT CANNOT BE SKIPPED. The fix is not "be careful": guard the
--    section so it refuses to start once the change is applied - "stop unless
--    date_of_birth still exists" costs one query and turns a re-run into a no-op instead
--    of an outage.
--  * A MAINTENANCE SECTION IS NOT IDEMPOTENT. Re-running a build script is usually safe;
--    re-running a script that revokes-changes-restores is safe only if it completes. Any
--    section that takes access away must be written so a partial run fails LOUDLY, or kept
--    in a file that cannot be run wholesale by accident.
--  * NOTHING REPORTED IT. No error, no alert. The personas would have discovered it by
--    being unable to work; the owner would never have seen it, because owners bypass the
--    matrix. It surfaced only because a verification query was run instead of trusting a
--    report that everything was OK.
--  * `SHOW GRANTS ON TABLE` AND `ON SCHEMA` ANSWER DIFFERENT QUESTIONS. The table-level
--    view lists privileges that REACH the table and showed SELECT inherited from the schema;
--    the schema-level view lists what is actually HELD there and showed only USE SCHEMA.
--    Check access at the level the grant lives, or a revoked privilege can still look
--    present in the view you happened to run.
-- ===========================================================================

-- ===========================================================================
-- 5. RETIRE THE CONTROL AND ITS VOCABULARY.
--    A policy whose last matching column is gone is not harmless - it is a
--    control that reports nothing, matches nothing, and reads as coverage.
-- ===========================================================================
-- 5a. Does anything still carry the tag value? Check before deleting.
SELECT schema_name, table_name, column_name
FROM prod_commerce.information_schema.column_tags
WHERE tag_name = 'pii_type' AND tag_value = 'dob_date';
-- EXPECT: 0 rows. If any row appears, STOP - something else depends on this policy.

-- RESULT of the tag check above, Sep 28 2026: 0 rows. Nothing still carries dob_date, so
-- retiring the policy strands nothing.
--
-- SYNTAX FINDING, Sep 28 2026: `DROP POLICY IF EXISTS ...` is NOT valid here -
-- [PARSE_SYNTAX_ERROR] Syntax error at or near 'EXISTS': missing 'ON'. The parser reads IF
-- as the POLICY NAME and then expects ON. ABAC's DROP POLICY takes no IF EXISTS clause,
-- unlike DROP TABLE/FUNCTION/VIEW, so the habit transfers wrongly. Consequence for a
-- runbook: a teardown script cannot be made idempotent for policies the way it can for
-- tables - re-running it errors on an already-dropped policy rather than passing quietly.
--
-- The failure was usefully ordered: the batch stopped, so DROP FUNCTION did not run either,
-- which is correct - the function is still referenced by the policy until the policy is
-- gone. Drop the POLICY first, then the FUNCTION.
DROP POLICY mask_dob_date ON CATALOG prod_commerce;
DROP FUNCTION prod_commerce.governance.mask_dob_date;

-- Then read the REMAINING list, not the OK. A successful DROP proves a statement ran; only
-- the inventory proves it removed the one thing intended and left the other controls whole.
SHOW POLICIES ON CATALOG prod_commerce;
-- EXPECT: exactly one fewer than 0b recorded - the 4 other masks and the row filter intact.
-- RESULT, Sep 28 2026: mask_dob_date ABSENT. Seven policies remain, all CATALOG-scoped on
-- prod_commerce: mask_dob, mask_email, mask_name_address, mask_national_id,
-- mask_payment_card, mask_phone (COLUMN_MASK x6) + regional_access_eu (ROW_FILTER).
-- The one that matters most here is mask_dob SURVIVING: it is the STRING mask still
-- protecting the full dates in bronze.customers and silver.quarantine_customers. Retiring
-- `dob` instead of `dob_date` would have stripped both, and the two names differ by five
-- characters - which is the argument for the tag-value check ABOVE the drop, not after it.
--
-- COUNT TO RECONCILE, not smoothed over: the domain record states "7 catalog-level ABAC
-- policies", and 7 remain AFTER removing one. Both are probably right - the record likely
-- predates mask_dob_date, which was added later as the fix for the type-mismatch finding -
-- but that is an inference, not a check. Confirm against the Phase 3 script before quoting
-- either number anywhere it will be read as fact.

-- 5b. Retire the governed-tag ALLOWED VALUE too, now its last user is gone.
--     This is account-level and may not be permitted on Free Edition. Attempt it and
--     record the outcome either way - a vocabulary that only ever grows is a vocabulary
--     nobody can reason about, and "we could not remove it" is a finding, not a failure.
--     (UI path: Catalog > Tag policies > pii_type > edit allowed values.)
-- RESULT: <record whether dob_date could be removed from the pii_type governed tag>

-- Note `dob` (the STRING mask, used by bronze.customers and silver.quarantine_customers)
-- STAYS. Only `dob_date` retires. Deleting both would strip the mask from two tables that
-- still hold full dates - read the tag values in use before retiring any of them.

-- ===========================================================================
-- 6. PERSONA VERIFICATION - as the SECOND account (light session).
--    Nothing above proves anything about access: the owner bypasses the matrix.
-- ===========================================================================
-- 6a. GATE. If `who` is not the test user, stop.
-- SELECT current_user() AS who, is_account_group_member('analyst') AS in_analyst;

-- 6b. The column is gone, not hidden.
-- SELECT birth_year, COUNT(*) FROM prod_commerce.silver.customers
-- GROUP BY birth_year ORDER BY birth_year LIMIT 5;
-- EXPECT: real years, unmasked, readable. This is the point of the change.
-- RESULT, Sep 28 2026, SECOND ACCOUNT (light): PASS. 1940:8, 1941:23, 1942:20, 1943:23,
-- 1944:29 - real years, no mask, directly usable for age analysis. The analyst previously
-- got 1951-01-01 through a mask that could (and did) break; they now get the same
-- information with NO CONTROL IN THE PATH TO FAIL.
--
-- UNASKED-FOR OBSERVATION worth keeping: these counts are far below what 4940 rows over 69
-- years would give, and are consistent with the ~1684 EU rows. THE ROW FILTER IS STILL
-- APPLYING. Removing the column mask did not disturb it, because the filter operates on
-- `region` rather than on the column being read - so the new column inherited row-level
-- protection with no action at all. Two controls, independent, and only one was retired.
-- Guide point: structural anonymization of a column does NOT weaken row-level scope, and
-- the two should be reasoned about separately rather than as one "masking" story.

-- 6c. NEGATIVE CONTROL: the old column must be unresolvable, not merely empty.
-- SELECT date_of_birth FROM prod_commerce.silver.customers LIMIT 1;
-- EXPECT: UNRESOLVED_COLUMN. An error here is a PASS. A result is a FAIL.
-- RESULT, Sep 28 2026, SECOND ACCOUNT (light, in_analyst=true): PASS.
-- [UNRESOLVED_COLUMN.WITH_SUGGESTION] `date_of_birth` cannot be resolved. SQLSTATE 42703.
-- Gone, not hidden - and note the run reports "Last execution failed", which is the
-- expected-denial trap: the suite's own status says FAILED while the control says PASS.
--
-- TWO OPERATIONAL NOTES worth carrying into any persona suite:
--  * The batch ABORTED here, so the statement AFTER this one never ran. In a suite that
--    deliberately contains denials, a failing statement silently cancels every check below
--    it - so the positive controls must run SEPARATELY, or a suite can report a pass it
--    never actually performed.
--  * The error SUGGESTS other column names (`country`, `created_at`, `email`,
--    `national_id`, `region`). Harmless here because the analyst can already see all of
--    them, but worth knowing that error text ENUMERATES SCHEMA - if a design ever relies on
--    a persona not knowing a column exists, this message defeats it.
--
-- REDACTION: the screenshot of this step shows the second account's real email address in
-- current_user(). Crop it before any public use - it is not synthetic data.

-- 6d. POSITIVE CONTROL: the other masks still work, so this change retired ONE control
--     rather than quietly weakening the policy set.
-- SELECT first_name, email, national_id FROM prod_commerce.silver.customers LIMIT 3;
-- EXPECT: still masked. If these came back raw, section 5 dropped more than intended.
-- RESULT, Sep 28 2026, SECOND ACCOUNT (light): PASS - masks fully intact.
--   first_name  ***
--   email       r***@hotmail.de, s***@yahoo.com, c***@yahoo.com   (domain preserved)
--   national_id e01159252fdffff4cb..., fa58acef5ec45ffbf5..., 148a0e406902956f4...
-- So section 5 retired exactly ONE control and left the other six policies whole. Without
-- this check, "the drop succeeded" and "the drop took the wrong policy with it" look
-- identical from the owner's seat - the owner is EXCEPT-ed from all of them and would see
-- raw values either way.

-- ===========================================================================
-- 7. AFTER-STATE, and the thing most likely to be forgotten.
-- ===========================================================================
-- 7a. Schema and tags now.
SELECT c.column_name, c.data_type, t.tag_name, t.tag_value
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON t.schema_name = c.table_schema AND t.table_name = c.table_name
 AND t.column_name = c.column_name
WHERE c.table_schema = 'silver' AND c.table_name = 'customers'
  AND c.column_name IN ('date_of_birth','birth_year')
ORDER BY c.column_name, t.tag_name;
-- EXPECT: birth_year INT with classification=confidential and NO pii_type; date_of_birth absent.
-- RESULT, Sep 28 2026, PRIMARY (dark): exactly ONE row - birth_year INT, classification
-- confidential, no pii_type. date_of_birth ABSENT from information_schema.columns entirely,
-- which is the distinction that mattered: absent, not merely untagged. Verified BEFORE the
-- re-grant, for the reason in 4d.
--
-- THE CONTROL IS NOW STRUCTURAL. Nothing is masked here and nothing needs to be: the
-- precision that required protection was never written. Compare the two failure modes -
-- if the ABAC policy had been dropped by accident, a masked column would have started
-- serving raw dates silently; if this column were dropped by accident, every query naming
-- it fails loudly. Structural controls fail CLOSED and LOUD, display-time controls fail
-- OPEN and SILENT. That asymmetry is the argument for structure wherever the business can
-- live without the precision - and the reason to ask what precision is actually needed
-- before designing a mask at all.

-- 7b. THE BUILD SCRIPT MUST BE CHANGED TOO, or the next refill reintroduces the column.
--     09_silver.sql builds silver.customers with try_cast(date_of_birth AS DATE).
--     INSERT OVERWRITE from that script would recreate the exact risk this phase removed,
--     and nothing would report it - the table would simply have the column back.
--     THIS IS THE STEP THAT GETS SKIPPED. Do it in the same pass.
-- RESULT, Sep 28 2026: 09_silver.sql UPDATED - CREATE, INSERT OVERWRITE refill,
-- quality check, tag statement, column comment and owner persona check. quarantine_customers
-- DELIBERATELY KEEPS date_of_birth with pii_type='dob': it still holds full dates and still
-- needs the mask. Only silver.customers went structural.
--
-- A TRAP FOUND WHILE DOING IT, and the most transferable thing in this phase:
-- ALTER TABLE ADD COLUMN appends to the END of the live table, but the obvious edit to a
-- build script is to replace the old column IN PLACE (position 13). INSERT OVERWRITE matches
-- BY POSITION. So the obvious edit would have written birth_year into `marketing_consent` on
-- the next refill - a type-compatible-enough silent corruption, with the script and the table
-- each internally consistent and disagreeing only about order. Nothing reports this.
-- Both CREATE and refill now place birth_year LAST to match the live table.
-- `INSERT OVERWRITE ... BY NAME` would remove the positional dependency; recorded as a
-- recommendation to test, NOT as a verified instruction.

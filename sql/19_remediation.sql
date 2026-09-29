-- Remediation: the two defects the state-assertion suite found, and the statements that
-- fixed them. Run AFTER 17 and 18.
--
-- WHY THIS IS A SEPARATE SCRIPT RATHER THAN AN EDIT TO 06 AND 16.
-- Both fixes could have been folded back into the scripts that create these objects, and a
-- clean run would then end 20/20 with nothing to explain. That was the wrong trade. Folding
-- them in would make the build reproduce a state that was never built: the defects were real,
-- they survived a phase that was thinking about something else, and a whole-state check is
-- what caught them. Deleting the evidence to tidy the result would remove the only proof that
-- the suite does anything.
--
-- SO THE HONEST ORDER IS THE ONE THAT ACTUALLY HAPPENED. Run 01-18 in sequence and the suite
-- FAILS three controls:
--   A4  gold.customer_profile_anonymized is owned by whoever created it, not by the group
--   B1  governance.audit_log has 6 columns with no classification
--   B2  governance.audit_log has columns with no description
-- Those failures are correct. This script is what turns them green, and running 18 again
-- afterwards is the point: you see the suite catch something, then stop catching it.
--
-- Same reasoning that kept anonymization at 15/16 instead of renumbering it before the
-- masking it replaces. The build order is a record, not a presentation.

-- ===========================================================================
-- 1. DEFECT 1 - OWNERSHIP.
--    gold.customer_profile_anonymized was created in Phase 3b and ownership was never
--    transferred, so it stayed with the individual who ran the CREATE. Every other table in
--    the build belongs to commerce_data_owners.
--
--    It is the worst object in the build to get wrong. It is the one granted to
--    `account users`, so the most widely readable object here was personally owned - and an
--    object owned by a person leaves with that person.
--
--    THE LESSON, which is why this is a CHECK and not a note: ownership does not apply to
--    things created later. It is not learned once. A per-phase checklist verifies what that
--    phase was thinking about, and this table was created while thinking about anonymization.
-- ===========================================================================
ALTER TABLE prod_commerce.gold.customer_profile_anonymized OWNER TO `commerce_data_owners`;

-- Verify, and check all three gold tables rather than the one just changed - the defect was
-- never specific to this table, only discovered there.
SELECT table_name, table_owner
FROM prod_commerce.information_schema.tables
WHERE table_schema = 'gold' ORDER BY table_name;
-- EXPECT: commerce_data_owners on every row.

-- ===========================================================================
-- 2. DEFECT 2 - THE AUDIT LOG WAS UNCLASSIFIED.
--    Six columns, no classification, and it is the ONLY object in the build carrying real
--    personal data rather than synthetic: it reads actual user emails from system.access.
--    The one object whose contents are genuinely sensitive is the one nobody classified,
--    because classification was applied per-phase to the tables each phase created, and the
--    audit view was created by a different phase for a different reason.
--
--    NOTE THESE ARE `ALTER TABLE` STATEMENTS AGAINST A VIEW, and that is correct.
--    `ALTER VIEW` has no ALTER COLUMN branch, which led to a wrong conclusion here once:
--    that views cannot carry column tags at all, and three consequences drawn from it. All
--    wrong - the capability lives under the sibling statement. A missing branch in one
--    statement's grammar is not a missing capability.
-- ===========================================================================
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN event_time     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN user_email     SET TAGS ('classification' = 'restricted', 'pii_type' = 'email');
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN service_name   SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN action_name    SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN request_params SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.governance.audit_log ALTER COLUMN status_code    SET TAGS ('classification' = 'internal');

-- THE JUDGEMENT CALL ON request_params, recorded because it is the kind that gets made
-- silently. It is a MAP that can carry statement text and object names, and it is tempting to
-- tag it `confidential` to signal "this one deserves a closer look". That would be wrong: the
-- taxonomy defines confidential as a QUASI-IDENTIFIER, and request_params identifies no
-- person. Stretching a label to express unease corrupts the vocabulary for every future
-- reader. It is `internal`, with the unease written into its description instead.

COMMENT ON COLUMN prod_commerce.governance.audit_log.user_email IS 'Email address of the identity that performed the action. REAL personal data, not synthetic - this is the only column in the build that identifies an actual person. Inherited from system.access.audit, which records every query against this catalog.';
COMMENT ON COLUMN prod_commerce.governance.audit_log.request_params IS 'Request parameters of the audited action, as key/value pairs. Classified internal because it identifies no person, but it is the column to reassess first if this log is ever retained longer or shared wider: it can carry statement text and object names, which describe what people do even when they do not say who.';
COMMENT ON COLUMN prod_commerce.governance.audit_log.status_code IS 'HTTP-style status of the audited request. 200 means the action was permitted; a denial appears here as a non-200, which is what makes this view evidence of controls working rather than just of activity.';

-- A COUNT TO RECONCILE RATHER THAN SMOOTH OVER: the discovery pass recorded audit_log as
-- 6 columns / 6 missing classification / **2** missing description, and three COMMENT
-- statements are recorded above. So at least one of the three rewrote a description that
-- already existed rather than adding a missing one - most likely a comment inherited from
-- the underlying `system.access.audit` column. Stated rather than resolved: confirming it
-- would need the pre-fix state, which no longer exists. The end state is what was verified.

-- Verify both defects closed.
SELECT c.table_schema, c.table_name,
       COUNT(*)                                      AS columns_total,
       COUNT_IF(cls.tag_value IS NULL)               AS missing_classification,
       COUNT_IF(c.comment IS NULL OR c.comment = '') AS missing_description
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags cls
  ON  cls.schema_name = c.table_schema AND cls.table_name = c.table_name
  AND cls.column_name = c.column_name  AND cls.tag_name   = 'classification'
WHERE c.table_schema = 'governance'
GROUP BY 1, 2;
-- RESULT Sep 28 2026: 6 columns, 0 missing classification, 0 missing description.

-- ===========================================================================
-- 3. RE-RUN 18_state_suite.sql NOW. It should read 20 of 20.
--    That is the only step that proves this script did anything, and it is worth doing in
--    this order deliberately: a suite you have watched fail and then watched pass is worth
--    more than one that was green the first time you ran it.
-- ===========================================================================

-- ===========================================================================
-- APPENDIX - THE FAULT-SEEDING STATEMENTS (Sep 28 2026).
--
-- NOT EXECUTABLE. Every statement below is commented out on purpose: two of them change
-- ACCESS and one changes OWNERSHIP, and a reader running this file top to bottom must not
-- perform them by accident.
--
-- Section E3 of the suite records that ten controls were seeded and all ten fired. These are
-- the statements behind that claim. They were missing from this repo until Sep 29 2026, which
-- made the strongest evidence in the build the one part a reader could not reproduce.
--
-- THE METHOD THAT MATTERS: for a control that COMPARES an expectation against reality, seed
-- the EXPECTATION, not the system. A2, C1 and C4 were fault-tested by editing the literal
-- inside the query - adding a grant that does not exist to C1's expected array - which proves
-- the control fires with zero risk, zero cleanup and nothing left stranded. Only
-- presence/absence controls need the platform touched at all, and one empty throwaway table
-- seeded three of them at once, because an untagged table trips the coverage checks as well
-- as the object count.
--
-- SEQUENCING THAT KEPT IT SAFE: zero-risk query seeds first, then reversible object seeds,
-- then the two that change ACCESS, one at a time, each reversed and the reversal CONFIRMED
-- before the next was applied. A half-finished seed is how a maintenance re-run stranded two
-- personas' access earlier in this build.
--
-- IN A SEEDING RUN, PASS IS THE BAD OUTCOME. Label the statuses accordingly
-- ('FAIL (correct)' / 'PASS (WRONG - blind)') so a skim-read cannot misfile the result - but
-- do not reuse that wording for the post-cleanup check, where it reads backwards.
--
--   A1, B1, B2 - one throwaway table trips the object count AND both coverage checks:
--     CREATE TABLE prod_commerce.silver._seed_check (dummy INT);
--     DROP TABLE prod_commerce.silver._seed_check;
--
--   A3 - the platform default schema, dropped in Phase 1:
--     CREATE SCHEMA prod_commerce.default;
--     DROP SCHEMA prod_commerce.default;
--
--   B1 - a classification removed from a real column, then restored to its original value
--        (read from 03_tags.sql, not from memory):
--     ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment UNSET TAGS ('classification');
--     ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment SET TAGS ('classification' = 'internal');
--
--   B5 - THIS SEED NO LONGER WORKS, AND THAT IS THE GOOD OUTCOME:
--     ALTER TABLE prod_commerce.silver.customers ALTER COLUMN birth_year SET TAGS ('pii_type' = 'dob_date');
--     It SUCCEEDED when seeded, which proved the governed tag still allowed a value whose
--     policy had been retired - retiring a control is THREE steps (policy, function, allowed
--     value) and only two had been done. After the third, the identical statement is refused
--     with UC_TAG_POLICY_VALUE_NOT_ALLOWED. B5 is now the detective backstop behind a
--     preventive control, and its own fault-test is historical rather than repeatable.
--
--   A4 - OWNERSHIP. Changes who controls the most widely readable object in the build:
--     ALTER TABLE prod_commerce.gold.customer_profile_anonymized OWNER TO `<your-personal-account>`;
--     ALTER TABLE prod_commerce.gold.customer_profile_anonymized OWNER TO `commerce_data_owners`;
--     A4 NAMES its exceptions rather than counting them, which is why the seeded run could
--     show `audit_log, customer_profile_anonymized` and be read at a glance. A count-based
--     version would have said 2 != 1 and told you nothing about which.
--
--   C2 - ACCESS. This one gives the auditor read access to customer PII in silver. It is
--        exactly the defect the suite exists to catch, which is why it was worth seeding and
--        why it could not be left pending:
--     GRANT SELECT ON SCHEMA prod_commerce.silver TO `auditor`;
--     REVOKE SELECT ON SCHEMA prod_commerce.silver FROM `auditor`;
--
--   A2, C1, C4 - seeded in the QUERY, never in the system. Edit the expected literal (add a
--     schema to A2's array, a grant to C1's, a function to C4's), confirm FAIL, revert the
--     edit. No cleanup, nothing stranded, and no window in which the platform is wrong.
--
--   D3, D4, D5 - NOT SEEDED, deliberately. Seeding a k-anonymity control means publishing a
--     group below k, which is the one defect in this build with a real-world cost. Trust
--     these only through the CHECK constraint's own rejection test in 12_constraint_tests.sql.
-- ===========================================================================

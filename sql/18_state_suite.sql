-- Final state assertion, PART 2 of 2: THE SUITE.
-- Read-only by construction: no statement here writes, grants, or alters anything, so it is
-- safe to run against production and safe to re-run. That is deliberate - the maintenance
-- script in Phase 3b stranded access precisely because a re-run was not a no-op.
--
-- OUTPUT CONTRACT: every section returns ONE ROW PER CONTROL with the same five columns -
--   id | control | expected | actual | status
-- so the whole suite reads as a list of PASS/FAIL and not as a pile of result tabs nobody
-- scrolls to the end of. The EXPECTED value is a literal in the query, which is what makes a
-- failure diffable: you see what was wanted beside what is there.
--
-- BUILT FROM THE DESIGN, NOT FROM THE PHASES. Every per-phase check verified what that phase
-- was thinking about, which is exactly how six personally-owned tables survived for two days
-- and how the anonymized table and the audit view each came out wrong in a different
-- dimension. Those two were found by the DISCOVERY pass in Part 1, before a single
-- assertion existed. A suite derived from the phases inherits their blind spots; one derived
-- from the intended state asks what must be true and finds what nobody thought to check.
--
-- THREE KINDS OF EXPECTED VALUE, and mixing them up is how a suite becomes decoration:
--   DESIGN CONSTANT  the design mandates this exact value. Frozen as a literal here.
--   INVARIANT        the design mandates a RELATIONSHIP. Asserted as the relationship, so it
--                    survives a reload. `silver + quarantine = bronze`, never `silver=4940`.
--   FIXTURE FACT     true today, not required by the design. NOT asserted anywhere below.
--                    Freezing one is how a suite starts failing on correct changes.
--
-- WHAT THIS SUITE CANNOT DO - read section E before trusting a clean run.

-- ===========================================================================
-- SECTION A - VISIBILITY AND STRUCTURE
-- Run A first and read A1 before reading anything else in the suite.
-- ===========================================================================
SELECT 'A0' AS id, 'Identity running this suite' AS control,
       'a member of commerce_data_owners' AS expected,
       concat(current_user(), ' | owner=', cast(is_account_group_member('commerce_data_owners') AS STRING)) AS actual,
       CASE WHEN is_account_group_member('commerce_data_owners') THEN 'PASS' ELSE 'FAIL' END AS status

UNION ALL
-- A1 IS THE VISIBILITY POSITIVE CONTROL AND IT GATES THE REST OF THE SUITE.
-- `information_schema` is PERMISSION-FILTERED: it returns only what the running identity can
-- see. So every "0 rows missing" result below is really "0 that I can see", and a narrowed
-- identity produces a suite that passes MORE quietly, not less. Asserting the number of
-- objects this suite expects to inspect is what turns that silence into a failure.
SELECT 'A1', 'Objects inspectable (visibility control)',
       '10',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 10 THEN 'PASS'
            ELSE 'FAIL - fewer objects than expected means NARROWED SIGHT, not a clean build' END
FROM prod_commerce.information_schema.tables
WHERE table_schema <> 'information_schema'

UNION ALL
SELECT 'A2', 'Designed schemas present, and no stray ones',
       'bronze, gold, governance, landing, silver',
       concat_ws(', ', sort_array(collect_set(schema_name))),
       CASE WHEN sort_array(collect_set(schema_name))
                 = array('bronze','gold','governance','landing','silver')
            THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.schemata
WHERE schema_name <> 'information_schema'

UNION ALL
-- A3: the platform's `default` schema was dropped in Phase 1. Its return would mean
-- something re-created it, and nothing else in the suite would notice.
SELECT 'A3', 'Platform default schema still absent',
       '0',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.schemata
WHERE schema_name = 'default'

UNION ALL
-- A4: EXPECT ONE NAMED EXCEPTION, NOT ZERO. governance.audit_log must stay with an identity
-- that can read system.access; commerce_data_owners cannot. A check written to expect zero
-- would flag it forever, and the obvious way to silence that - transfer it - is exactly what
-- BREAKS the audit view. State the exception at the check, never suppress it.
SELECT 'A4', 'Every object owned by commerce_data_owners, except audit_log',
       'audit_log',
       coalesce(concat_ws(', ', sort_array(collect_set(table_name))), '(none)'),
       CASE WHEN sort_array(collect_set(table_name)) = array('audit_log') THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.tables
WHERE table_schema <> 'information_schema'
  AND table_owner <> 'commerce_data_owners'
ORDER BY id;

-- ===========================================================================
-- RESULT, SECTION A, Sep 28 2026, PRIMARY (dark): 5 of 5 PASS on the first run.
--   A0 owner=true | A1 10 objects | A2 the five designed schemas | A3 no `default`
--   A4 exactly one ownership exception: audit_log
-- A4 is the one that matters: it would have caught the personally-owned anonymized table
-- found hours earlier by the discovery pass, and it will catch the next one without anyone
-- remembering to look. Results for B, C and D are recorded at their own sections below.

-- ===========================================================================
-- SECTION B - METADATA AND VOCABULARY
-- ===========================================================================
SELECT 'B1' AS id, 'Columns with no classification tag' AS control,
       '0' AS expected,
       cast(COUNT(*) AS STRING) AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON  t.schema_name = c.table_schema AND t.table_name = c.table_name
  AND t.column_name = c.column_name  AND t.tag_name   = 'classification'
WHERE c.table_schema <> 'information_schema' AND t.tag_value IS NULL

UNION ALL
SELECT 'B2', 'Columns with no description', '0',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.columns
WHERE table_schema <> 'information_schema'
  AND (comment IS NULL OR comment = '')

UNION ALL
-- B3/B4: validate values against the ALLOWED ENUMERATION, not against the majority. A
-- consistency check that aligns to whatever is most common ratifies the most common error.
SELECT 'B3', 'classification values within the allowed vocabulary',
       'confidential, internal, restricted',
       concat_ws(', ', sort_array(collect_set(tag_value))),
       CASE WHEN size(array_except(collect_set(tag_value),
                      array('confidential','internal','restricted'))) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.column_tags
WHERE tag_name = 'classification' AND schema_name <> 'information_schema'

UNION ALL
-- !! B4 FAILED ON ITS FIRST RUN, Sep 28 2026, AND THE SUITE WAS WRONG, NOT THE DATA. !!
-- The expected list omitted `phone`. The discovery pass had returned SEVEN pii_type values
-- and the taxonomy header in 03_tags.sql lists the same seven; six were transcribed
-- here. That is the COP-currency failure again - a verified list that already existed in
-- this repo, degraded by being RETYPED instead of copied - committed while writing the very
-- suite meant to catch that class of defect.
-- Two things worth keeping from it: an assertion suite has the SAME failure modes as the
-- code it checks, so its expected values need the same discipline as any other enumeration;
-- and a FAIL is not evidence the system is wrong - the first question on any red row is
-- WHICH SIDE IS WRONG, and here it was the check.
--
-- NOTE `filter_key` is a THIRD governed tag, matched on by the row-filter policy. The
-- taxonomy header in 03_tags.sql documents only classification and pii_type, so a
-- vocabulary check written from that header would flag 4 correct columns as invalid - and
-- the natural "fix", deleting the tag, breaks the row filter. Documented here at the check.
SELECT 'B4', 'pii_type values within the allowed vocabulary',
       'address, dob, email, name, national_id, payment_card, phone',
       concat_ws(', ', sort_array(collect_set(tag_value))),
       CASE WHEN size(array_except(collect_set(tag_value),
                      array('address','dob','email','name','national_id','payment_card','phone'))) = 0
            THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.column_tags
WHERE tag_name = 'pii_type' AND schema_name <> 'information_schema'

UNION ALL
-- B5: `dob_date` was retired in Phase 3b along with its policy and function. A column still
-- carrying it would be tagged for a control that no longer exists - metadata pointing at
-- nothing, which reads as coverage on every inventory.
SELECT 'B5', 'Retired tag value dob_date is gone', '0',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.column_tags
WHERE tag_name = 'pii_type' AND tag_value = 'dob_date'
ORDER BY id;

-- ===========================================================================
-- SECTION C - ACCESS AND POLICY
-- RESULT, SECTION C, Sep 28 2026: 4 of 4 PASS once the three traps below were fixed.
-- C0 19 direct grants | C1 none missing | C2 none extra | C3 no BROWSE | C4 six functions.
-- A FOURTH, COSMETIC BUT WORTH THE FIX: `coalesce(concat_ws(...), '(none missing)')` never
-- fired, because concat_ws over an EMPTY array returns '' rather than NULL. The two most
-- important rows in the section displayed a BLANK cell, which reads as "the query did not
-- compute" rather than "nothing was missing". Replaced with an explicit COUNT(*)=0 case.
-- Same family as the empty-string-is-not-a-blank-cell trap: **an empty aggregate is not a
-- null, and a check that reports its good news as blank will be read as broken.**
--
-- !! THREE TRAPS FOUND HERE ON THE FIRST RUNS, Sep 28 2026 - all three silent. !!
--  0. The TABLE branch was missing `table_schema <> 'information_schema'` while the SCHEMA
--     branch had it. `account users` holds SELECT on ~31 information_schema views by
--     default, so the CTE returned 50 rows instead of 19 - and the 31 extras would have
--     landed in C2 as "grants outside the matrix", reading as a governance breach on the
--     most widely-shared principal in the build. **A filter applied to one branch of a UNION
--     and not the others is invisible: every branch parses, and only the total is wrong.**
--     Worth naming: my first theory was owner-derived privileges. It was wrong -
--     commerce_data_owners appears NOWHERE in these views. Grouping by grantee settled it in
--     one query where reasoning would have sent me to read ownership docs.
--  1. `inherited_from` holds the STRING 'NONE', not NULL. `inherited_from IS NULL` matched
--     NOTHING and the whole CTE returned ZERO rows - no error, just an empty set.
--  2. `privilege_type` is spelled with UNDERSCORES here (USE_SCHEMA, USE_CATALOG,
--     READ_VOLUME) while SHOW GRANTS displays them with SPACES. The expected list was built
--     from SHOW GRANTS output, so 11 of 19 rows would have mismatched. Same trap as
--     `table_schema` vs `schema_name`, now on VALUES rather than column names.
--
-- WHY C0 EXISTS, and it is design rather than caution. With an empty CTE:
--     C1 "every matrix grant present"         -> FAIL, 19 missing  (loud, investigated)
--     C2 "no grant exists OUTSIDE the matrix" -> **PASS**, nothing extra because nothing at all
-- The half of the access check that matters most would have reported CLEAN because it could
-- see nothing. **Any check whose clean result is an ABSENCE needs a positive control proving
-- it can see.** A1 gates the suite for that reason; C0 gates this section.
--
-- The privilege VIEWS make this a real assertion. `SHOW GRANTS` could not:
-- it returns a result set that is not a relation, so it cannot be unioned,
-- joined or compared - only read by eye, which is what this suite exists to
-- replace. Filtering on inherited_from = 'NONE' keeps it to DIRECT grants.
-- ===========================================================================
WITH actual_grants AS (
  SELECT concat_ws(' | ', grantee, privilege_type, 'CATALOG', catalog_name) AS g
  FROM prod_commerce.information_schema.catalog_privileges
  WHERE catalog_name = 'prod_commerce' AND inherited_from = 'NONE'
  UNION ALL
  SELECT concat_ws(' | ', grantee, privilege_type, 'SCHEMA', concat(catalog_name, '.', schema_name))
  FROM prod_commerce.information_schema.schema_privileges
  WHERE catalog_name = 'prod_commerce' AND schema_name <> 'information_schema'
    AND inherited_from = 'NONE'
  UNION ALL
  SELECT concat_ws(' | ', grantee, privilege_type, 'TABLE',
                   concat(table_catalog, '.', table_schema, '.', table_name))
  FROM prod_commerce.information_schema.table_privileges
  WHERE table_catalog = 'prod_commerce' AND table_schema <> 'information_schema'
    AND inherited_from = 'NONE'
),
expected_grants AS (
  SELECT explode(array(
    -- Catalog
    'auditor | BROWSE | CATALOG | prod_commerce',
    'auditor | USE_CATALOG | CATALOG | prod_commerce',
    'analyst | USE_CATALOG | CATALOG | prod_commerce',
    'data_engineer | USE_CATALOG | CATALOG | prod_commerce',
    -- Schemas
    'data_engineer | READ_VOLUME | SCHEMA | prod_commerce.landing',
    'data_engineer | USE_SCHEMA | SCHEMA | prod_commerce.landing',
    'data_engineer | SELECT | SCHEMA | prod_commerce.bronze',
    'data_engineer | USE_SCHEMA | SCHEMA | prod_commerce.bronze',
    'data_engineer | SELECT | SCHEMA | prod_commerce.silver',
    'data_engineer | USE_SCHEMA | SCHEMA | prod_commerce.silver',
    'analyst | SELECT | SCHEMA | prod_commerce.silver',
    'analyst | USE_SCHEMA | SCHEMA | prod_commerce.silver',
    'data_engineer | SELECT | SCHEMA | prod_commerce.gold',
    'data_engineer | USE_SCHEMA | SCHEMA | prod_commerce.gold',
    'analyst | SELECT | SCHEMA | prod_commerce.gold',
    'analyst | USE_SCHEMA | SCHEMA | prod_commerce.gold',
    'auditor | USE_SCHEMA | SCHEMA | prod_commerce.governance',
    -- Tables. The second one was added by Phase 3b and is NOT in 06_grants.sql:
    -- `account users` may read the anonymized table, which is the entire return on removing
    -- the identifiers. A check written from the original matrix would flag it forever, and
    -- revoking it to silence that would undo the phase.
    'auditor | SELECT | TABLE | prod_commerce.governance.audit_log',
    'account users | SELECT | TABLE | prod_commerce.gold.customer_profile_anonymized'
  )) AS g
)
SELECT 'C1' AS id, 'Every grant in the matrix is present' AS control,
       '0 missing' AS expected,
       CASE WHEN COUNT(*) = 0 THEN '(none missing)' ELSE concat_ws(' ;; ', collect_list(g)) END AS actual,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status
FROM (SELECT g FROM expected_grants EXCEPT SELECT g FROM actual_grants)

UNION ALL
-- C2 is the half that matters more. A missing grant is discovered the moment someone cannot
-- work; an EXTRA grant is discovered by nobody, ever.
SELECT 'C2', 'No grant exists outside the matrix', '0 extra',
       CASE WHEN COUNT(*) = 0 THEN '(none extra)' ELSE concat_ws(' ;; ', collect_list(g)) END,
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM (SELECT g FROM actual_grants EXCEPT SELECT g FROM expected_grants)

UNION ALL
-- C3: a platform default revoked in Phase 2. Its return is a silent regression that no data
-- check could ever see.
SELECT 'C3', 'account users holds no BROWSE on the catalog', '0',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.catalog_privileges
WHERE catalog_name = 'prod_commerce' AND grantee = 'account users' AND privilege_type = 'BROWSE'

UNION ALL
-- C4: six functions for seven policies, because mask_full serves BOTH mask_name_address and
-- mask_phone. VERIFIED from the policy definitions, not inferred from the arithmetic - a
-- prediction that lands on the right count for the wrong reason passes every check built
-- from it.
SELECT 'C4', 'Governance functions present',
       'filter_by_region, mask_dob, mask_email, mask_full, mask_last4, pseudonymize',
       concat_ws(', ', sort_array(collect_set(routine_name))),
       CASE WHEN sort_array(collect_set(routine_name))
                 = array('filter_by_region','mask_dob','mask_email','mask_full','mask_last4','pseudonymize')
            THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.routines
WHERE routine_schema = 'governance'
ORDER BY id;

-- ===========================================================================
-- SECTION D - DATA INVARIANTS
-- Relationships the design requires, not counts that happen to be true today.
-- ===========================================================================
SELECT 'D1' AS id, 'Customers: nothing lost between bronze and silver' AS control,
       'silver + quarantined = bronze' AS expected,
       concat(cast((SELECT COUNT(*) FROM prod_commerce.silver.customers) AS STRING), ' + ',
              cast((SELECT COUNT(*) FROM prod_commerce.silver.quarantine_customers) AS STRING), ' vs ',
              cast((SELECT COUNT(*) FROM prod_commerce.bronze.customers) AS STRING)) AS actual,
       CASE WHEN (SELECT COUNT(*) FROM prod_commerce.silver.customers)
                 + (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_customers)
                 = (SELECT COUNT(*) FROM prod_commerce.bronze.customers)
            THEN 'PASS' ELSE 'FAIL' END AS status

UNION ALL
SELECT 'D2', 'Orders: nothing lost between bronze and silver',
       'silver + quarantined = bronze',
       concat(cast((SELECT COUNT(*) FROM prod_commerce.silver.orders) AS STRING), ' + ',
              cast((SELECT COUNT(*) FROM prod_commerce.silver.quarantine_orders) AS STRING), ' vs ',
              cast((SELECT COUNT(*) FROM prod_commerce.bronze.orders) AS STRING)),
       CASE WHEN (SELECT COUNT(*) FROM prod_commerce.silver.orders)
                 + (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_orders)
                 = (SELECT COUNT(*) FROM prod_commerce.bronze.orders)
            THEN 'PASS' ELSE 'FAIL' END

UNION ALL
-- D3-D5: k-anonymity on all three published aggregates. Three tables, three separate
-- enforcements - a rule stated once and enforced in one place is a rule with two holes.
SELECT 'D3', 'k-anonymity: revenue_by_region_month', '>= 5',
       cast(MIN(customers_active) AS STRING),
       CASE WHEN MIN(customers_active) >= 5 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.gold.revenue_by_region_month

UNION ALL
SELECT 'D4', 'k-anonymity: customer_segment_profile', '>= 5',
       cast(MIN(customers) AS STRING),
       CASE WHEN MIN(customers) >= 5 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.gold.customer_segment_profile

UNION ALL
SELECT 'D5', 'k-anonymity: customer_profile_anonymized', '>= 5',
       cast(MIN(people_in_group) AS STRING),
       CASE WHEN MIN(people_in_group) >= 5 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.gold.customer_profile_anonymized

UNION ALL
-- D6: the anonymized table must carry NO pii_type on any column. That is the intended end
-- state and it needs stating, because "no policy applies here" and "nobody classified this"
-- look identical on an inventory.
SELECT 'D6', 'Anonymized table matches no masking policy', '0',
       cast(COUNT(*) AS STRING),
       CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END
FROM prod_commerce.information_schema.column_tags
WHERE schema_name = 'gold' AND table_name = 'customer_profile_anonymized'
  AND tag_name = 'pii_type'
ORDER BY id;

-- ===========================================================================
-- RESULT, SECTION D, Sep 28 2026: 6 of 6 PASS.
--   D1 4940 + 60 vs 5000 | D2 19565 + 435 vs 20000 | D3 5 | D4 129 | D5 5 | D6 0
-- NOTE D3 AND D5 BOTH SIT EXACTLY ON k=5. Phase 3b recorded that for the anonymized table;
-- revenue_by_region_month is in the same state and it had not been named. TWO of the three
-- published aggregates have NO margin - either is one departing customer away from the
-- suppression rule firing on the next build. D4 at 129 is the only one with room.
--
-- ===========================================================================
-- FULL SUITE RESULT, Sep 28 2026: 20 controls, 20 PASS (A 5, B 5, C 4, D 6).
--
-- BUT READ E3 BEFORE CALLING THAT A CLEAN BUILD. The suite failed FOUR times during its
-- first run and **every failure was the suite being wrong, not the system**: B4's expected
-- vocabulary dropped `phone`; C0 returned 0 because `inherited_from` is the STRING 'NONE';
-- C0 then returned 50 because the TABLE branch was missing the information_schema filter the
-- SCHEMA branch had; and C1/C2 displayed their good news as a blank cell. So the suite has
-- been seen to fail only on its OWN defects, and has NEVER been seen to correctly detect a
-- real fault. **That is not validation - it is the opposite.** E3's seeding is what turns
-- twenty green rows into evidence.
-- ===========================================================================

-- ===========================================================================
-- SECTION E - WHAT THIS SUITE CANNOT PROVE
-- Read this before treating a clean run as a clean build.
-- ===========================================================================
--
-- E1. IT PROVES NOTHING ABOUT ACCESS. Every query above runs as an identity that is EXCEPT-ed
--     from every mask and every row filter it is checking. The owner sees raw values whether
--     the controls work or not. A full PASS here is consistent with every persona being able
--     to read everything. Access is proven only by signing in as each persona and reading -
--     07_persona_tests.sql - and that remains a separate, manual, second-identity
--     exercise that this suite deliberately does not replace.
--
-- E2. IT CANNOT SEE CONSTRAINTS. `information_schema.check_constraints` is documented
--     "reserved for future use" and returns nothing; `SHOW TBLPROPERTIES` returns a result
--     set that is not a relation, so it cannot be queried. D3-D5 assert the INVARIANTS the
--     constraints enforce, which is not the same thing: a dropped constraint over clean data
--     produces an identical PASS. Until the platform exposes them, this is a MANUAL step:
--
--       SHOW TBLPROPERTIES prod_commerce.silver.orders;
--       SHOW TBLPROPERTIES prod_commerce.silver.customers;
--       SHOW TBLPROPERTIES prod_commerce.gold.revenue_by_region_month;
--       SHOW TBLPROPERTIES prod_commerce.gold.customer_segment_profile;
--       SHOW TBLPROPERTIES prod_commerce.gold.customer_profile_anonymized;
--
--     Read the `delta.constraints.*` keys and check the EXPRESSIONS, not just the names - a
--     constraint can be weakened to `>= 1` and still be present. Expect eleven in total.
--     An automated suite that quietly omits a control it cannot reach is worse than one that
--     names the hole, because the omission is invisible in a clean report.
--
-- E3. DONE Sep 28 2026 - TEN CONTROLS SEEDED, TEN FIRED CORRECTLY, ALL SEEDS REVERSED AND
--     THE REVERSAL VERIFIED. A1 A2 A3 A4 B1 B2 B5 C1 C2 C4 + C0/B4 already proven by their
--     own real defects earlier the same day.
--
--     METHOD WORTH REUSING: **for a control that COMPARES expectation to reality, seed the
--     EXPECTATION, not the system.** Adding a fake row to C1's expected array proves C1
--     fires with zero risk, zero cleanup and nothing to strand. Only presence/absence
--     controls (A1 A3 A4 B1 B2 B5 C2 D6) need the platform touched at all - and one empty
--     throwaway table seeded THREE of them at once, because an untagged table trips the
--     coverage checks as well as the count.
--
--     SEQUENCING THAT KEPT IT SAFE: zero-risk query seeds first, then reversible object
--     seeds, then the two that change ACCESS (C2's extra grant, A4's ownership transfer) one
--     at a time, each reversed and the reversal CONFIRMED before the next. C2's seed gave the
--     auditor read access to customer PII and A4's put the account-wide table under a
--     personal owner; both are exactly the defects this suite exists to catch, which is why
--     they were worth seeding and why neither could be left pending.
--
--     WHAT THE SEEDING BOUGHT BEYOND CONFIDENCE - it answered a question nobody asked.
--     B5's seed (`SET TAGS ('pii_type' = 'dob_date')`) SUCCEEDED rather than being refused,
--     which proved the governed tag STILL ALLOWED a value whose policy had been retired in
--     Phase 3b. **Retiring a control is THREE steps - policy, function, and the tag's
--     allowed value - and Phase 3b had done two.**
--     **FIXED THE SAME DAY, so the sentence above is history, not current state:** the value
--     was removed from the pii_type governed tag, and the identical statement is now refused
--     with UC_TAG_POLICY_VALUE_NOT_ALLOWED. The control is PREVENTIVE; B5 is now the
--     detective backstop rather than the only thing standing in the way. See
--     15_anonymize_silver.sql section 5b.
--
--     TWO DESIGN NOTES FROM RUNNING IT:
--     * A4 NAMES its exceptions rather than counting them, which is why the seeded run could
--       show `audit_log, customer_profile_anonymized` and be read at a glance. A count-based
--       version would have said 2 != 1 and told you nothing about which.
--     * In a seeding run, PASS is the BAD outcome. Label the statuses accordingly
--       ('FAIL (correct)' / 'PASS (WRONG - blind)') so a skim-read cannot misfile the result
--       - but do NOT reuse that wording for the post-cleanup check, where it reads backwards.
--
-- E3-ORIGINAL - SUPERSEDED BY E3 ABOVE; KEPT AS THE PLAN, NOT AS CURRENT STATE.
--     The paragraph below was written BEFORE the seeding run and says the suite has
--     never been seen to fail. That is no longer true - ten controls have now been
--     seeded and all ten fired. It is kept because the seed list is the reusable part.
--
--     AS WRITTEN: it has never been seen to fail, which means it is not yet known to work.
--     Before this suite is trusted, seed each control with the fault it claims to catch and
--     confirm it reports FAIL - then undo the seed. A check that has only ever printed PASS
--     is indistinguishable from one that never runs. Suggested seeds, each reversible:
--       A1  create a table in silver              -> expect A1 FAIL (11 not 10)
--       A3  CREATE SCHEMA prod_commerce.default   -> expect A3 FAIL, then DROP it
--       A4  transfer any table to a personal user -> expect A4 FAIL, then transfer back
--       B1  UNSET a classification tag on one column -> expect B1 FAIL, then re-set it
--       B5  SET pii_type='dob_date' on one column -> now REFUSED at write time
--           (UC_TAG_POLICY_VALUE_NOT_ALLOWED), since the value was removed from the governed
--           tag on Sep 28. B5 can therefore no longer be seeded from this path - which is
--           the good outcome, and means B5's own fault-test is now the HISTORICAL one
--           recorded above rather than one you can repeat.
--       C2  GRANT SELECT ON SCHEMA silver TO auditor -> expect C2 FAIL, then REVOKE
--       D5  (do not seed - it would publish a group below k. Trust D5 only after the
--            constraint has been fault-tested by its own rejection test.)
--     Seeding A4 or C2 changes access. Do it deliberately, in that order, and undo it in the
--     same sitting - a half-finished seed is the Phase 3b incident again.
--
-- E4. IT ASSERTS prod_commerce ONLY. dev_commerce carries the same schema design and
--     `data_engineer` holds ALL PRIVILEGES there by design. Extending the suite means
--     parameterising the catalog, and the dev matrix is deliberately different - copying
--     these expectations across would report failures that are the design working.

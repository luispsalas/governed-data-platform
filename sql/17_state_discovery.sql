-- Final state assertion, PART 1 of 2: STATE DISCOVERY.
-- Read-only. Prints the current state of every dimension the assertion suite will check.
--
-- WHY THIS EXISTS AS A SEPARATE STEP, rather than writing the assertions directly:
-- an assertion suite is only as good as its expected values, and the two ways to get those
-- wrong are opposite and both fatal.
--   * Invent them from memory -> the suite asserts a state that was never designed, and
--     every failure is the suite's fault. This build has already lost a currency list and a
--     status vocabulary to exactly that.
--   * Copy them from whatever the system currently holds -> the suite RATIFIES the current
--     state, defects included. It will then pass forever and report nothing, because it is
--     comparing the system against itself.
--
-- So: this script prints what IS. For each line of output, ask "does the DESIGN require
-- this?" before it becomes an expected value in Part 2. Where the answer is no, the right
-- assertion is usually an INVARIANT rather than the number - `silver + quarantine = bronze`
-- rather than `silver = 4940`, because the first survives a reload and the second does not.
--
-- RUN AS: the PRIMARY (dark). Part 2 states plainly what an owner-run pass cannot prove.

-- ===========================================================================
-- D0. IDENTITY AND VISIBILITY.
--     Every count below is filtered by what this identity can see
--     (`information_schema` is permission-filtered), so the identity is part
--     of the result, not context for it.
-- ===========================================================================
SELECT current_user()                                      AS who,
       is_account_group_member('commerce_data_owners')     AS is_owner;

-- ===========================================================================
-- D1. STRUCTURE
-- ===========================================================================
SELECT catalog_name, schema_name
FROM prod_commerce.information_schema.schemata
ORDER BY schema_name;
-- DESIGN SAYS: bronze, gold, governance, landing, silver (+ information_schema, platform).
-- `default` was dropped on purpose - if it is back, something re-created it.

SELECT table_schema, table_name, table_type, table_owner
FROM prod_commerce.information_schema.tables
WHERE table_schema <> 'information_schema'
ORDER BY table_schema, table_name;
-- COLUMN-NAME TRAP, hit on the first run (Sep 28 2026): `information_schema.TABLES` names
-- the schema column `table_schema`, while `information_schema.COLUMN_TAGS` names it
-- `schema_name`. Two views in the same schema, two names for the same concept, and a query
-- joining them needs both spellings - as the coverage check below does. UNRESOLVED_COLUMN
-- is the good outcome here; the bad one is a query that happens to parse against the wrong
-- view and reports a clean result for the wrong objects.
-- Gives four things at once: the object inventory, the count for the visibility control,
-- any object nobody designed, and the owner of each - the dimension no query asked about
-- until a screenshot exposed six personally-owned tables.

-- ===========================================================================
-- D2. METADATA COVERAGE
-- ===========================================================================
SELECT c.table_schema, c.table_name,
       COUNT(*)                                                   AS columns_total,
       COUNT_IF(cls.tag_value IS NULL)                            AS missing_classification,
       COUNT_IF(c.comment IS NULL OR c.comment = '')              AS missing_description
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags cls
  ON  cls.schema_name = c.table_schema AND cls.table_name = c.table_name
  AND cls.column_name = c.column_name  AND cls.tag_name   = 'classification'
WHERE c.table_schema <> 'information_schema'
GROUP BY 1, 2 ORDER BY 1, 2;
-- DESIGN SAYS: zero missing, everywhere. `internal` is a classification, not an absence.

-- ===========================================================================
-- D3. TAG VOCABULARY - the values actually in use, against the allowed list.
-- ===========================================================================
SELECT tag_name, tag_value, COUNT(*) AS columns_using
FROM prod_commerce.information_schema.column_tags
WHERE schema_name <> 'information_schema'
GROUP BY 1, 2 ORDER BY 1, 2;
-- DESIGN SAYS:
--   classification: internal | confidential | restricted
--   pii_type:       name | email | phone | national_id | address | dob | payment_card
-- NOTE `dob_date` was RETIRED in Phase 3b and must not appear. If it does, something still
-- carries it and the policy that matched it no longer exists - a tag pointing at nothing.

-- ===========================================================================
-- D4. ACCESS - what is actually granted, at the level it is actually held.
-- ===========================================================================
SHOW GRANTS ON CATALOG prod_commerce;
SHOW GRANTS ON SCHEMA prod_commerce.landing;
SHOW GRANTS ON SCHEMA prod_commerce.bronze;
SHOW GRANTS ON SCHEMA prod_commerce.silver;
SHOW GRANTS ON SCHEMA prod_commerce.gold;
SHOW GRANTS ON SCHEMA prod_commerce.governance;
SHOW GRANTS ON TABLE  prod_commerce.gold.customer_profile_anonymized;
SHOW GRANTS ON TABLE  prod_commerce.governance.audit_log;
-- ASK AT THE LEVEL THE GRANT LIVES. A table-level view lists privileges that REACH an
-- object and looked entirely normal on Sep 28 while SELECT had in fact been revoked at the
-- schema; only the schema-level view showed the loss.
--
-- TWO EXPECTED RESULTS THAT ARE NOT IN THE ORIGINAL MATRIX, and must be stated at the check
-- rather than discovered as violations:
--   * `account users` holds SELECT on gold.customer_profile_anonymized. Added by Phase 3b
--     and deliberate - it is the anonymized table, and being readable account-wide is the
--     entire return on removing the identifiers. A check written from 06_grants.sql
--     alone would flag it forever, and revoking it to silence that would undo the phase.
--   * `account users` must NOT hold BROWSE on the catalog. That was a platform default,
--     revoked on purpose. Its return is a real failure.

-- ===========================================================================
-- D5. POLICIES
-- ===========================================================================
SHOW POLICIES ON CATALOG prod_commerce;
-- DESIGN SAYS seven, all CATALOG-scoped: mask_dob, mask_email, mask_name_address,
-- mask_national_id, mask_payment_card, mask_phone, regional_access_eu.
-- mask_dob_date was retired in Phase 3b and must be absent.

SELECT routine_schema, routine_name
FROM prod_commerce.information_schema.routines
WHERE routine_schema = 'governance' ORDER BY routine_name;
-- The functions the policies call. A policy whose function is missing is a control that
-- cannot resolve; a function no policy calls is dead code that reads as coverage.

-- ===========================================================================
-- D6. DATA INVARIANTS - the relationships the design requires, not today's counts.
-- ===========================================================================
SELECT 'customers' AS entity,
       (SELECT COUNT(*) FROM prod_commerce.bronze.customers)            AS bronze,
       (SELECT COUNT(*) FROM prod_commerce.silver.customers)            AS silver,
       (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_customers) AS quarantined
UNION ALL
SELECT 'orders',
       (SELECT COUNT(*) FROM prod_commerce.bronze.orders),
       (SELECT COUNT(*) FROM prod_commerce.silver.orders),
       (SELECT COUNT(*) FROM prod_commerce.silver.quarantine_orders);
-- THE INVARIANT, not the numbers: silver + quarantined = bronze, for both entities.
-- Nothing is dropped between layers; a rejected row is set aside, never discarded. That
-- rule holds after any reload. `silver.customers = 4940` does not, and freezing it would
-- turn this suite into a snapshot test that fails on every legitimate change.

SELECT COUNT(*)                     AS groups_published,
       MIN(people_in_group)         AS smallest_group,
       SUM(people_in_group)         AS people_covered
FROM prod_commerce.gold.customer_profile_anonymized;
-- INVARIANT: smallest_group >= 5. The other two are facts about the fixture.

SELECT 'revenue_by_region_month' AS tbl, MIN(customers_active) AS smallest_group
FROM prod_commerce.gold.revenue_by_region_month
UNION ALL
SELECT 'customer_segment_profile', MIN(customers)
FROM prod_commerce.gold.customer_segment_profile;
-- INVARIANT: both >= 5. Same rule, three tables, three separate enforcements.

-- ===========================================================================
-- D7. CONSTRAINTS - which tables carry which, read from TBLPROPERTIES.
--     information_schema.CHECK_CONSTRAINTS is documented as "reserved for
--     future use" and returns nothing, so the properties are the only source.
-- ===========================================================================
SHOW TBLPROPERTIES prod_commerce.silver.orders;
SHOW TBLPROPERTIES prod_commerce.silver.customers;
SHOW TBLPROPERTIES prod_commerce.gold.revenue_by_region_month;
SHOW TBLPROPERTIES prod_commerce.gold.customer_segment_profile;
SHOW TBLPROPERTIES prod_commerce.gold.customer_profile_anonymized;
-- Look for keys starting `delta.constraints.`. DESIGN SAYS eleven in total: ten from
-- Phase 5 plus k_anonymity_min_group added by Phase 3b.

-- ===========================================================================
-- WHAT TO DO WITH THIS OUTPUT
-- ===========================================================================
-- For each result, decide which of three kinds it is - this is the whole judgement, and
-- getting it wrong is how an assertion suite becomes decoration:
--   DESIGN CONSTANT   the design mandates this exact value (5 schemas; 7 policies; the
--                     allowed tag values). Freeze it as a literal in Part 2.
--   INVARIANT         the design mandates a RELATIONSHIP (silver + quarantine = bronze;
--                     smallest group >= 5). Assert the relationship, never the number.
--   FIXTURE FACT      true today, not required by the design (4940 silver customers; 126
--                     published groups). Do NOT assert it. Freezing a fixture fact is how
--                     a suite starts failing on correct changes, and a suite that cries
--                     wolf is one nobody reads.
-- RESULTS OF THE FIRST DISCOVERY RUN, Sep 28 2026, PRIMARY (dark, is_owner=true).
-- TWO REAL DEFECTS, FOUND BEFORE A SINGLE ASSERTION WAS WRITTEN. That is the argument for
-- discovery being its own step: had Part 2 been written directly, both would have been
-- frozen in as expected values and the suite would have passed on them forever.
--
-- D1 STRUCTURE - PASS on schemas: bronze, gold, governance, landing, silver (+
-- information_schema). No `default`; the Phase 1 drop has held.
--
-- !! DEFECT 1 - OWNERSHIP, RECURRING, AND CREATED TODAY !!
--   gold.customer_profile_anonymized   MANAGED   <personal account>
-- Every other table is commerce_data_owners. This table was created in Phase 3b THIS
-- AFTERNOON and ownership was never transferred - in a session where the Sep 24 ownership
-- finding was discussed repeatedly, by the person who wrote the finding. "Ownership does not
-- apply to things created later" is not a lesson anyone learns once; it is a property of the
-- platform that needs a CHECK, which is precisely what this suite is for.
-- It is also the worst object to get wrong: it is the one granted to `account users`, so the
-- most widely readable object in the build was personally owned.
--   governance.audit_log under the same owner is the KNOWN, CORRECT exception - it must stay
--   with an identity that can read system.access. One named exception, not zero.
--
-- !! DEFECT 2 - THE AUDIT LOG IS UNCLASSIFIED !!
--   governance.audit_log   6 columns   6 missing classification   2 missing description
-- Every other object is at zero. And this is the ONLY object in the build carrying REAL
-- personal data rather than synthetic - it holds actual user emails from system.access.
-- The one object whose contents are genuinely sensitive is the one nobody classified,
-- because classification was applied per-phase to the tables each phase created, and the
-- audit view was created by a different phase for a different reason.
--
-- D3 VOCABULARY - one genuine surprise, not a defect:
--   classification: confidential 15, internal 62, restricted 25   (all three allowed values)
--   pii_type:       address 9, dob 2, email 3, name 6, national_id 3, payment_card 3
--   filter_key:     region 4
-- `dob_date` is ABSENT - Phase 3b's retirement is confirmed at the data level.
-- **`filter_key` is a THIRD governed tag that the taxonomy header in 03_tags.sql does
-- not document.** It names only classification and pii_type. The tag is legitimate - it is
-- what the row-filter policy matches on - so the DESIGN is right and its DESCRIPTION is
-- incomplete. A vocabulary check written from that header would flag 4 correct columns as
-- invalid, and the natural "fix" would be to delete the tag and break the row filter.
-- Same shape as the audit_log ownership exception: state it at the check.
--
-- CROSS-CHECK that the coverage numbers are internally consistent: 15+62+25 = 102 classified
-- against 108 columns total across the ten objects; the 6-column gap is exactly audit_log.
--
-- BOTH DEFECTS FIXED, Sep 28 2026, and verified: gold.customer_profile_anonymized is now
-- owned by commerce_data_owners (all three gold tables confirmed), and audit_log reads
-- 6 columns / 0 missing classification / 0 missing description.
--
-- A RETRACTION WORTH KEEPING, because the reasoning failed in a way that will recur.
-- Mid-fix I stated that "a view cannot carry column-level classification tags", having read
-- the ALTER VIEW grammar and found no ALTER COLUMN branch. I then drew three consequences
-- from it: that audit_log would show unclassified columns permanently, that a coverage check
-- would report an unfixable failure, and that views are second-class for CLASSIFICATION as
-- well as enforcement. **All three were wrong.** `ALTER TABLE ... ALTER COLUMN ... SET TAGS`
-- works perfectly well against a view; the capability simply lives under a different
-- statement. **The absence of a branch in one statement's grammar is not the absence of the
-- capability** - check the sibling statement before generalizing from a single doc page.
-- (What DOES still stand, established separately: a view can carry no column mask and no row
--  filter. Views are second-class for ENFORCEMENT, not for classification.)
--
-- THE JUDGEMENT CALL ON request_params, recorded because it is the kind that gets made
-- silently: it is a MAP that can carry statement text and object names, and it is tempting to
-- tag it `confidential` to signal "this one deserves a closer look". That would be wrong -
-- the taxonomy defines confidential as a QUASI-IDENTIFIER, and request_params identifies no
-- person. Stretching a label to express unease corrupts the vocabulary for every future
-- reader. It is tagged `internal`, which is correct, with the unease written into its COMMENT
-- instead: the column to reassess first if this log is retained longer or shared wider.
--
-- WHAT THE TWO DEFECTS HAVE IN COMMON, which is the finding rather than either one alone:
-- both objects were created by a phase that was thinking about something else. The
-- anonymized table was created while designing anonymization, and ownership was not on that
-- checklist. The audit view was created while wiring auditor access, and classification was
-- not on that one. **Per-phase checks verify what that phase was thinking about; a
-- whole-state check is the only thing that catches what no phase was thinking about.** That
-- is the entire argument for this suite, and it was demonstrated by the DISCOVERY step
-- before a single assertion had been written.
--
-- D4 ACCESS, Sep 28 2026 - every observed grant matches the matrix, and the key NEGATIVE
-- holds: `account users` has NO BROWSE on prod_commerce. That platform default was revoked
-- in Phase 2 and has stayed revoked; its return would be a silent regression that no data
-- check could see.
--   CATALOG     auditor BROWSE + USE CATALOG; analyst USE CATALOG; data_engineer USE CATALOG
--   silver      analyst SELECT + USE SCHEMA; data_engineer SELECT + USE SCHEMA
--   gold        analyst SELECT + USE SCHEMA; data_engineer SELECT + USE SCHEMA
--   governance  auditor USE SCHEMA only (the SELECT on audit_log is a TABLE grant)
--   gold.customer_profile_anonymized: `account users` SELECT at TABLE level (Phase 3b)
--
-- D5 POLICIES - seven, all CATALOG-scoped, mask_dob_date ABSENT.
-- SIX FUNCTIONS, which is exactly right, and the mapping was VERIFIED rather than assumed:
--   mask_name_address -> mask_full          mask_phone      -> mask_full   (SHARED)
--   mask_email        -> mask_email         mask_payment_card -> mask_last4
--   mask_dob          -> mask_dob           mask_national_id  -> pseudonymize
--   regional_access_eu -> filter_by_region
-- I had predicted six and named `pseudonymize` as the shared one. The count was right and
-- the reason was wrong - it is `mask_full` that serves two policies. **A prediction that
-- lands on the right number for the wrong reason will pass every check you write from it**,
-- so read the mapping, never infer it from the arithmetic.
-- Phase 3b's retirement is now confirmed at ALL THREE levels: tag value, policy, function.
--
-- D6 INVARIANTS - both hold exactly:
--   customers  bronze 5000  = silver 4940  + quarantined 60
--   orders     bronze 20000 = silver 19565 + quarantined 435
-- Nothing is lost between layers. THIS is what Part 2 asserts - not `silver = 4940`, which
-- is a fact about today's fixture and would fail on every legitimate reload.
--
-- D4 completed: bronze -> data_engineer SELECT + USE SCHEMA and NO ANALYST, which is the
-- critical negative of the whole matrix (bronze holds the raw card numbers and national
-- IDs). landing -> data_engineer READ VOLUME + USE SCHEMA. audit_log -> auditor SELECT at
-- TABLE level. Every grant observed matches the matrix; none exists outside it.
--
-- D7 CONSTRAINTS - readable from TBLPROPERTIES, and BETTER than expected: the value carries
-- the full EXPRESSION, not just the name.
--   silver.orders: amount_non_negative `amount >= 0`; currency_known `currency IN
--     ('USD','CAD','EUR','MXN','BRL','COP')`; order_date_plausible `order_date >=
--     DATE'2015-01-01' AND order_date <= DATE'2035-01-01'`; status_known `status IN
--     ('completed','refunded','cancelled')`
--   gold.customer_profile_anonymized: k_anonymity_min_group `people_in_group >= 5`
-- That matters: a constraint can be silently WEAKENED (>= 1 instead of >= 5) and still
-- exist. Asserting presence would pass that; asserting the expression catches it.
--
-- !! A GAP TO STATE RATHER THAN SKIP: CONSTRAINTS CANNOT BE ASSERTED FROM SQL. !!
-- `information_schema.check_constraints` is documented "reserved for future use" and returns
-- nothing, and `SHOW TBLPROPERTIES` yields a result set that is NOT a relation - it cannot be
-- selected from, joined, or unioned. So constraint existence cannot enter a PASS/FAIL query.
-- Only the INVARIANT a constraint enforces can be asserted (MIN(people_in_group) >= 5), and
-- that tests the outcome rather than the control: a dropped constraint over clean data looks
-- identical to an enforced one. Part 2 asserts the invariant automatically and keeps
-- constraint existence as a stated MANUAL step. An automated suite that quietly omits a
-- control it cannot reach is worse than one that names the hole.
--
-- PRIVILEGE VIEWS EXIST, which decides the design of Part 2's access section:
-- catalog_privileges, schema_privileges, table_privileges, routine_privileges,
-- volume_privileges. Grants ARE queryable, so "every grant in the matrix AND no grant
-- outside it" becomes a real assertion instead of output to eyeball. `SHOW GRANTS` alone
-- would not have allowed that - it is not a relation either.
--
-- DISCOVERY COMPLETE. Every dimension classified as design constant, invariant or fixture
-- fact; Part 2 can now be written without inventing a single expected value.

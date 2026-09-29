-- Phase 3b, Part B: an ANONYMIZED published table in gold.
-- Part A made silver structurally safe for ONE column. Part B produces an output that can be
-- shared more widely than silver ever could, because no row in it refers to a person.
--
-- =========================================================================================
-- THE DISTINCTION THIS PHASE EXISTS TO MAKE, and the mistake it refuses to make:
--
--   MASKING           reversible BY POLICY. The value is in the table; the platform hides it
--                     from some readers. Grant the wrong role, drop the policy, or query as
--                     the owner and it is right there. Part A's retired mask_dob_date.
--   PSEUDONYMIZATION  reversible WITH THE KEY, or by brute force when the keyspace is small.
--                     governance.pseudonymize(val, version) = sha2(concat(val, version)) has
--                     NO SECRET. customer_id is `C00001` - a five-digit sequence. An attacker
--                     who knows the format hashes all 100,000 candidates in under a second,
--                     and tries ten versions for good measure. The function is CORRECTLY
--                     NAMED; the error would be using it here and calling the result
--                     anonymized.
--   ANONYMIZATION     not reversible, because the information required to reverse it was
--                     never written. That is what this table does.
--
-- SO THIS TABLE CARRIES NO PER-PERSON KEY AT ALL - not even a hashed one. A hashed key is a
-- join key, and a join key is a re-identification path waiting for a second dataset. If
-- linkage is genuinely needed, the honest answer is a PSEUDONYMIZED table labelled as such,
-- with the salt held somewhere the readers of the table cannot reach - not this one.
-- =========================================================================================
--
-- K-ANONYMITY HERE IS NOT THE CONSTRAINT ALREADY BUILT IN PHASE 5. That one guards AGGREGATE
-- group sizes (`customers >= 5` on a grouped table). This is the ROW-LEVEL property: every
-- distinct COMBINATION of quasi-identifiers must appear at least k times, so no row can be
-- narrowed to one person by intersecting the columns that remain. A table can satisfy the
-- first and fail the second completely.
--
-- IDENTITY: sections 0-4 as the PRIMARY (dark). Sections 5-6 as the SECOND account (light).

-- ===========================================================================
-- 0. MEASURE BEFORE BUILDING. The generalization is a DESIGN DECISION and the
--    data decides it, not taste. Run all three and compare k.
-- ===========================================================================
SELECT current_user() AS who,
       is_account_group_member('commerce_data_owners') AS is_owner;   -- expect TRUE

-- 0a. NAIVE: keep location at country level. This is what "just drop the names" looks like.
SELECT COUNT(*)                                  AS combinations,
       MIN(n)                                    AS smallest_group,
       COUNT_IF(n < 5)                           AS combos_below_k,
       SUM(CASE WHEN n < 5 THEN n ELSE 0 END)    AS rows_at_risk
FROM (
  SELECT floor(birth_year / 10) * 10 AS decade, region, segment, country, COUNT(*) AS n
  FROM prod_commerce.silver.customers
  GROUP BY 1, 2, 3, 4
);
-- EXPECT this to fail badly. Country plus a decade plus a segment is a narrow box, and the
-- rows in the small boxes are precisely the identifiable people.

-- 0b. PROPOSED: location generalized to region, which is already the row-filter dimension.
SELECT COUNT(*)                                  AS combinations,
       MIN(n)                                    AS smallest_group,
       COUNT_IF(n < 5)                           AS combos_below_k,
       SUM(CASE WHEN n < 5 THEN n ELSE 0 END)    AS rows_at_risk
FROM (
  SELECT floor(birth_year / 10) * 10 AS decade, region, segment, COUNT(*) AS n
  FROM prod_commerce.silver.customers
  GROUP BY 1, 2, 3
);

-- 0c. WHERE the residual risk sits, so suppression is aimed rather than blanket.
SELECT floor(birth_year / 10) * 10 AS decade, region, segment, COUNT(*) AS n
FROM prod_commerce.silver.customers
GROUP BY 1, 2, 3
HAVING COUNT(*) < 5
ORDER BY n, decade;
-- EXPECT the extremes of the age range. Those rows are the oldest and youngest customers -
-- the ones a generalization that treats all bands equally protects least.
-- RESULT, Sep 28 2026, PRIMARY (dark) - the generalization decision, settled by measurement:
--
--   variant        combinations  smallest_group  combos_below_k  rows_at_risk
--   with country            168               3               6            22
--   region only              63              15               0             0
--
-- KEEPING COUNTRY WOULD HAVE PUBLISHED 6 GROUPS DESCRIBING 22 PEOPLE, the smallest being 3.
-- Those 22 are not an abstraction: they are the individuals a reader could isolate by
-- intersecting decade + country + segment. This is what "we removed the names" looks like
-- when nobody measures it - the table would have been titled anonymized and would not be.
--
-- Region-only passes with 3x margin (smallest 15 against k=5), so the HAVING in section 1
-- suppresses NOTHING today. Keep it anyway: it is what catches the next load, a new segment
-- value, or a region with fewer customers. A suppression rule that is inert on current data
-- is not a useless rule - it is a rule that has not been needed YET, and the day it fires is
-- the day nobody would have noticed the problem by hand.
--
-- OPTION RECORDED, NOT TAKEN: the 3x margin would also support FIVE-year age bands, which
-- doubles the analytic resolution and probably still clears k. Not done - the margin is the
-- safety budget for future data, and spending it to sharpen a demo trades a real property
-- for a cosmetic one. Revisit only with a business reason for the finer grain.

-- ===========================================================================
-- 1. BUILD. Direct identifiers are not masked here, not hashed here - they are
--    NOT SELECTED. The difference is the whole phase: a column that is absent
--    cannot be exposed by a policy change, a new grant, or an owner's query.
-- ===========================================================================
CREATE TABLE prod_commerce.gold.customer_profile_anonymized
COMMENT 'Anonymized customer profile, one row per customer with nothing that identifies one. Carries no name, email, phone, national ID, address or customer key - not masked or hashed, absent. Age is generalized to a decade band and location to region, and any combination of those appearing fewer than 5 times is withheld, so no row can be narrowed to a person by combining its columns. Intended to be shareable beyond the groups that may read silver. Source: silver.customers.'
AS
SELECT
    concat(cast(floor(birth_year / 10) * 10 AS STRING), 's') AS age_band,
    region,
    segment,
    marketing_consent,
    COUNT(*) AS people_in_group
FROM prod_commerce.silver.customers
WHERE birth_year IS NOT NULL
GROUP BY 1, 2, 3, 4
HAVING COUNT(*) >= 5;
-- NOTE THE SHAPE CHANGE: this is one row per GROUP, not per person. Publishing one row per
-- person and calling it anonymous is the harder claim to defend - every row still describes
-- an individual, and safety rests entirely on the generalization holding. Collapsing to
-- groups makes the k-anonymity property structural rather than something to be re-checked
-- every time a column is added. If per-person rows are genuinely required, that is a
-- different table with a different argument, and it needs a privacy review this does not.
--
-- The HAVING is the suppression. Rows below k are not published at all - they are not
-- nulled, bucketed or rounded, because each of those leaves a trace that a determined
-- reader can use to reconstruct what was withheld.

-- ===========================================================================
-- 2. PROVE THE PROPERTY, THEN ENFORCE IT.
-- ===========================================================================
-- 2a. Nothing below k survived. This must return 0 rows.
SELECT * FROM prod_commerce.gold.customer_profile_anonymized WHERE people_in_group < 5;

-- 2b. What suppression COST, stated as a number rather than assumed to be small. An
--     anonymization that silently drops a tenth of the population is a different dataset
--     from the one the reader thinks they have.
SELECT (SELECT SUM(people_in_group) FROM prod_commerce.gold.customer_profile_anonymized) AS people_published,
       (SELECT COUNT(*) FROM prod_commerce.silver.customers WHERE birth_year IS NOT NULL)  AS people_eligible;
-- RESULT, Sep 28 2026: people_published 4940, people_eligible 4940. ZERO SUPPRESSION - and
-- 2a returned 0 rows, so nothing below k survived either. Note this held even though the
-- build groups by FOUR columns (marketing_consent joins the quasi-identifier set) while
-- section 0 measured only three; the extra split did not push any group under 5.
--
-- THE CAVEAT THAT MUST TRAVEL WITH THIS NUMBER, or it teaches the wrong lesson: this
-- dataset is SYNTHETIC and close to uniformly distributed, which makes it unusually easy to
-- anonymize. Real customer data is clumpy - one dominant region, a long tail of small
-- segments, age skewed by product - and the same design against real data WOULD suppress a
-- visible fraction. The method is what transfers; the zero does not. Anyone quoting "we lost
-- no rows to k-anonymity" as evidence the technique is cheap is quoting a property of the
-- fixture, not of the technique.
--
-- Corollary: report suppression cost as a RATE on every publication, not once
-- at design time. It is the number that moves when the population changes, and it moves
-- without anyone editing the query.

-- 2c. Enforce, so a later refill cannot quietly publish a small group.
ALTER TABLE prod_commerce.gold.customer_profile_anonymized
  ADD CONSTRAINT k_anonymity_min_group CHECK (people_in_group >= 5);

-- 2d. FAULT-TEST IT. A constraint that has never refused anything is not known to work.
INSERT INTO prod_commerce.gold.customer_profile_anonymized
VALUES ('1930s', 'eu', 'retail', true, 3);
-- RESULT, Sep 28 2026: REJECTED - [DELTA_VIOLATE_CONSTRAINT_WITH_VALUES] CHECK constraint
-- k_anonymity_min_group (people_in_group >= 5) violated by row with values: people_in_group
-- : 3. The error names the constraint AND the offending value, so the reason needs no
-- investigation - the same self-explaining rejection recorded in Phase 5, and still the
-- sharpest contrast with a mask failure, which names neither.
--
-- TABLE SHAPE: 126 groups, smallest 5, largest 120, covering all 4940 people.
--
-- !! THIS CORRECTS THE MARGIN CLAIM RECORDED IN SECTION 0 !! That measurement used THREE
-- quasi-identifiers and found smallest_group 15 - read as "3x margin against k=5". The built
-- table groups by FOUR (marketing_consent joins the set) and the smallest group is EXACTLY
-- 5. The consent split consumed the ENTIRE margin, and the table now sits precisely on its
-- own threshold.
--
-- Three things follow, and the first two reverse what section 0 concluded:
--  * The suppression rule is NOT "inert". It is one person away from firing. A single
--    customer leaving a 5-person group triggers it on the next build.
--  * FIVE-YEAR AGE BANDS ARE NOW CLEARLY OFF. Section 0 recorded them as affordable on the
--    3-dimension margin. There is no margin. Not taking that option was right for a reason
--    that only became visible after the table was built.
--  * MEASURE k ON THE DIMENSIONS YOU WILL ACTUALLY PUBLISH, not on the ones you designed
--    with. Adding one BOOLEAN column - the least suspicious kind - cut the smallest group
--    from 15 to 5. Every column added to a published anonymized table is a k reduction, and
--    a boolean looks harmless precisely because it only has two values.
--
-- OPEN QUESTION worth stating rather than deciding here: k=5 is a convention, not a law. For
-- a genuinely public release k=10 or k=20 is the more common floor, and this table would not
-- meet either. It is adequate for the internal-sharing purpose it documents.

-- ===========================================================================
-- 3. CLASSIFY. An anonymized table still needs tags - `internal` is a
--    classification, not an absence of one, and an untagged column is
--    indistinguishable from one nobody has assessed yet.
-- ===========================================================================
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN age_band          SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN region            SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN segment           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN marketing_consent SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN people_in_group   SET TAGS ('classification' = 'internal');

-- NOTE what is deliberately absent: no pii_type on any column, so NO ABAC POLICY MATCHES
-- THIS TABLE AT ALL. That is the intended end state and it should be stated out loud,
-- because "no policy applies" and "we forgot to classify it" look identical on an
-- inventory. The tags above are what distinguishes the two.

ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN age_band COMMENT
  'Decade of birth, e.g. 1970s. The finest age grain published: a narrower band shrinks the groups and defeats the suppression rule.';
ALTER TABLE prod_commerce.gold.customer_profile_anonymized ALTER COLUMN people_in_group COMMENT
  'Number of customers sharing this combination of age band, region, segment and consent. Never below 5 - enforced by the k_anonymity_min_group constraint, not by convention. The smallest group in the current build is exactly 5, so this table sits on its threshold rather than above it.';

-- RESULT, Sep 28 2026: 5 tags + 2 comments applied, all OK.
-- The comment above was CORRECTED before it was applied: the first draft said the published
-- total is "deliberately smaller than the customer count", which was written before the
-- table existed and turned out to be FALSE - suppression removed nothing, 4940 of 4940.
-- A column description asserting a property the data does not have is the same defect class
-- as a stale finding, and it ships inside the catalog where it reads as authoritative.
-- Write descriptions AFTER measuring, or write them without the number.

-- ===========================================================================
-- 4. GRANT WIDELY - the point of the exercise.
--    silver.customers is readable by two groups. This is readable by everyone,
--    and that is the return on removing the identifiers.
-- ===========================================================================
GRANT SELECT ON TABLE prod_commerce.gold.customer_profile_anonymized TO `account users`;
SHOW GRANTS ON TABLE prod_commerce.gold.customer_profile_anonymized;
-- RESULT, Sep 28 2026 - three rows, and the LEVELS are the finding:
--   analyst        SELECT  SCHEMA  prod_commerce.gold
--   data_engineer  SELECT  SCHEMA  prod_commerce.gold
--   account users  SELECT  TABLE   prod_commerce.gold.customer_profile_anonymized
--
-- The broad grant is scoped to THIS ONE TABLE while every other grant in the build is at
-- SCHEMA level. That asymmetry is deliberate and worth teaching: granting `account users` at
-- schema level - matching the surrounding convention - would also have exposed
-- revenue_by_region_month and customer_segment_profile to everyone. Both carry k-anonymity
-- constraints so it would not have been a breach, but it would have been an exposure NOBODY
-- DECIDED, arrived at by consistency with neighbouring statements.
--
-- RULE: the wider the audience, the narrower the object. A grant to `account users` should
-- name a table, never a schema - and when the surrounding code is all schema-level, copying
-- the local style is exactly the wrong instinct. `account users` is also the group Phase 2
-- deliberately revoked BROWSE from on this catalog, which is what makes this statement
-- meaningful rather than routine: it is the only privilege that group holds here.

-- ===========================================================================
-- 5. PERSONA CHECK - as the SECOND account (light).
-- ===========================================================================
-- SELECT current_user() AS who;
-- SELECT * FROM prod_commerce.gold.customer_profile_anonymized ORDER BY people_in_group LIMIT 10;
-- EXPECT: readable, nothing masked, smallest group >= 5.
-- EXPECT ALSO: the ROW FILTER does not apply here - there is no `region` policy match
-- because no column carries a pii_type tag, and regional_access_eu matches on tag. CONFIRM
-- whether an EU-only persona sees all regions. Either answer is a finding: if it sees all,
-- the anonymized table is genuinely outside the policy set; if it sees only eu, the filter
-- reaches further than the tag suggests.
-- RESULT, Sep 28 2026, SECOND ACCOUNT (light, in_analyst=true) - THREE REGIONS VISIBLE:
--   eu     42 groups  1684 people
--   latam  42 groups  1249 people
--   na     42 groups  2007 people
-- So the ROW FILTER DOES NOT APPLY here. The technical reason is consistent with the model:
-- regional_access_eu matches on a TAG, and no column in this table carries pii_type.
--
-- !! THE FINDING OF PART B, and it is a business question wearing a technical disguise !!
-- eu = 1684 is EXACTLY the number of EU customers this analyst can see individually in
-- silver. The same person, restricted to 1684 rows there, reads aggregates covering all 4940
-- here. ANONYMIZING DATA CHANGES ITS AUDIENCE, WHICH MEANS IT ALSO BYPASSES SCOPE CONTROLS.
--
-- Whether that is correct cannot be answered from the platform. It depends on what the EU
-- row filter MEANS, and the two readings are indistinguishable in a privilege matrix:
--   "this analyst may only see EU customers' PERSONAL DATA"  -> this table is fine.
--   "this analyst may only KNOW ABOUT EU customers"          -> this table violates the
--        intent while passing every technical control, and no check will ever flag it.
-- Nobody has been asked which one the row filter encodes. That question belongs to the
-- business, and the answer has to be written down beside the policy - because the policy
-- itself cannot express the difference.
--
-- Guide consequence: an anonymized output is not automatically "safe to share widely". It is
-- safe with respect to IDENTIFICATION, which is the only thing k-anonymity speaks to. Scope,
-- purpose limitation and need-to-know are separate questions that anonymization does not
-- answer and can silently undo.

-- ===========================================================================
-- 6. THE ADVERSARIAL CHECK. Anonymization is a claim about what an ATTACKER
--    cannot do, so testing it means attempting the attack, not admiring the
--    schema. Run as the second account.
-- ===========================================================================
-- 6a. Can a published row be narrowed to one person? The smallest group is the best case
--     for an attacker; if that is >= 5, no combination of the published columns identifies
--     anyone.
-- SELECT MIN(people_in_group) AS best_case_for_attacker
-- FROM prod_commerce.gold.customer_profile_anonymized;
-- EXPECT >= 5.

-- 6b. Is there any join path back to a person? There should be no column in common with
--     silver.customers that is unique to a customer.
-- SELECT * FROM prod_commerce.gold.customer_profile_anonymized a
-- JOIN prod_commerce.silver.customers s
--   ON a.region = s.region AND a.segment = s.segment
-- LIMIT 5;
-- This join SUCCEEDS and that is fine: it matches thousands of rows to thousands of rows,
-- which is the definition of not identifying. The finding to record is that a successful
-- join is not a re-identification - the question is always the CARDINALITY of the match.
-- RESULT, Sep 28 2026: 69,160 matched pairs across 126 anonymized rows - roughly 549 silver
-- customers per anonymized row. THE JOIN SUCCEEDS AND NOTHING IS IDENTIFIED, which is the
-- point: a successful join is not a re-identification, and the only question that matters is
-- CARDINALITY. Anyone alarmed that "the tables can be joined" is measuring the wrong thing.
-- (Run as the OWNER, so it is a property of the full data rather than of an analyst's view.)
--
-- best_case_for_attacker = 5, confirmed. The two smallest groups are both `business` segment
-- - the thinner of the two - so that is where k will break first when the population moves.
-- Watch the smallest SEGMENT, not the smallest region.

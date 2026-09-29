-- Phase 2, Part A: ownership and grants (privilege matrix).
-- Prerequisites, done in the UI (Settings > Identity and access):
--   * Add yourself to commerce_data_owners BEFORE transferring ownership, or you lose
--     owner rights over the catalogs.
--   * A second test user exists (for persona tests); not in any group yet.

-- 0. Before-state (informational)
DESCRIBE CATALOG prod_commerce;          -- owner = your personal account
SHOW GRANTS ON CATALOG prod_commerce;
SHOW GRANTS ON CATALOG dev_commerce;

-- 1. Ownership to a group (Databricks: production catalogs and schemas are owned by groups).
-- Ownership is per object: children created by you stay yours unless transferred too.
ALTER CATALOG prod_commerce OWNER TO `commerce_data_owners`;
ALTER SCHEMA  prod_commerce.landing    OWNER TO `commerce_data_owners`;
ALTER SCHEMA  prod_commerce.bronze     OWNER TO `commerce_data_owners`;
ALTER SCHEMA  prod_commerce.silver     OWNER TO `commerce_data_owners`;
ALTER SCHEMA  prod_commerce.gold       OWNER TO `commerce_data_owners`;
ALTER SCHEMA  prod_commerce.governance OWNER TO `commerce_data_owners`;
ALTER VOLUME  prod_commerce.landing.raw_files OWNER TO `commerce_data_owners`;
ALTER TABLE   prod_commerce.bronze.customers  OWNER TO `commerce_data_owners`;
ALTER TABLE   prod_commerce.bronze.orders     OWNER TO `commerce_data_owners`;
ALTER CATALOG dev_commerce  OWNER TO `commerce_data_owners`;

-- 2. data_engineer: read everything in prod, write nothing (prod changes come from pipelines);
--    full rights in dev.
GRANT USE CATALOG ON CATALOG prod_commerce TO `data_engineer`;
GRANT USE SCHEMA, READ VOLUME ON SCHEMA prod_commerce.landing TO `data_engineer`;
GRANT USE SCHEMA, SELECT      ON SCHEMA prod_commerce.bronze  TO `data_engineer`;
GRANT USE SCHEMA, SELECT      ON SCHEMA prod_commerce.silver  TO `data_engineer`;
GRANT USE SCHEMA, SELECT      ON SCHEMA prod_commerce.gold    TO `data_engineer`;
GRANT ALL PRIVILEGES ON CATALOG dev_commerce TO `data_engineer`;

-- 3. analyst: curated layers only; never landing or bronze (raw PII). Silver is masked in Phase 3.
GRANT USE CATALOG ON CATALOG prod_commerce TO `analyst`;
GRANT USE SCHEMA, SELECT ON SCHEMA prod_commerce.silver TO `analyst`;
GRANT USE SCHEMA, SELECT ON SCHEMA prod_commerce.gold   TO `analyst`;

-- 4. auditor: sees what exists (metadata, tags, descriptions) but no rows; reads the audit log.
GRANT BROWSE ON CATALOG prod_commerce TO `auditor`;
-- BROWSE is NOT USE CATALOG. With BROWSE alone the auditor could not run any SQL in the
-- catalog - not even the audit view built for it (Sep 22 2026, confirmed with the membership
-- active): "User does not have USE CATALOG on Catalog 'prod_commerce'". BROWSE covers UI
-- discovery; querying needs USE CATALOG. This stays least privilege: USE CATALOG only allows
-- traversal, and reading data still needs USE SCHEMA + SELECT, which the auditor has only on
-- the governance schema and the audit view.
GRANT USE CATALOG ON CATALOG prod_commerce TO `auditor`;
-- Direct system-table grants fail in Free Edition (Sep 22 2026):
--   GRANT USE CATALOG ON CATALOG system TO `auditor`;
--   -> PERMISSION_DENIED: User does not have MANAGE on Catalog 'system'.
-- Only a metastore admin can grant on `system`. In an enterprise, that admin grants
-- auditors USE CATALOG system + USE SCHEMA/SELECT on system.access directly.
-- Lab alternative (also least privilege): a view exposing only this catalog's events.
-- A Unity Catalog view reads its source with the OWNER's rights, so it must stay owned by
-- an identity that can read system.access (the primary account) - do NOT transfer it
-- to commerce_data_owners, which has no system access.
CREATE OR REPLACE VIEW prod_commerce.governance.audit_log
COMMENT 'Audit events that concern the prod_commerce catalog, from system.access.audit. Owned by an identity with system-table access; auditors read this view instead of the system catalog.'
AS SELECT event_time, user_identity.email AS user_email, service_name, action_name,
          request_params, response.status_code AS status_code
   FROM system.access.audit
   WHERE to_json(request_params) LIKE '%prod_commerce%';
GRANT USE SCHEMA ON SCHEMA prod_commerce.governance TO `auditor`;
-- Use ON TABLE for views: on Sep 22 2026 `GRANT SELECT ON VIEW ...` ran without error but no
-- grant was visible afterwards (SHOW GRANTS and information_schema both empty); ON TABLE worked.
GRANT SELECT ON TABLE prod_commerce.governance.audit_log TO `auditor`;

-- 4c. Default discoverability grant. New catalogs come with `account users | BROWSE` (Databricks
-- default: every account user can see catalog metadata, never rows). Decision (Sep 22 2026):
-- revoke on prod (column names, tags and descriptions describe where PII lives; access comes only
-- from the matrix; auditor keeps its own BROWSE), keep on dev (discoverability helps, low risk).
REVOKE BROWSE ON CATALOG prod_commerce FROM `account users`;

-- 5. After-state (informational)
DESCRIBE CATALOG prod_commerce;          -- owner = commerce_data_owners
SHOW GRANTS ON CATALOG prod_commerce;        -- auditor BROWSE + USE CATALOG; analyst + data_engineer USE CATALOG; NO account users
SHOW GRANTS ON SCHEMA prod_commerce.bronze;  -- data_engineer only (no analyst: raw PII)
SHOW GRANTS ON SCHEMA prod_commerce.silver;  -- analyst + data_engineer: USE SCHEMA, SELECT
SHOW GRANTS ON CATALOG dev_commerce;         -- data_engineer ALL PRIVILEGES; account users BROWSE (kept on purpose)
SHOW GRANTS ON TABLE prod_commerce.governance.audit_log;   -- expect auditor | SELECT
SELECT COUNT(*) AS prod_commerce_events FROM prod_commerce.governance.audit_log;  -- expect > 0

-- 6. STANDING OWNERSHIP CHECK - re-run after EVERY phase that creates an object.
-- Ownership is per object and does NOT apply forward in time: the transfers above cover
-- what existed when they ran, and every table created afterwards belongs to its creator.
-- Phase 4 created six tables and all six were personally owned until Sep 24 2026, when
-- this was spotted on a LINEAGE SCREENSHOT - no query in the suite had ever asked who owns
-- anything. A control with no check degrades silently from the next CREATE onwards.
--
-- Note the expected result is ONE NAMED EXCEPTION, not zero. governance.audit_log must stay
-- with an identity that can read system.access; commerce_data_owners cannot. A check written
-- to expect zero would flag it forever, and the obvious way to silence that warning - transfer
-- it - is precisely what BREAKS the audit view. State the exception at the check.
SELECT table_schema, table_name, table_owner
FROM prod_commerce.information_schema.tables
WHERE table_schema IN ('bronze','silver','gold','governance')
  AND table_owner <> 'commerce_data_owners'
ORDER BY table_schema, table_name;
-- expect exactly: governance | audit_log | <the primary account>   (CONFIRMED Sep 24 2026)

-- Compute (UI): SQL Warehouses > Serverless Starter Warehouse > Permissions
--   data_engineer = CAN MANAGE, analyst = CAN USE, auditor = CAN USE

-- Phase 1, Part A: catalogs, schemas, landing volume.
-- Run in SQL Editor. Always use full catalog.schema.object names so nothing lands in the
-- shared `workspace` catalog by accident.

-- Done in the UI, not SQL (Free Edition, Sep 21 2026):
--   * Account groups: Settings > Identity and access > Groups > Add group
--     ("Add group to account and workspace"; Admin access OFF):
--     data_engineer, analyst, auditor, commerce_data_owners
--   * Governed tags: Catalog > Govern > Governed Tags > Create governed tag, then
--     "+ Add value" ONCE PER VALUE (a comma list typed into one field becomes a single value
--     and every SET TAGS fails with UC_TAG_POLICY_VALUE_NOT_ALLOWED). Check the page's count:
--     classification = internal | confidential | restricted                              -> "3 values"
--     pii_type       = name | email | phone | national_id | address | dob | payment_card -> "7 values"
--   * Catalogs were created in the UI; the SQL equivalent is:
CREATE CATALOG IF NOT EXISTS prod_commerce;
CREATE CATALOG IF NOT EXISTS dev_commerce;

-- Schemas: environment = catalog, layer = schema; `governance` holds policy functions
CREATE SCHEMA IF NOT EXISTS prod_commerce.landing;
CREATE SCHEMA IF NOT EXISTS prod_commerce.bronze;
CREATE SCHEMA IF NOT EXISTS prod_commerce.silver;
CREATE SCHEMA IF NOT EXISTS prod_commerce.gold;
CREATE SCHEMA IF NOT EXISTS prod_commerce.governance;
CREATE SCHEMA IF NOT EXISTS dev_commerce.landing;
CREATE SCHEMA IF NOT EXISTS dev_commerce.bronze;
CREATE SCHEMA IF NOT EXISTS dev_commerce.silver;
CREATE SCHEMA IF NOT EXISTS dev_commerce.gold;
CREATE SCHEMA IF NOT EXISTS dev_commerce.governance;

-- A new catalog gets an automatic `default` schema; drop it so the catalog holds only
-- designed schemas. No CASCADE, so this fails rather than deleting anything if it is not empty.
DROP SCHEMA IF EXISTS prod_commerce.default;
DROP SCHEMA IF EXISTS dev_commerce.default;

-- Landing volume for raw files (upload customers.csv and orders.csv in the UI:
-- Catalog > prod_commerce > landing > raw_files > Upload to this volume)
CREATE VOLUME IF NOT EXISTS prod_commerce.landing.raw_files;

-- Checks
SHOW SCHEMAS IN prod_commerce;          -- expect bronze, gold, governance, information_schema, landing, silver
SHOW SCHEMAS IN dev_commerce;           -- same list
SHOW VOLUMES IN prod_commerce.landing;  -- expect raw_files
-- Upload check (UI, volume Overview): customers.csv 808.98 KB = 828,395 bytes;
-- orders.csv 1.21 MB = 1,266,368 bytes, matching the local files byte for byte.

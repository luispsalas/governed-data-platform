-- Phase 1, Part C: classification with governed tags.
--   classification = who may see it:  internal | confidential | restricted
--   pii_type       = how it is masked: name | email | phone | national_id | address | dob | payment_card
-- restricted   = direct identifiers
-- confidential = quasi-identifiers (identify a person only in combination; input to anonymization)
-- internal     = everything else
-- Tag every column, including internal ones, so a missing tag can only mean "not classified yet".

-- Table level: the highest sensitivity the table contains
ALTER TABLE prod_commerce.bronze.customers SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.bronze.orders    SET TAGS ('classification' = 'restricted');

-- customers: restricted
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN first_name     SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN last_name      SET TAGS ('classification' = 'restricted', 'pii_type' = 'name');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN email          SET TAGS ('classification' = 'restricted', 'pii_type' = 'email');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN phone          SET TAGS ('classification' = 'restricted', 'pii_type' = 'phone');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN national_id    SET TAGS ('classification' = 'restricted', 'pii_type' = 'national_id');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN street_address SET TAGS ('classification' = 'restricted', 'pii_type' = 'address');

-- customers: confidential
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN customer_id    SET TAGS ('classification' = 'confidential');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN date_of_birth  SET TAGS ('classification' = 'confidential', 'pii_type' = 'dob');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN city           SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN postcode       SET TAGS ('classification' = 'confidential', 'pii_type' = 'address');

-- customers: internal
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN country           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN region            SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment           SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN marketing_consent SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN created_at        SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN _ingested_at      SET TAGS ('classification' = 'internal');

-- orders
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN card_number  SET TAGS ('classification' = 'restricted', 'pii_type' = 'payment_card');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN customer_id  SET TAGS ('classification' = 'confidential');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN order_id     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN order_date   SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN amount       SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN currency     SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN status       SET TAGS ('classification' = 'internal');
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN _ingested_at SET TAGS ('classification' = 'internal');

-- read_files adds a _rescued_data column (confirmed on customers, Sep 22 2026). Tag it restricted:
-- a malformed row can land raw PII there.
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN _rescued_data SET TAGS ('classification' = 'restricted');
ALTER TABLE prod_commerce.bronze.orders    ALTER COLUMN _rescued_data SET TAGS ('classification' = 'restricted');

-- Check: columns with no classification tag (expect 0 rows).
-- New tag assignments can take a few minutes to appear; re-run before concluding.
SELECT c.table_name, c.column_name
FROM prod_commerce.information_schema.columns c
LEFT JOIN prod_commerce.information_schema.column_tags t
  ON  t.schema_name = c.table_schema
  AND t.table_name  = c.table_name
  AND t.column_name = c.column_name
  AND t.tag_name    = 'classification'
WHERE c.table_schema = 'bronze' AND t.tag_name IS NULL;

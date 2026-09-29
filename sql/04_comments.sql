-- Phase 1: table and column descriptions for the bronze layer.
-- Descriptions state meaning, format, and why the column carries its classification tag.
-- Bronze stores every column as STRING; types are cast in silver.

-- Tables
COMMENT ON TABLE prod_commerce.bronze.customers IS
  'Raw customer records loaded as-is from /Volumes/prod_commerce/landing/raw_files/customers.csv. All columns are STRING; types are cast in silver. Synthetic data (Faker, seed 42) with about 1% deliberate quality defects for testing.';
COMMENT ON TABLE prod_commerce.bronze.orders IS
  'Raw order transactions loaded as-is from /Volumes/prod_commerce/landing/raw_files/orders.csv. All columns are STRING; types are cast in silver. Synthetic data with deliberate defects: negative amounts, future dates, orders for unknown customers.';

-- customers
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN customer_id       COMMENT 'Customer identifier (C followed by 5 digits). Pseudonymous key linking customers to orders; confidential because it can be joined back to a person.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN first_name        COMMENT 'Customer given name. Direct identifier (PII).';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN last_name         COMMENT 'Customer family name. Direct identifier (PII).';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN email             COMMENT 'Customer email address. Direct identifier (PII). About 1% empty by design, as a quality-test defect.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN phone             COMMENT 'Customer phone number in the local format of the customer country. Direct identifier (PII).';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN date_of_birth     COMMENT 'Date of birth as ISO 8601 text (YYYY-MM-DD); ages 18 to 85. Quasi-identifier: identifies a person in combination with postcode or city.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN national_id       COMMENT 'National identification number in the customer country format (DE, ES and CO use US-style numbers, a generator limitation). Direct identifier (PII). Kept as text to preserve leading zeros.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN street_address    COMMENT 'Street address line. Direct identifier (PII).';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN city              COMMENT 'City of residence. Quasi-identifier.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN postcode          COMMENT 'Postal code as text, leading zeros preserved. Quasi-identifier.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN country           COMMENT 'ISO 3166-1 alpha-2 country code: US, CA, DE, FR, ES, MX, BR, CO.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN region            COMMENT 'Sales region derived from country: NA, EU or LATAM. Drives region-based row filtering.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN segment           COMMENT 'Customer segment: retail, premium or business.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN marketing_consent COMMENT 'Marketing consent flag (True or False, as text). Records the consent basis relevant to GDPR and CCPA.';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN created_at        COMMENT 'Date the customer record was created, as ISO 8601 text (YYYY-MM-DD).';
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN _ingested_at      COMMENT 'Timestamp when the row was loaded into bronze.';

-- orders
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN order_id     COMMENT 'Order identifier (O followed by 6 digits).';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN customer_id  COMMENT 'Customer identifier; references customers.customer_id. About 0.3% point to unknown customers by design, as a quality-test defect.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN order_date   COMMENT 'Order date as ISO 8601 text (YYYY-MM-DD). A few future dates by design.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN amount       COMMENT 'Order amount in the currency given by the currency column, as text. A few negative values by design.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN currency     COMMENT 'ISO 4217 currency code: USD, CAD, EUR, MXN, BRL, COP.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN card_number  COMMENT 'Payment card number used for the order (synthetic, checksum-valid). Restricted; in a real system this column is in PCI DSS scope.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN status       COMMENT 'Order status: completed, refunded or cancelled.';
ALTER TABLE prod_commerce.bronze.orders ALTER COLUMN _ingested_at COMMENT 'Timestamp when the row was loaded into bronze.';

-- _rescued_data (added automatically by read_files)
ALTER TABLE prod_commerce.bronze.customers ALTER COLUMN _rescued_data COMMENT 'Added automatically by read_files: holds any values from a source row that did not fit the table schema. Expected empty; restricted because a malformed row could carry raw PII.';
ALTER TABLE prod_commerce.bronze.orders    ALTER COLUMN _rescued_data COMMENT 'Added automatically by read_files: holds any values from a source row that did not fit the table schema. Expected empty; restricted because a malformed row could carry raw PII.';

-- Rescued data should be empty: every source row fitted the schema
SELECT 'customers' AS tbl, COUNT_IF(_rescued_data IS NOT NULL) AS rescued_rows FROM prod_commerce.bronze.customers
UNION ALL SELECT 'orders', COUNT_IF(_rescued_data IS NOT NULL) FROM prod_commerce.bronze.orders;
-- expect 0 / 0

-- Check: columns still missing a description (expect 0 rows)
SELECT table_name, column_name
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'bronze' AND (comment IS NULL OR comment = '');

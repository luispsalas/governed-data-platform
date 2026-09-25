-- Phase 1, Part B: bronze (raw) tables.
-- Every column stays STRING (inferColumnTypes => false): type inference would turn
-- postcodes and national IDs into numbers and drop their leading zeros.
-- Types are cast in silver.

CREATE TABLE IF NOT EXISTS prod_commerce.bronze.customers AS
SELECT *, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/prod_commerce/landing/raw_files/customers.csv',
                format => 'csv', header => true, inferColumnTypes => false);

CREATE TABLE IF NOT EXISTS prod_commerce.bronze.orders AS
SELECT *, current_timestamp() AS _ingested_at
FROM read_files('/Volumes/prod_commerce/landing/raw_files/orders.csv',
                format => 'csv', header => true, inferColumnTypes => false);

-- Checks (results on Sep 22 2026 in comments)
SELECT 'customers' AS tbl, COUNT(*) AS n_rows FROM prod_commerce.bronze.customers
UNION ALL SELECT 'orders', COUNT(*) FROM prod_commerce.bronze.orders;
-- expect 5000 / 20000

-- Leading zeros survived ingestion. Use COUNT_IF: SUM(<boolean>) fails in Databricks SQL.
SELECT COUNT_IF(postcode LIKE '0%')    AS postcodes_leading_zero,
       COUNT_IF(national_id LIKE '0%') AS ids_leading_zero
FROM prod_commerce.bronze.customers;
-- expect 409 / 447 (the count taken from the local CSV)

DESCRIBE TABLE prod_commerce.bronze.customers;
-- expect every data column STRING, plus _ingested_at TIMESTAMP (and possibly _rescued_data)

SELECT table_name, COUNT(*) AS n_columns
FROM prod_commerce.information_schema.columns
WHERE table_schema = 'bronze'
GROUP BY table_name;
-- expect customers 16 (17 with _rescued_data), orders 8 (9 with _rescued_data)

/* ==========================================================================
   Project : Online Retail II - sales analysis
   File    : 01_staging_and_data_quality.sql
   Database: RetailAnalysis (SQL Server)
   Goal    : load raw data, convert types, audit data quality and define
             the row classification rules used later in 03_star_schema.sql
             (column row_type)

   Input   : dbo.raw_2009, dbo.raw_2010 (CSV imports, all columns nvarchar)
   Output  : dbo.stg_retail_raw    both files combined, still text
             dbo.stg_retail_typed  typed columns, input for 02_cleaning.sql

   Note    : all audit numbers in this file are measured on stg_retail_typed,
             i.e. BEFORE the cross-file duplicates are removed (02_cleaning.sql).

   Comment tags used in this file:
     QUESTION   what we wanted to know
     RESULT     what the numbers showed
     FINDING    what it means
     DECISION   how the rows will be treated
     TODO       result still to be filled in after re-running

   Contents
     01. Import check and raw staging
     02. Typed staging table
     03. Data quality audit
     04. Zero-price rows without customer (inventory adjustments)
     05. Zero-price rows with customer (free items)
     06. Summary of classification rules
   ========================================================================== */

USE RetailAnalysis;
GO


/* ==========================================================================
   01. IMPORT CHECK AND RAW STAGING
   Both CSV files are loaded as text (nvarchar), so that dirty values cannot
   break the import or be lost silently. Types are converted in section 02.
   ========================================================================== */

-- QUESTION: were both CSV files loaded completely?
-- RESULT  : 525,461 rows (2009-2010) and 541,910 rows (2010-2011)
SELECT 'raw_2009' AS table_name, COUNT(*) AS row_count FROM dbo.raw_2009
UNION ALL
SELECT 'raw_2010', COUNT(*) FROM dbo.raw_2010;

-- Quick look at the raw data (column names, formats)
SELECT TOP 5 * FROM dbo.raw_2009;

-- Combine both files into one raw table; nothing is removed.
-- source_file keeps the origin of each row (needed for the duplicate analysis).
DROP TABLE IF EXISTS dbo.stg_retail_raw;

SELECT
    Invoice,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    Price,
    Customer_ID,
    Country,
    'raw_2009' AS source_file
INTO dbo.stg_retail_raw
FROM dbo.raw_2009

UNION ALL

SELECT
    Invoice,
    StockCode,
    Description,
    Quantity,
    InvoiceDate,
    Price,
    Customer_ID,
    Country,
    'raw_2010'
FROM dbo.raw_2010;

-- Validation: 525,461 + 541,910 = 1,067,371
SELECT COUNT(*) AS row_count FROM dbo.stg_retail_raw;


/* ==========================================================================
   02. TYPED STAGING TABLE
   Columns are converted once, so later queries need no casting.
   ========================================================================== */

-- QUESTION: why did the first typed table lose most prices and dates?
-- RESULT  : the first attempt (plain TRY_CAST) failed on
--             InvoiceDate: 616,193 rows (58%)
--             Price      : 1,057,347 rows (99%)
-- FINDING : the CSV was saved with Polish regional settings:
--             Price       uses a decimal comma  ('7,95')
--             InvoiceDate uses dd.mm.yyyy       ('13.12.2009 09:58')
--           Without an explicit format, days <= 12 were read as months
--           (2 Dec became 12 Feb) and days > 12 became NULL.
-- DECISION: REPLACE(',', '.') for Price and style 104 (dd.mm.yyyy) for dates.
SELECT TOP 20
    Price,
    InvoiceDate
FROM dbo.stg_retail_raw
WHERE TRY_CAST(Price AS DECIMAL(10,2)) IS NULL
  AND Price IS NOT NULL
  AND TRY_CAST(InvoiceDate AS DATETIME2) IS NULL
  AND InvoiceDate IS NOT NULL;

-- Typed table (final version)
--   Description : trimmed, empty text becomes NULL
--   Price       : decimal comma replaced by a dot, 2 decimal places
--                 (prices below one penny are rounded, see the check below)
--   CustomerID  : empty text becomes NULL first (an empty string would convert to 0);
--                 cast via FLOAT because some IDs may be stored as '12345.0'
DROP TABLE IF EXISTS dbo.stg_retail_typed;

SELECT
    Invoice,
    StockCode,
    NULLIF(TRIM(Description), '')                                          AS Description,
    TRY_CAST(Quantity AS INT)                                              AS Quantity,
    TRY_CONVERT(DATETIME2, InvoiceDate, 104)                               AS InvoiceDate,
    TRY_CAST(REPLACE(Price, ',', '.') AS DECIMAL(10,2))                    AS Price,
    TRY_CAST(TRY_CAST(NULLIF(TRIM(Customer_ID), '') AS FLOAT) AS INT)      AS CustomerID,
    Country,
    source_file
INTO dbo.stg_retail_typed
FROM dbo.stg_retail_raw;

-- Validation 1: row count unchanged (expected 1,067,371)
SELECT COUNT(*) AS row_count FROM dbo.stg_retail_typed;

-- Validation 2: conversion must not create new NULLs (expected 0 | 0 | 0 | 0)
-- TODO: fill in the result after re-running
SELECT
    SUM(CASE WHEN Quantity    IS NOT NULL
              AND TRY_CAST(Quantity AS INT) IS NULL THEN 1 ELSE 0 END)                           AS bad_quantity,
    SUM(CASE WHEN InvoiceDate IS NOT NULL
              AND TRY_CONVERT(DATETIME2, InvoiceDate, 104) IS NULL THEN 1 ELSE 0 END)            AS bad_date,
    SUM(CASE WHEN Price       IS NOT NULL
              AND TRY_CAST(REPLACE(Price, ',', '.') AS DECIMAL(10,2)) IS NULL THEN 1 ELSE 0 END) AS bad_price,
    SUM(CASE WHEN NULLIF(TRIM(Customer_ID), '') IS NOT NULL
              AND TRY_CAST(TRY_CAST(NULLIF(TRIM(Customer_ID), '') AS FLOAT) AS INT) IS NULL
             THEN 1 ELSE 0 END)                                                                  AS bad_customer
FROM dbo.stg_retail_raw;

-- Validation 3: rounding of prices with more than 2 decimal places
-- QUESTION: does DECIMAL(10,2) round any price (e.g. 0,001 -> 0.00)?
--           Validation 2 cannot catch this: the conversion succeeds, but the value changes.
-- HYPOTHESIS: after the price fix, 18 extra zero-price rows appeared, the same
--           number as the PADS rows in section 05, so PADS may cost 0.001, not 0.
-- TODO    : run; if rows are found, consider DECIMAL(12,4) and rerun all scripts
SELECT
    Price                AS raw_price,
    StockCode,
    MAX(Description)     AS description,
    COUNT(*)             AS rows_count
FROM dbo.stg_retail_raw
WHERE CHARINDEX(',', Price) > 0
  AND LEN(Price) - CHARINDEX(',', Price) > 2          -- more than 2 digits after the comma
GROUP BY Price, StockCode
ORDER BY rows_count DESC;

-- Validation 4: sanity checks on the typed table
-- Expected: first_date 2009-12-01 | last_date 2011-12-09 | missing_customer 243,007 | customer_zero 0
-- TODO: fill in the result after re-running
SELECT
    MIN(InvoiceDate)                                       AS first_date,
    MAX(InvoiceDate)                                       AS last_date,
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END)    AS missing_customer,
    SUM(CASE WHEN CustomerID = 0 THEN 1 ELSE 0 END)        AS customer_zero
FROM dbo.stg_retail_typed;


/* ==========================================================================
   03. DATA QUALITY AUDIT (typed table, before deduplication)
   Size of each known issue. Feeds "Here's the situation" in the report.
   ========================================================================== */

-- QUESTION: how big is each data quality problem?
-- RESULT (first run, before the price fix):
--   total_rows 1,067,371 | missing_customer 243,007 (22.8%) | missing_description 4,382
--   price <= 0: 6,202    | negative_quantity 22,950         | cancellations 19,494
-- NOTE    : only price_zero_or_negative depends on the price fix. Section 03b shows
--           23 more rows with price <= 0 after the fix (2,745 -> 2,768), so the
--           expected new value is 6,225. TODO: confirm by re-running.
SELECT
    COUNT(*)                                                    AS total_rows,
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END)         AS missing_customer,
    SUM(CASE WHEN Description IS NULL THEN 1 ELSE 0 END)        AS missing_description,
    SUM(CASE WHEN Price <= 0 THEN 1 ELSE 0 END)                 AS price_zero_or_negative,
    SUM(CASE WHEN Quantity < 0 THEN 1 ELSE 0 END)               AS negative_quantity,
    SUM(CASE WHEN Invoice LIKE 'C%' THEN 1 ELSE 0 END)          AS cancellations
FROM dbo.stg_retail_typed;

-- QUESTION: what are the negative quantities that are NOT cancellations (no "C" prefix)?
-- FINDING : zero price, no customer, staff notes in Description
--           (lost, damaged, wet, MIA, smashed) = inventory write-offs, not sales
SELECT TOP 50
    Invoice, StockCode, Description, Quantity, Price, CustomerID
FROM dbo.stg_retail_typed
WHERE Quantity < 0
  AND Invoice NOT LIKE 'C%'
ORDER BY Invoice;

-- QUESTION: do ALL of them have price 0 and no customer?
-- RESULT  : 3,457 / 3,457 / 3,457 / 3,457 -> yes, hypothesis confirmed
--           (price 0 was read correctly before the fix, so this does not change)
SELECT
    COUNT(*)                                                             AS rows_total,
    SUM(CASE WHEN Price = 0 THEN 1 ELSE 0 END)                           AS price_zero,
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END)                  AS no_customer,
    SUM(CASE WHEN Price = 0 AND CustomerID IS NULL THEN 1 ELSE 0 END)    AS both_conditions
FROM dbo.stg_retail_typed
WHERE Quantity < 0
  AND Invoice NOT LIKE 'C%';

-- 03b.
-- QUESTION: what is left with price <= 0 once the write-offs are excluded?
-- RESULT (after the price fix): 2,768 rows
--   5 with negative price | 2,763 with price 0 | 2,679 without customer
--   (2,679 = 2,674 zero-price rows without customer + the 5 negative-price rows)
-- NOTE    : the first run gave 2,745 / 0 / 2,745 / 2,674. That was wrong:
--           prices with a decimal comma became NULL and silently dropped
--           out of the filter (lesson: always validate type conversions).
SELECT
    COUNT(*)                                             AS rows_in_scope,
    SUM(CASE WHEN Price < 0 THEN 1 ELSE 0 END)           AS price_negative,
    SUM(CASE WHEN Price = 0 THEN 1 ELSE 0 END)           AS price_zero,
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END)  AS no_customer
FROM dbo.stg_retail_typed
WHERE Price <= 0
  AND NOT (Quantity < 0 AND Invoice NOT LIKE 'C%');      -- exclude the write-offs

-- QUESTION: what are the 5 negative-price rows? (hypothesis: bad-debt adjustments)
-- RESULT  : 5 rows, all StockCode B "Adjust bad debt", no customer
-- DECISION: flag bad_debt_adjustment (StockCode = 'B' OR Price < 0), outside sales
SELECT
    Invoice, StockCode, Description, Quantity, Price, CustomerID, InvoiceDate
FROM dbo.stg_retail_typed
WHERE Price < 0;


/* ==========================================================================
   04. ZERO-PRICE ROWS WITHOUT CUSTOMER (inventory adjustments)
   Do positive adjustments simply reverse the negative ones?
   Match key: same StockCode and opposite quantity (+90 vs -90).
   ========================================================================== */

-- pos: zero-price additions without customer (stock increases)
-- neg: zero-price removals without customer, cancellations excluded (write-offs)
-- RESULT: pos 2,674 | neg 3,457
--         (unchanged by the price fix: the rows gained by the fix were
--          either negative prices or had a customer, see 03b)
WITH pos AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Quantity > 0
),
neg AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Invoice NOT LIKE 'C%' AND Quantity < 0
)
SELECT 'pos' AS list_name, COUNT(*) AS row_count FROM pos
UNION ALL
SELECT 'neg', COUNT(*) FROM neg;

-- QUESTION: where do the 4,382 missing descriptions come from?
-- RESULT  : inventory_adjustment 4,382 (100%), no other category
-- FINDING : missing descriptions only occur on stock adjustments, never on sales
-- DECISION: no separate rule, covered by the inventory_adjustment flag
SELECT
    CASE
        WHEN Price = 0 AND CustomerID IS NULL     THEN 'inventory_adjustment'
        WHEN Price = 0 AND CustomerID IS NOT NULL THEN 'free_item'
        WHEN Price < 0                            THEN 'negative_price'
        ELSE 'other'
    END AS row_category,
    COUNT(*) AS rows_missing_description
FROM dbo.stg_retail_typed
WHERE Description IS NULL
GROUP BY
    CASE
        WHEN Price = 0 AND CustomerID IS NULL     THEN 'inventory_adjustment'
        WHEN Price = 0 AND CustomerID IS NOT NULL THEN 'free_item'
        WHEN Price < 0                            THEN 'negative_price'
        ELSE 'other'
    END
ORDER BY rows_missing_description DESC;

-- Pair test, JOIN version (kept on purpose to show the pitfall)
-- RESULT : matched 152 | no_match 2,530 (sum 2,682 > 2,674)
-- FINDING: the JOIN counts a positive row several times when it matches
--          several negative rows, so the result is inflated
WITH pos AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Quantity > 0
),
neg AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Invoice NOT LIKE 'C%' AND Quantity < 0
)
SELECT
    CASE WHEN n.Invoice IS NULL THEN 'no_match' ELSE 'matched' END AS match_status,
    COUNT(*) AS row_count
FROM pos AS p
LEFT JOIN neg AS n
    ON  p.StockCode = n.StockCode
    AND p.Quantity  = -n.Quantity                    -- flip the sign to compare +90 with -90
GROUP BY CASE WHEN n.Invoice IS NULL THEN 'no_match' ELSE 'matched' END;

-- Pair test, EXISTS version (exact: each positive row counted once)
-- RESULT  : 2,674 positive rows | 144 with a negative mirror (5.4%)
-- FINDING : offsetting is rare. Adjustments are mostly one-sided stock movements,
--           and some pairs use a different code (79323G vs 79323GR).
-- DECISION: Price = 0 AND CustomerID IS NULL -> flag inventory_adjustment
--           (3,457 negative + 2,674 positive = 6,131 rows), excluded from sales
WITH pos AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Quantity > 0
),
neg AS (
    SELECT Invoice, StockCode, Quantity
    FROM dbo.stg_retail_typed
    WHERE Price = 0 AND CustomerID IS NULL AND Invoice NOT LIKE 'C%' AND Quantity < 0
),
pos_flagged AS (
    -- one row per positive adjustment, flag 1/0: does a negative mirror exist?
    SELECT
        p.Invoice,
        p.StockCode,
        p.Quantity,
        CASE WHEN EXISTS (
                 SELECT 1
                 FROM neg AS n
                 WHERE n.StockCode = p.StockCode
                   AND n.Quantity  = -p.Quantity
             ) THEN 1 ELSE 0 END AS has_match
    FROM pos AS p
)
SELECT
    COUNT(*)       AS positive_rows,
    SUM(has_match) AS positive_with_match
FROM pos_flagged;

-- Sample of positive zero-price rows without customer
-- FINDING: description mostly NULL, series of consecutive invoice numbers,
--          codes like DOT, gift_0001_80, C2 = stock intake or technical entries
SELECT TOP 50
    Invoice, StockCode, Description, Quantity, Price, CustomerID
FROM dbo.stg_retail_typed
WHERE Price = 0
  AND Quantity > 0
  AND Invoice NOT LIKE 'C%'
  AND CustomerID IS NULL
ORDER BY Invoice;


/* ==========================================================================
   05. ZERO-PRICE ROWS WITH CUSTOMER (free items)
   ========================================================================== */

-- Row-level preview
-- RESULT  : 71 rows in the first run (before the price fix)
-- TODO    : note the count after the fix (the final free_item count comes
--           from the row_type summary in 03_star_schema.sql, section 01)
SELECT
    Invoice, StockCode, Description, Quantity, InvoiceDate, Price, CustomerID
FROM dbo.stg_retail_typed
WHERE Price = 0
  AND Quantity > 0
  AND Invoice NOT LIKE 'C%'
  AND CustomerID IS NOT NULL
ORDER BY InvoiceDate, Invoice;

-- QUESTION: which products repeat and how many customers got them?
-- FINDING :
--   * about 50 regular products, usually 1 row for 1 customer, small quantities
--     (1-24 units): looks like manual freebies or replacements, reason not recorded
--   * PADS ("PADS TO MATCH ALL CUSHIONS"): 18 rows, 16 customers, 1 unit each
--     = the only recurring pattern (standard add-on to cushion orders);
--     possibly a 0.001 price rounded to 0, see section 02, validation 3
--   * non-product codes: M (Manual) 7 rows, TEST001 2 rows, BANK CHARGES 1 row
--   * outlier: 84826 (3D paper stickers), 12,540 units in one row
-- DECISION: non_product for M / TEST001 / BANK CHARGES, free_item for the rest
--           (including 84826). All of them are outside fact_sales, so revenue
--           and units sold are not affected.
SELECT
    StockCode,
    MAX(Description)           AS description,   -- one name per code (MAX picks any single variant)
    COUNT(*)                   AS rows_count,
    COUNT(DISTINCT CustomerID) AS customers,
    SUM(Quantity)              AS total_units
FROM dbo.stg_retail_typed
WHERE Price = 0
  AND Quantity > 0
  AND Invoice NOT LIKE 'C%'
  AND CustomerID IS NOT NULL
GROUP BY StockCode
ORDER BY rows_count DESC;

-- The 12,540-unit row: huge giveaway or data error?
-- TODO: run and describe the result (does not affect revenue, the row is a free_item)
SELECT Invoice, StockCode, Description, Quantity, Price, CustomerID, InvoiceDate
FROM dbo.stg_retail_typed
WHERE StockCode = '84826'
  AND Price = 0
  AND Quantity > 0
  AND CustomerID IS NOT NULL;


/* ==========================================================================
   06. SUMMARY OF CLASSIFICATION RULES
   --------------------------------------------------------------------------
   Implemented as column row_type in 03_star_schema.sql, section 01.
   Rules are applied in this order, the first match wins.
   --------------------------------------------------------------------------
   row_type               Condition                                  Treatment
   --------------------------------------------------------------------------
   inventory_adjustment   Price = 0 AND CustomerID IS NULL           outside sales,
                          (negative and positive quantity)           kept for shrinkage analysis

   bad_debt_adjustment    StockCode = 'B' OR Price < 0 (5 rows)      outside sales

   non_product            StockCode IN (POST, DOT, M, C2, D, S,      outside sales and
                          BANK CHARGES, ADJUST, ADJUST2, AMAZONFEE,  product analysis
                          CRUK, TEST001, TEST002)

   voucher                StockCode LIKE 'gift_0001%'                outside sales

   cancellation           Invoice LIKE 'C%'                          in fact_sales, negative amount,
                                                                     subtracted from revenue

   free_item              Price = 0 AND CustomerID IS NOT NULL       outside sales (revenue 0);
                          (includes the 84826 outlier)               units not counted

   sale                   everything else                            in fact_sales
   --------------------------------------------------------------------------
   Other decisions
   missing CustomerID     kept in revenue, excluded from per-customer analysis
   duplicates             cross-file copies in the overlap window (Dec 2010)
                          removed in 02_cleaning.sql; repeats within one file kept
   ========================================================================== */
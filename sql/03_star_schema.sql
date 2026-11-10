/* ==========================================================================
   Project : Online Retail II - sales analysis
   File    : 03_star_schema.sql
   Database: RetailAnalysis (SQL Server)
   Goal    : classify every row (row_type) and build the star schema
             used by Excel and Power BI

   Input   : dbo.stg_retail_dedup (from 02_cleaning.sql)
   Output  : dbo.dim_customer  (CustomerID PK, Country)
             dbo.dim_product   (StockCode PK, Description)
             dbo.dim_date      (FullDate PK, SalesYear, SalesMonth, SalesWeek,
                                WeekdayName, SalesQuarter)
             dbo.fact_sales    one row per invoice line, row_type 'sale' or 'cancellation'

   The script can be re-run from the top: every table is dropped and rebuilt.
   GO separates batches where a later statement needs a column or table
   created by an earlier one.

   Contents
     01. Row classification (row_type)
     02. dim_customer
     03. dim_product
     04. dim_date
     05. fact_sales
     06. Integrity checks
     07. Reconciliation and outliers
   ========================================================================== */



/* ==========================================================================
   01. ROW CLASSIFICATION (row_type)
   Rules from 01_staging_and_data_quality.sql, section 06.
   Order matters: the first matching rule wins, so e.g. a cancelled
   postage line is 'non_product', not 'cancellation'.
   ========================================================================== */

-- Add the column only if it does not exist yet (makes the script re-runnable)
IF COL_LENGTH('dbo.stg_retail_dedup', 'row_type') IS NULL
    ALTER TABLE dbo.stg_retail_dedup ADD row_type NVARCHAR(50) NULL;
GO

UPDATE dbo.stg_retail_dedup
SET row_type = CASE
        WHEN Price = 0 AND CustomerID IS NULL           THEN 'inventory_adjustment'  -- stock write-offs and intake
        WHEN StockCode = 'B' OR Price < 0               THEN 'bad_debt_adjustment'   -- "Adjust bad debt"
        WHEN StockCode IN ('POST','DOT','M','C2','D','S','BANK CHARGES',
                           'ADJUST','ADJUST2','AMAZONFEE','CRUK',
                           'TEST001','TEST002')         THEN 'non_product'           -- postage, fees, manual, tests
        WHEN StockCode LIKE 'gift_0001%'                THEN 'voucher'               -- gift vouchers
        WHEN Invoice LIKE 'C%'                          THEN 'cancellation'          -- customer returns
        WHEN Price = 0 AND CustomerID IS NOT NULL       THEN 'free_item'             -- freebies, e.g. PADS
        ELSE 'sale'
    END;

-- Summary of all row types
-- Source of the README numbers for vouchers and free items.
-- TODO: copy the voucher and free_item counts into the README data quality log
SELECT
    row_type,
    COUNT(*)               AS lines,
    SUM(Quantity * Price)  AS amount
FROM dbo.stg_retail_dedup
GROUP BY row_type
ORDER BY lines DESC;


/* ==========================================================================
   02. DIM_CUSTOMER
   One row per customer with a known CustomerID.
   ========================================================================== */

-- QUESTION: how many customers appear under more than one country?
-- TODO    : copy the count into the README data quality log
SELECT COUNT(*) AS customers_with_many_countries
FROM (
    SELECT CustomerID
    FROM dbo.stg_retail_dedup
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
    HAVING COUNT(DISTINCT Country) > 1
) AS multi_country;

-- List of those customers with all their countries
SELECT
    CustomerID,
    Country,
    COUNT(DISTINCT Invoice) AS invoice_count
FROM dbo.stg_retail_dedup
WHERE CustomerID IN (
    SELECT CustomerID
    FROM dbo.stg_retail_dedup
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID
    HAVING COUNT(DISTINCT Country) > 1
)
GROUP BY CustomerID, Country
ORDER BY CustomerID, invoice_count DESC;

-- DECISION: each customer gets the country with the most distinct invoices;
--           a tie goes to the alphabetically first country, so the result is
--           the same on every run
DROP TABLE IF EXISTS dbo.dim_customer;

WITH country_counts AS (
    SELECT
        CustomerID,
        Country,
        ROW_NUMBER() OVER (
            PARTITION BY CustomerID
            ORDER BY COUNT(DISTINCT Invoice) DESC, Country     -- most invoices first, then A-Z
        ) AS rn
    FROM dbo.stg_retail_dedup
    WHERE CustomerID IS NOT NULL
    GROUP BY CustomerID, Country
)
SELECT
    CustomerID,
    Country
INTO dbo.dim_customer
FROM country_counts
WHERE rn = 1;
GO

-- CustomerID stays INT, the same type as in fact_sales
-- (relationship columns in the Data Model must have the same data type)
ALTER TABLE dbo.dim_customer ALTER COLUMN CustomerID INT NOT NULL;
GO
-- NOT NULL and the primary key in separate batches (see dim_date)
ALTER TABLE dbo.dim_customer ADD CONSTRAINT PK_dim_customer PRIMARY KEY (CustomerID);
GO


/* ==========================================================================
   03. DIM_PRODUCT
   One row per StockCode. The same code has several description variants,
   so the longest one is kept (tie: alphabetically last).
   Note: the default collation is case-insensitive, so codes that differ
   only in letter case (e.g. 85123A / 85123a) are treated as one product.
   ========================================================================== */

DROP TABLE IF EXISTS dbo.dim_product;

WITH product_descriptions AS (
    SELECT
        StockCode,
        Description,
        ROW_NUMBER() OVER (
            PARTITION BY StockCode
            ORDER BY COUNT(*) DESC, LEN(Description) DESC   -- most frequent, then longest
        ) AS rn
    FROM dbo.stg_retail_dedup
    WHERE Description IS NOT NULL
      AND row_type IN ('sale', 'cancellation')               -- real product names only
    GROUP BY StockCode, Description
)
SELECT StockCode, Description
INTO dbo.dim_product
FROM product_descriptions
WHERE rn = 1;
GO

ALTER TABLE dbo.dim_product ALTER COLUMN StockCode NVARCHAR(50) NOT NULL;
GO
ALTER TABLE dbo.dim_product ADD CONSTRAINT PK_dim_product PRIMARY KEY (StockCode);
GO

-- check: should return 0
SELECT COUNT(*) AS missing_product
FROM dbo.fact_sales AS f
LEFT JOIN dbo.dim_product AS p ON f.StockCode = p.StockCode
WHERE p.StockCode IS NULL;


/* ==========================================================================
   04. DIM_DATE
   One row per day that occurs in the data (no gaps are filled).
   Note: SalesWeek depends on SET DATEFIRST and WeekdayName on the session
   language (e.g. 'Monday' vs 'poniedziałek').
   ========================================================================== */

DROP TABLE IF EXISTS dbo.dim_date;

DECLARE @start DATE = '2009-01-01', @end DATE = '2011-12-31';   -- pełne lata

SELECT
    d.FullDate,
    YEAR(d.FullDate)               AS SalesYear,
    MONTH(d.FullDate)              AS SalesMonth,
    DATEPART(WEEK, d.FullDate)     AS SalesWeek,
    DATENAME(WEEKDAY, d.FullDate)  AS WeekdayName,
    DATEPART(QUARTER, d.FullDate)  AS SalesQuarter
INTO dbo.dim_date
FROM (
    SELECT TOP (DATEDIFF(DAY, @start, @end) + 1)
        DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1, @start) AS FullDate
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
) AS d;
GO
ALTER TABLE dbo.dim_date ALTER COLUMN FullDate DATE NOT NULL;
GO
ALTER TABLE dbo.dim_date ADD CONSTRAINT PK_dim_date PRIMARY KEY (FullDate);

SELECT
    MIN(FullDate)                                   AS first_date,
    MAX(FullDate)                                   AS last_date,
    COUNT(*)                                        AS days_in_table,
    DATEDIFF(DAY, MIN(FullDate), MAX(FullDate)) + 1 AS days_expected
FROM dbo.dim_date;


/* ==========================================================================
   05. FACT_SALES
   Grain: one row per invoice line with row_type 'sale' or 'cancellation'.
   TotalAmount = Quantity * Price, so cancellations (negative quantity)
   carry a negative amount and net revenue is a plain SUM(TotalAmount).
   No primary key: identical lines on one invoice are real repeated
   purchases (see 02_cleaning.sql, section 04).
   ========================================================================== */

DROP TABLE IF EXISTS dbo.fact_sales;

SELECT
    Invoice,
    CustomerID,                                          -- NULL for guest lines, shown as (blank) country
    StockCode,
    CAST(InvoiceDate AS DATE)  AS FullDate,
    Quantity,
    Price,
    Quantity * Price           AS TotalAmount,
    row_type
INTO dbo.fact_sales
FROM dbo.stg_retail_dedup
WHERE row_type IN ('sale', 'cancellation');

-- Fact table check (numbers used in the README)
-- RESULT: sale         1,015,155 lines | 19,701,806.27 | quantity 1 to 80,995
--         cancellation    17,974 lines |   -719,692.94 | quantity -80,995 to -1
SELECT
    row_type,
    COUNT(*)          AS lines,
    SUM(TotalAmount)  AS amount,
    MIN(Quantity)     AS min_qty,
    MAX(Quantity)     AS max_qty
FROM dbo.fact_sales
GROUP BY row_type;

-- Headline figures
-- RESULT: gross 19,701,806.27 | returns 719,692.94 | net 18,982,113.33 | return rate 3.65%
SELECT
    SUM(CASE WHEN row_type = 'sale'         THEN TotalAmount ELSE 0 END)  AS gross_revenue,
    -SUM(CASE WHEN row_type = 'cancellation' THEN TotalAmount ELSE 0 END) AS returns,
    SUM(TotalAmount)                                                      AS net_revenue,
    -SUM(CASE WHEN row_type = 'cancellation' THEN TotalAmount ELSE 0 END)
        / SUM(CASE WHEN row_type = 'sale'   THEN TotalAmount ELSE 0 END)  AS return_rate
FROM dbo.fact_sales;


/* ==========================================================================
   06. INTEGRITY CHECKS
   Every key in fact_sales must exist in its dimension.
   Expected: 0 | 0 | 0 (CustomerID NULL is allowed and not counted)
   ========================================================================== */

SELECT
    SUM(CASE WHEN f.CustomerID IS NOT NULL AND c.CustomerID IS NULL THEN 1 ELSE 0 END) AS missing_customer,
    SUM(CASE WHEN p.StockCode IS NULL THEN 1 ELSE 0 END)                               AS missing_product,
    SUM(CASE WHEN d.FullDate  IS NULL THEN 1 ELSE 0 END)                               AS missing_date
FROM dbo.fact_sales AS f
LEFT JOIN dbo.dim_customer AS c ON f.CustomerID = c.CustomerID
LEFT JOIN dbo.dim_product  AS p ON f.StockCode  = p.StockCode
LEFT JOIN dbo.dim_date     AS d ON f.FullDate   = d.FullDate;


/* ==========================================================================
   07. RECONCILIATION AND OUTLIERS
   ========================================================================== */

-- QUESTION: why does the audit show 19,494 cancellations but fact_sales only 17,974?
-- Step 1: how many "C" lines were removed as cross-file duplicates?
SELECT 'stg_retail_typed (before dedup)' AS stage, COUNT(*) AS c_lines
FROM dbo.stg_retail_typed
WHERE Invoice LIKE 'C%'
UNION ALL
SELECT 'stg_retail_dedup (after dedup)', COUNT(*)
FROM dbo.stg_retail_dedup
WHERE Invoice LIKE 'C%';

-- Step 2: which row_type did the remaining "C" lines get?
-- (only 'cancellation' goes to fact_sales; the others matched an earlier rule)
-- TODO: copy the split into the README data quality log
SELECT
    row_type,
    COUNT(*) AS c_lines
FROM dbo.stg_retail_dedup
WHERE Invoice LIKE 'C%'
GROUP BY row_type
ORDER BY c_lines DESC;

-- QUESTION: are the largest sale and the largest return (quantity 80,995)
--           one order that was cancelled right away?
-- TODO    : check Invoice / C-Invoice, date, customer and product, then note in the README
SELECT TOP 10
    f.Invoice,
    f.FullDate,
    f.CustomerID,
    f.StockCode,
    p.Description,
    f.Quantity,
    f.Price,
    f.TotalAmount,
    f.row_type
FROM dbo.fact_sales AS f
LEFT JOIN dbo.dim_product AS p ON f.StockCode = p.StockCode
ORDER BY ABS(f.Quantity) DESC;


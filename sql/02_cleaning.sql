/* ==========================================================================
   Project : Online Retail II - sales analysis
   File    : 02_cleaning.sql
   Database: RetailAnalysis (SQL Server)
   Goal    : find and size duplicates, decide how to remove them,
             then build clean_retail

   Contents
     01. Duplicates: size and origin
     02. Date range of each source file
     03. Do cross-file duplicates fall inside the overlap window?
     04. Duplicates within one file
     05. Balance of copies between files
   ========================================================================== */


/* ==========================================================================
   01. DUPLICATES: SIZE AND ORIGIN
   ========================================================================== */

-- RESULT  : across_files   22,118 groups | 44,878 rows | 22,760 extra
--           within_one_file 10,705 groups | 22,196 rows | 11,491 extra
--           total extra rows = 34,251 (3.2% of the table)
-- NOTE    : "extra" assumes we keep one row per group. That is only right for
--           artefact duplicates, not for real repeats (see sections 04 and 05).
WITH dup_groups AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country,
        COUNT(*)                    AS copies,
        COUNT(DISTINCT source_file) AS files
    FROM dbo.stg_retail_typed
    GROUP BY
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country
    HAVING COUNT(*) > 1                       -- only groups with at least 2 rows
)
SELECT
    CASE WHEN files = 2 THEN 'across_files' ELSE 'within_one_file' END AS duplicate_type,
    COUNT(*)           AS duplicate_groups,       -- number of groups
    SUM(copies)        AS rows_in_groups,         -- all rows in those groups
    SUM(copies - 1)    AS extra_rows_to_remove    -- rows left over if we keep 1 per group
FROM dup_groups
GROUP BY CASE WHEN files = 2 THEN 'across_files' ELSE 'within_one_file' END;


/* ==========================================================================
   02. DATE RANGE OF EACH SOURCE FILE
   ========================================================================== */

-- QUESTION: what period does each file cover (and so where do they overlap)?
-- RESULT  : raw_2009 ends 2010-12-09 20:01, raw_2010 starts 2010-12-01 08:26
-- FINDING : the files overlap between 2010-12-01 and 2010-12-09
SELECT
    source_file,
    MIN(InvoiceDate) AS first_date,
    MAX(InvoiceDate) AS last_date
FROM dbo.stg_retail_typed
GROUP BY source_file;


/* ==========================================================================
   03. DO CROSS-FILE DUPLICATES FALL INSIDE THE OVERLAP WINDOW?
   ========================================================================== */

-- QUESTION: do all duplicates across files fall inside the overlap window?
-- RESULT  : first_dup_date 2010-12-01 08:26 | last_dup_date 2010-12-09 20:01
--           = exactly the overlap (sheet 2009-2010 ends 2010-12-09 20:01,
--             sheet 2010-2011 starts 2010-12-01 08:26)
-- FINDING : duplicates across files are an export artefact, not repeated transactions
-- DECISION: only the across-file duplicates are removed (not "all extra rows";
--           the exact rule and count come from section 05)
WITH dup_groups AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country,
        COUNT(*)                    AS copies,
        COUNT(DISTINCT source_file) AS files
    FROM dbo.stg_retail_typed
    GROUP BY
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country
    HAVING COUNT(*) > 1
)
SELECT
    MIN(InvoiceDate) AS first_dup_date,
    MAX(InvoiceDate) AS last_dup_date
FROM dup_groups
WHERE files = 2;                              -- only duplicates present in both files


/* ==========================================================================
   04. DUPLICATES WITHIN ONE FILE
   ========================================================================== */

-- QUESTION: what do duplicates inside a single file look like?
--           (hypothesis: the same product scanned twice on one invoice,
--            so these may be real sales and not errors)
-- RESULT  : top groups are real products bought by named customers: same customer,
--           same minute, Quantity 1 repeated many times
--           (e.g. invoice 555524: 20 identical lines of 1 teacup)
-- FINDING : the system stored each unit as a separate line, so these are real sales
-- DECISION: keep all within-file duplicates (11,491 extra rows); removing them
--           would understate revenue and units sold
WITH dup_groups AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country,
        COUNT(*)                    AS copies,
        COUNT(DISTINCT source_file) AS files
    FROM dbo.stg_retail_typed
    GROUP BY
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country
    HAVING COUNT(*) > 1
)
SELECT TOP 20
    Invoice, StockCode, Description, Quantity,
    InvoiceDate, Price, CustomerID, Country, copies
FROM dup_groups
WHERE files = 1                               -- repeated inside one file only
ORDER BY copies DESC;                         -- most repeated first


/* ==========================================================================
   05. BALANCE OF COPIES BETWEEN FILES
   ========================================================================== */

-- QUESTION: in cross-file groups, does each file hold the same number of copies?
--           equal     -> e.g. 1 in raw_2009 + 1 in raw_2010 (pure overlap artefact)
--           different -> e.g. 2 in raw_2009 + 1 in raw_2010 (also repeats inside a file)
-- WHY IT MATTERS: for 'equal' groups with copies > 2 (e.g. 2 + 2), the real
--           repeats are legitimate, so "copies - 1" would remove too much.
--           The safe removal rule is: drop the raw_2010 copies in the overlap window.
-- RESULT  : equal 22,118 | different 0
-- FINDING : in every cross-file group both files hold the same number of copies,
--           so the 2010-2011 sheet is an exact copy of the overlap window
-- DECISION: remove the raw_2010 copy of each row that also exists in raw_2009
--           expected rows to remove = 44,878 / 2 = 22,439 (confirmed in section 06)
--           the earlier figure 22,760 also counted real repeats inside a file
WITH dup_groups AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country,
        COUNT(*)                                                  AS copies,
        COUNT(DISTINCT source_file)                               AS files,
        SUM(CASE WHEN source_file = 'raw_2009' THEN 1 ELSE 0 END) AS copies_2009,
        SUM(CASE WHEN source_file = 'raw_2010' THEN 1 ELSE 0 END) AS copies_2010
    FROM dbo.stg_retail_typed
    GROUP BY
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country
    HAVING COUNT(*) > 1
)
SELECT
    CASE WHEN copies_2009 = copies_2010 THEN 'equal' ELSE 'different' END AS copy_balance,
    COUNT(*) AS group_count
FROM dup_groups
WHERE files = 2
GROUP BY CASE WHEN copies_2009 = copies_2010 THEN 'equal' ELSE 'different' END;

--- 06. REMOVE CROSS-FILE DUPLICATES

-- QUESTION: how many raw_2010 rows have an identical twin in raw_2009?
-- Twin = same Invoice, StockCode, Description, Quantity, InvoiceDate, Price,
--        CustomerID, Country (source_file is not part of the key)
-- RESULT  : 22,439 rows (= 44,878 / 2, as predicted from section 05)
-- DECISION: these rows are removed; all raw_2009 rows and all real repeats
--           inside one file stay
WITH rows_with_twin_count AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country, source_file,
        SUM(CASE WHEN source_file = 'raw_2009' THEN 1 ELSE 0 END)
            OVER (PARTITION BY Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country)  AS n_2009
    FROM dbo.stg_retail_typed
)
SELECT COUNT(*) AS rows_to_remove
FROM rows_with_twin_count
WHERE source_file = 'raw_2010' and n_2009 > 0

DROP TABLE IF EXISTS dbo.stg_retail_dedup;

WITH rows_with_twin_count AS (
    SELECT
        Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country, source_file,
        SUM(CASE WHEN source_file = 'raw_2009' THEN 1 ELSE 0 END)
            OVER (PARTITION BY Invoice, StockCode, Description, Quantity,
        InvoiceDate, Price, CustomerID, Country)  AS n_2009
    FROM dbo.stg_retail_typed
)
SELECT
Invoice, StockCode, Description, Quantity, InvoiceDate, Price, CustomerID, Country, source_file      -- te same kolumny, ale BEZ n_2009
INTO dbo.stg_retail_dedup
FROM rows_with_twin_count
WHERE NOT (source_file = 'raw_2010' and n_2009 > 0) ;                               -- odwrotno�� warunku z sekcji 06

/* ==========================================================================
   07. VALIDATION AND DATA QUALITY EXPLORATION
   ========================================================================== */

-- 1. VALIDATION: verify if the row count after deduplication matches expectations
--    (Total rows - removed overlap duplicates)
SELECT
    COUNT(*)            AS rows_after_dedup,
    1067371 - 22439     AS expected_rows
FROM dbo.stg_retail_dedup;

-- 2. VALIDATION: verify if any cross-file duplicates persist
--    (Result should be 0)
WITH groups_check AS (
    SELECT 
        Invoice, StockCode, Description, Quantity, 
        InvoiceDate, Price, CustomerID, Country,  
        COUNT(DISTINCT source_file) AS files
    FROM dbo.stg_retail_dedup
    GROUP BY 
        Invoice, StockCode, Description, Quantity, 
        InvoiceDate, Price, CustomerID, Country
    HAVING COUNT(DISTINCT source_file) > 1
)
SELECT COUNT(*) AS groups_still_in_both_files
FROM groups_check;

-- 3. EXPLORATION: analyze special "non-numeric" product codes (services, adjustments)
SELECT
    StockCode,
    MAX(description) AS description,
    COUNT(*) as rows_count,
    SUM(Quantity) as total_units,
    SUM(Quantity * Price) as total_value
FROM dbo.stg_retail_dedup
WHERE STOCKCODE NOT LIKE '[0-9][0-9][0-9][0-9][0-9]%'
GROUP BY StockCode
ORDER BY rows_count DESC;

-- 4. EXPLORATION: categorize rows to differentiate real sales from artefacts
--    (e.g., cancellations, manual adjustments, vouchers)
SELECT 
    CASE
        WHEN Price = 0 AND CustomerID IS NULL THEN 'inventory_adjustment'
        WHEN Price < 0 THEN 'bad_debt_adjustment'
        WHEN StockCode IN ('POST','DOT','M','C2','D','S','BANK CHARGES',
                           'ADJUST','ADJUST2','AMAZONFEE','CRUK','TEST001','TEST002') THEN 'non_product'
        WHEN StockCode LIKE 'gift_0001%' THEN 'voucher'
        WHEN Invoice LIKE 'C%' THEN 'cancellation'
        WHEN Price = 0 AND CustomerID IS NOT NULL THEN 'free_item'
        ELSE 'sale'
    END AS row_type,
    COUNT(*) as rows_count,
    SUM(Quantity * Price) AS total_value
FROM dbo.stg_retail_dedup
GROUP BY 
    CASE
        WHEN Price = 0 AND CustomerID IS NULL THEN 'inventory_adjustment'
        WHEN StockCode = 'B' OR Price < 0 THEN 'bad_debt_adjustment'
        WHEN StockCode IN ('POST','DOT','M','C2','D','S','BANK CHARGES',
                           'ADJUST','ADJUST2','AMAZONFEE','CRUK','TEST001','TEST002') THEN 'non_product'
        WHEN StockCode LIKE 'gift_0001%' THEN 'voucher'
        WHEN Invoice LIKE 'C%' THEN 'cancellation'
        WHEN Price = 0 AND CustomerID IS NOT NULL THEN 'free_item'
        ELSE 'sale'
    END
ORDER BY rows_count DESC;



-- 5. EXPLORATION: check specific 'B' (Bad debt) codes
SELECT Invoice, StockCode, Description, Quantity, Price, CustomerID, InvoiceDate
FROM dbo.stg_retail_dedup
WHERE StockCode = 'B';

-- 6. EXPLORATION: identify negative sales that are not marked as cancellations
--    (These might be hidden errors or data quality issues)
SELECT COUNT(*) AS bad_sales
FROM dbo.stg_retail_dedup
WHERE Quantity < 0
  AND Invoice NOT LIKE 'C%'
  AND Price <> 0;

-- 7. EXPLORATION: size the "guest checkout" segment (missing CustomerID)
--    and check if these occur in specific countries
SELECT COUNT(*) AS null_customer_sales
FROM dbo.stg_retail_dedup
WHERE CustomerID IS NULL AND Price > 0;

SELECT DISTINCT(Country)
FROM dbo.stg_retail_dedup
WHERE CustomerID IS NULL AND Price > 0;

-- 8. EXPLORATION: verify if "Guest" and "Registered" accounts mix within the same invoice
--    (Used to diagnose hybrid invoicing patterns)
SELECT 
    Invoice, 
    SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END) as null_count,
    SUM(CASE WHEN CustomerID IS NOT NULL THEN 1 ELSE 0 END) as id_count
FROM dbo.stg_retail_dedup
GROUP BY Invoice
HAVING SUM(CASE WHEN CustomerID IS NULL THEN 1 ELSE 0 END) > 0
   AND SUM(CASE WHEN CustomerID IS NOT NULL THEN 1 ELSE 0 END) > 0;

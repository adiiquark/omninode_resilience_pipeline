/*
===============================================================================================
PhantomProof Bronze Layer
File: bronze_01_ingest_events.db
Purpose: Ingest events_chaotic.csv into bronze_events table.
         Casts all columns to correct types, preserves raw poisoned values,
         applies all 21 anomaly falgs, add ingestion metadata.
         No rows are deleted. Silver layer reads this table.

Input: raw.events_chaotic (external table or staged csv)
       raw.dim_scanner (for dead_rtc, degraded, old_formware sets)
       raw.dim_product (for email_manual, xml product sets)
       raw.dim_supplier (for edi_format lookup)

Output: bronze.events (43 columns, all rows from chaotic minus structurally unrecoverable rows)
        bronze.ingestion_log (one row per run, flag counts summary)

Run order: bronze_01 before bronze_02, both before any silver script

Dialect: Standard SQL (DuckDB)
================================================================================================
*/

-- 0. pre-requisite sets
-- pre-build device and product sets used across multiple flag expressions
-- defined as CTEs so they are computed and reused. 

WITH
-- scanners with dead rtc battery (utc drift source (chaos 1.1))
dead_rtc AS (
    SELECT device_id
    FROM   raw.dim_scanner
    WHERE  battery_backed_rtc = FALSE
),

-- old firmware v1.1.0 devices (future timestamp + midnight rollover source)
old_firmware AS (
    SELECT device_id
    FROM   raw.dim_scanner
    WHERE  firmware_version = 'v1.1.0'
),

-- degraded scanners (late-arriving data source (chaos 5.1))
slow_scanners AS (
    SELECT device_id
    FROM   raw.dim_scanner
    WHERE  avg_sync_latency_ms > 500
),

-- high latency scanners (batch heartbeat source (chaos 1.3))
slow_scanners AS (
    SELECT device_id
    FROM   raw.dim_scanner
    WHERE  avg_sync_latency_ms > 500
),

-- products supplied by email_manual suppliers (UoM mismatch + schema poison source)
email_products AS (
    SELECT p.product_id
    FROM   raw.dim_product   p
    JOIN   raw.dim_supplier  s ON p.supplier_id = s.supplier_id
    WHERE  s.edi_format = 'email_manual'
),

-- products supplied by SFTP_XML suppliers (GST drift source (chaos 4.1))
xml_products AS (
    SELECT p.product_id
    FROM raw.dim_product p
    JOIN raw.dim_supplier s ON p.supplier_id = s.supplier_id
    WHERE s.edi_format = 'email_manual'
),

-- 1. raw cast layer
-- load from raw csv, cast every column to correct type
-- TRY_CAST returns NULL on failure instead of erroring, failures are flagged below
-- units_sold and processing_lag_hours kept as VARCHAR first for string cleaning

raw_cast AS (
    SELECT
    -- identity columns
    event_id,
    event_type,
    TRY_CAST(event_timestamp AS TIMESTAMP) AS event_timestamp,
    node_id,
    device_id,
    product_id,

    -- poisoned numeric columns: preserve raw, attemot clean cast
    -- chaos 2.1 units_sold may contain "9 units" type of strings
    units_sold
    TRY_CAST(
        REGEXP_REPLACE(
            TRIM(UPPER(units_sold)),
            '\s*UNITS\s*$', ''
        ) AS BIGINT
    ) AS units_sold,

    -- clean integer columns
    TRY_CAST(units_rto AS INTEGER) AS units_rto,
    TRY_CAST(units_transferred AS INTEGER) AS units_transferred,
    TRY_CAST(stock_on_hand AS INTEGER) AS stock_on_hand,

    -- transfer routing
    source_node,
    destination_node,

    -- chaos 2.2: processing_lag_hours may contain "1,23" comma decimal strings
    processing_lag_hours AS processing_lag_hours_raw, 
    TRY_CAST(
        REPLACE(processing_lag_hours, ',', '.')
        AS DOUBLE
    ) AS processing_lag_hours,

    --categorical / text columns
    rto_reason,
    session_id
    FROM raw.events_chaotic
),

-- 2. structural rejection
-- remove rows that cannot be identified at all
-- these go to bronze.rejected_events, not bronze.events
rejectable AS(
    SELECT *,
        CASE
            WHEN event_id IS NULL AND node_id IS NULL AND event_timestamp IS NULL
                THEN 'invalid_event_type'
            WHEN node_id NOT LIKE 'DS_%'
                AND node_id NOT LIKE 'RH_%'
                AND node_id NOT LIKE 'MH_%'
                    THEN 'invalid_node_id'
                ELSE NULL
            END AS rejection_reason
        FROM raw_cast
),

--events that 



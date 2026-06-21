/*
===============================================================================================
PhantomProof Bronze Layer
File: bronze_01_ingest_events.db
Purpose: Ingest events_chaotic.csv into bronze_events table.
         Casts all columns to correct types, preserves raw poisoned values,
         applies all anomaly flags, add ingestion metadata.
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

CREATE SCHEMA IF NOT EXISTS bronze;

-- 0. pre-requisite sets
-- pre-build device and product sets used across multiple flag expressions
-- defined as CTEs so they are computed and reused. 
CREATE OR REPLACE TABLE bronze.events AS

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
    WHERE s.edi_format = 'sftp_xml'
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
    units_sold AS units_sold_raw,
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

--events that pass structural check
passable AS (
    SELECT * EXCLUDE (rejection_reason)
    FROM rejectable
    WHERE  rejection_reason IS NULL
),


--  3. node median units_sold (for GST drift detection) 
-- chaos 4.1 inflated xml_product units_sold by 1.18x
-- flag rows that are >10% above the node median for that product
node_product_medians AS (
    SELECT
        node_id,
        product_id,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY units_sold) AS median_units_sold
    FROM   passable
    WHERE  event_type = 'customer_fulfillment'
      AND  units_sold IS NOT NULL
    GROUP  BY node_id, product_id
),

--  4. near-duplicate detection (sub-second jitter — chaos 3.3) 
-- same node + product + event_type, timestamp within 1 second of previous row
near_dupe_detection AS (
    SELECT
        event_id,
        ABS(
            EXTRACT(EPOCH FROM (
                event_timestamp -
                LAG(event_timestamp) OVER (
                    PARTITION BY node_id, product_id, event_type
                    ORDER BY event_timestamp
                )
            ))
        ) AS seconds_from_prev
    FROM passable
),

--  5. flag application 
-- every known chaos mode gets a boolean flag column
-- flag = TRUE means this row is affected by that failure mode
-- no rows deleted here, Silver decides what to do with flagged rows

flagged AS (
    SELECT
        p.*,

        --  TEMPORAL FLAGS 

        -- [01] UTC/IST Drift
        -- dead RTC battery causes scanner to reset to UTC on power loss
        -- timestamps appear 5h30m behind IST, pre-SIM_START is the signal
        CASE WHEN p.event_timestamp < TIMESTAMP '2025-12-01 00:00:00'
              AND p.device_id IN (SELECT device_id FROM dead_rtc)
             THEN TRUE ELSE FALSE
        END AS flag_utc_drift,

        -- [02] + [04] Future Timestamp
        -- covers both timezone double conversion (+11h) and firmware clock drift (+2 to +45 days)
        -- both result in event_timestamp beyond SIM_END, single flag sufficient
        CASE WHEN p.event_timestamp > TIMESTAMP '2026-06-30 23:59:59'
             THEN TRUE ELSE FALSE
        END AS flag_future_timestamp,

        -- [03] Batch Heartbeat
        -- high latency scanner buffers all events and uploads at exactly 23:59:59
        CASE WHEN EXTRACT(HOUR FROM p.event_timestamp) = 23
              AND EXTRACT(MINUTE FROM p.event_timestamp) = 59
              AND EXTRACT(SECOND FROM p.event_timestamp) = 59
              AND p.device_id IN (SELECT device_id FROM slow_scanners)
             THEN TRUE ELSE FALSE
        END AS flag_batch_heartbeat,

        -- [05] Midnight Rollover
        -- old ERP export truncates datetime to date, time component zeroed
        -- only flagged for old firmware devices to avoid false positives on
        -- legitimate midnight events
        CASE WHEN EXTRACT(HOUR FROM p.event_timestamp) = 0
              AND EXTRACT(MINUTE FROM p.event_timestamp) = 0
              AND EXTRACT(SECOND FROM p.event_timestamp) = 0
              AND p.device_id IN (SELECT device_id FROM old_firmware)
             THEN TRUE ELSE FALSE
        END AS flag_midnight_rollover,

        -- [06] Processing Lag Smear (exact 155.5h injected value)
        -- degraded scanner accumulates 155.5 hour processing delay
        CASE WHEN p.processing_lag_hours = 155.5
             THEN TRUE ELSE FALSE
        END AS flag_lag_smear,

        -- general extreme lag (>24h covers both smear and late-arriving)
        CASE WHEN p.processing_lag_hours > 24
             THEN TRUE ELSE FALSE
        END AS flag_extreme_lag,


        -- STRUCTURAL FLAGS 

        -- [07] Schema Poisoning, Unit Suffix
        -- email_manual supplier typed "9 units", units_sold failed numeric cast
        CASE WHEN p.units_sold IS NULL
              AND p.units_sold_raw IS NOT NULL
              AND UPPER(p.units_sold_raw) LIKE '%UNITS%'
             THEN TRUE ELSE FALSE
        END AS flag_schema_poison_units,

        -- [08] Schema Poisoning, Decimal Separator
        -- SFTP_XML supplier used comma as decimal: "1,23" failed float cast
        CASE WHEN p.processing_lag_hours IS NULL
              AND p.processing_lag_hours_raw IS NOT NULL
              AND p.processing_lag_hours_raw LIKE '%,%'
             THEN TRUE ELSE FALSE
        END AS flag_decimal_separator,

        -- [10] Null RTO Reason
        -- rto_return event with units_rto > 0 but reason field is null
        -- returns scanner staff skipped reason dropdown under pressure
        CASE WHEN p.event_type = 'rto_return'
              AND COALESCE(p.units_rto, 0) > 0
              AND p.rto_reason IS NULL
             THEN TRUE ELSE FALSE
        END AS flag_null_rto_reason,

        -- [11] UoM Mismatch, Cases vs Units
        -- email_manual supplier sent quantity in cases (24 units each)
        -- inbound transfer has suspiciously low units_transferred
        CASE WHEN p.event_type = 'inbound_transfer'
              AND p.product_id IN (SELECT product_id FROM email_products)
              AND COALESCE(p.units_transferred, 999) < 10
             THEN TRUE ELSE FALSE
        END AS flag_uom_mismatch,

        -- OPERATIONAL FLAGS 

        -- [12] Ghost Inventory
        -- units_sold > stock_on_hand + 500 for fulfillment rows
        -- 500-unit buffer avoids false positives (stock_on_hand is post-sale)
        -- physical cause: sale recorded before inbound scan confirmed stock arrival
        CASE WHEN p.event_type = 'customer_fulfillment'
              AND COALESCE(p.units_sold, 0) > COALESCE(p.stock_on_hand, 0) + 500
             THEN TRUE ELSE FALSE
        END AS flag_ghost_inventory,

        -- [13] Exact Duplicate
        -- same node + product + event_type + timestamp + units_sold
        -- physical cause: double-tap submit on outbound scanner
        CASE WHEN COUNT(*) OVER (
                PARTITION BY p.node_id, p.product_id,
                             p.event_type, p.event_timestamp,
                             p.units_sold
             ) > 1
             THEN TRUE ELSE FALSE
        END AS flag_exact_duplicate,

        -- [14] Near Duplicate (sub-second jitter)
        -- same node/product/event_type, timestamp within 1 second of previous row
        -- physical cause: scanner retry mechanism sends event twice
        CASE WHEN nd.seconds_from_prev < 1
              AND nd.seconds_from_prev IS NOT NULL
             THEN TRUE ELSE FALSE
        END AS flag_near_duplicate,

        -- [16] Reverse Logistics Void
        -- units_rto = 100 but stock_on_hand = 2
        -- return logged but stock never physically restocked
        CASE WHEN p.event_type = 'rto_return'
              AND COALESCE(p.units_rto, 0) >= 100
              AND COALESCE(p.stock_on_hand, 999) <= 5
             THEN TRUE ELSE FALSE
        END AS flag_reverse_logistics_void,

        -- [17] Lateral Transfer Orphan
        -- source_node = 'MISSING_SOURCE'; DS2 received stock but DS1 has no outbound record
        -- inflates total system inventory
        CASE WHEN p.event_type = 'lateral_transfer'
              AND p.source_node = 'MISSING_SOURCE'
             THEN TRUE ELSE FALSE
        END AS flag_lateral_orphan,

        -- [22] Negative Stock
        -- stock_on_hand < 0; write-off entries entered with wrong sign
        CASE WHEN COALESCE(p.stock_on_hand, 0) < 0
             THEN TRUE ELSE FALSE
        END AS flag_negative_stock,


        -- MARKET AND INTEGRITY FLAGS 

        -- [18] GST Math Drift
        -- SFTP_XML supplier ERP added 18% GST to unit price
        -- units_sold > 10% above node median for same product signals inflation
        CASE WHEN p.event_type = 'customer_fulfillment'
              AND p.product_id IN (SELECT product_id FROM xml_products)
              AND p.units_sold > npm.median_units_sold * 1.10
             THEN TRUE ELSE FALSE
        END AS flag_gst_drift,

        -- [19] SKU Migration
        -- PROD_001 renamed to PROD_001_OLD_SKU for events before 2026-03-10
        -- analytics sees two products where one exists
        CASE WHEN p.product_id = 'PROD_001_OLD_SKU'
             THEN TRUE ELSE FALSE
        END AS flag_sku_migration,

        -- [20] Fat Finger Outlier
        -- cracked touchscreen registered 999999 units
        CASE WHEN COALESCE(p.units_sold, 0) = 999999
             THEN TRUE ELSE FALSE
        END AS flag_fat_finger,

        -- LATE ARRIVING DATA FLAGS 

        -- [24] Late Arriving Event
        -- degraded scanner buffered events during connectivity loss
        -- processing_lag_hours between 48 and 72 for degraded scanners
        CASE WHEN p.processing_lag_hours BETWEEN 48 AND 72
              AND p.device_id IN (SELECT device_id FROM slow_scanners)
             THEN TRUE ELSE FALSE
        END AS flag_late_arriving,

        -- [25] Out of Order Sequence
        -- placeholder requires lead/lag across ordered sequence
        -- Silver layer (silver_07_late_arriving_data.sql) will set this
        FALSE AS flag_out_of_order

    FROM      passable         p
    LEFT JOIN near_dupe_detection nd ON p.event_id = nd.event_id
    LEFT JOIN node_product_medians npm
           ON p.node_id = npm.node_id
          AND p.product_id = npm.product_id
),

-- 6. ingestion metadata 
final AS (
    SELECT
        f.*,

        -- ingestion timestamp (UTC)
        CURRENT_TIMESTAMP AS ingested_at,

        -- source file for lineage tracing
        'events_chaotic.csv' AS source_file,

        -- row hash for deduplication in Silver
        -- MD5 of key fields, first 16 chars sufficient for collision avoidance
        LEFT(
            MD5(
                COALESCE(event_id,       '') || '|' ||
                COALESCE(node_id,        '') || '|' ||
                COALESCE(product_id,     '') || '|' ||
                COALESCE(CAST(event_timestamp AS VARCHAR), '')
            ), 16
        ) AS row_hash,

        -- any_flag: quick filter, TRUE if any single chaos flag is set
        (
            flag_utc_drift OR flag_future_timestamp OR flag_batch_heartbeat OR
            flag_midnight_rollover OR flag_lag_smear OR flag_extreme_lag OR
            flag_schema_poison_units OR flag_decimal_separator OR
            flag_null_rto_reason OR flag_uom_mismatch OR
            flag_ghost_inventory OR flag_exact_duplicate OR flag_near_duplicate OR
            flag_reverse_logistics_void OR flag_lateral_orphan OR flag_negative_stock OR
            flag_gst_drift OR flag_sku_migration OR flag_fat_finger OR
            flag_late_arriving OR flag_out_of_order
        ) AS any_flag,

        -- flag_count: number of flags set, severity indicator for Silver triage
        (
            CAST(flag_utc_drift AS INTEGER) +
            CAST(flag_future_timestamp AS INTEGER) +
            CAST(flag_batch_heartbeat AS INTEGER) +
            CAST(flag_midnight_rollover AS INTEGER) +
            CAST(flag_lag_smear AS INTEGER) +
            CAST(flag_extreme_lag AS INTEGER) +
            CAST(flag_schema_poison_units AS INTEGER) +
            CAST(flag_decimal_separator AS INTEGER) +
            CAST(flag_null_rto_reason AS INTEGER) +
            CAST(flag_uom_mismatch AS INTEGER) +
            CAST(flag_ghost_inventory AS INTEGER) +
            CAST(flag_exact_duplicate AS INTEGER) +
            CAST(flag_near_duplicate AS INTEGER) +
            CAST(flag_reverse_logistics_void AS INTEGER) +
            CAST(flag_lateral_orphan AS INTEGER) +
            CAST(flag_negative_stock AS INTEGER) +
            CAST(flag_gst_drift AS INTEGER) +
            CAST(flag_sku_migration AS INTEGER) +
            CAST(flag_fat_finger AS INTEGER) +
            CAST(flag_late_arriving AS INTEGER) +
            CAST(flag_out_of_order AS INTEGER)
        ) AS flag_count

    FROM flagged f
) SELECT * FROM final; --  7. write to bronze.events 


--  8. write rejected rows to bronze.rejected_events 
--  8. write rejected rows to bronze.rejected_events 
CREATE OR REPLACE TABLE bronze.rejected_events AS
WITH raw_cast AS (
    SELECT
    event_id, 
    event_type, 
    TRY_CAST(event_timestamp AS TIMESTAMP) 
    AS event_timestamp,
    node_id, 
    device_id, 
    product_id, 
    units_sold AS units_sold_raw,
    TRY_CAST(REGEXP_REPLACE(
        TRIM(UPPER(units_sold)), '\s*UNITS\s*$', '') AS BIGINT) AS units_sold,
    TRY_CAST(units_rto AS INTEGER) AS units_rto, 
    TRY_CAST(units_transferred AS INTEGER) AS units_transferred,
    TRY_CAST(stock_on_hand AS INTEGER) AS stock_on_hand, 
    source_node, 
    destination_node,
    processing_lag_hours AS processing_lag_hours_raw, 
    TRY_CAST(REPLACE(processing_lag_hours, ',', '.') AS DOUBLE) AS processing_lag_hours,
    rto_reason, 
    session_id
    FROM raw.events_chaotic
),
rejectable AS (
    SELECT *,
        CASE
            WHEN event_id IS NULL AND node_id IS NULL AND event_timestamp IS NULL THEN 'invalid_event_type'
            WHEN node_id NOT LIKE 'DS_%' AND node_id NOT LIKE 'RH_%' AND node_id NOT LIKE 'MH_%' THEN 'invalid_node_id'
            ELSE NULL
        END AS rejection_reason
    FROM raw_cast
)
SELECT
    r.*,
    rejection_reason,
    CURRENT_TIMESTAMP AS ingested_at,
    'events_chaotic.csv' AS source_file
FROM rejectable r
WHERE rejection_reason IS NOT NULL;

-- 9. ingestion log 
CREATE OR REPLACE TABLE bronze.ingestion_log AS
SELECT
    CURRENT_TIMESTAMP AS run_timestamp,
    'events_chaotic.csv' AS source_file,
    (SELECT COUNT(*) FROM raw.events_chaotic) AS input_rows,
    (SELECT COUNT(*) FROM bronze.rejected_events
     WHERE  source_file = 'events_chaotic.csv') AS rejected_rows,
    (SELECT COUNT(*) FROM bronze.events) AS bronze_rows,
    (SELECT COUNT(*) FROM bronze.events WHERE any_flag = TRUE)  AS flagged_rows,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_count = 0) AS clean_rows,
    -- per-flag counts for audit
    (SELECT COUNT(*) FROM bronze.events WHERE flag_utc_drift) AS cnt_utc_drift,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_future_timestamp) AS cnt_future_timestamp,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_batch_heartbeat) AS cnt_batch_heartbeat,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_midnight_rollover) AS cnt_midnight_rollover,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_lag_smear) AS cnt_lag_smear,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_extreme_lag) AS cnt_extreme_lag,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_schema_poison_units) AS cnt_schema_poison_units,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_decimal_separator) AS cnt_decimal_separator,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_null_rto_reason) AS cnt_null_rto_reason,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_uom_mismatch) AS cnt_uom_mismatch,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_ghost_inventory) AS cnt_ghost_inventory,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_exact_duplicate) AS cnt_exact_duplicate,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_near_duplicate) AS cnt_near_duplicate,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_reverse_logistics_void) AS cnt_reverse_logistics_void,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_lateral_orphan) AS cnt_lateral_orphan,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_negative_stock) AS cnt_negative_stock,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_gst_drift) AS cnt_gst_drift,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_sku_migration) AS cnt_sku_migration,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_fat_finger) AS cnt_fat_finger,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_late_arriving) AS cnt_late_arriving,
    (SELECT COUNT(*) FROM bronze.events WHERE flag_out_of_order) AS cnt_out_of_order
;

-- 10. quick sanity check  
SELECT
    'bronze.events' AS table_name,
    COUNT(*)                AS total_rows,
    SUM(CAST(any_flag AS INTEGER)) AS flagged_rows,
    COUNT(*) - SUM(CAST(any_flag AS INTEGER)) AS clean_rows,
    MIN(event_timestamp) AS earliest_timestamp,
    MAX(event_timestamp) 
    
    
    
    AS latest_timestamp
FROM bronze.events

UNION ALL

SELECT
    'bronze.rejected_events',
    COUNT(*), NULL, NULL, NULL, NULL
FROM bronze.rejected_events
;


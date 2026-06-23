/*
================================================================================
PhantomProof : Silver Layer
File   : silver_01_timezone_normalisation.sql
Purpose: Fix all timestamp anomalies flagged in bronze.events.
         Produces a corrected event_timestamp for every row.
         Original timestamp preserved in event_timestamp_raw for audit.

Fixes applied (in order of application):
  [01] UTC/IST Drift  :add 5h30m where flag_utc_drift = TRUE
  [02] Future Timestamp  :flag retained, timestamp not corrected
                              (cannot know intended value: quarantined)
  [03] Batch Heartbeat   :flag retained, timestamp not corrected
                              (true event time unknowable: quarantined)
  [05] Midnight Rollover   :flag retained, timestamp not corrected
                              (time component lost : quarantined)
  [06] Lag Smear   : processing_lag_hours corrected to node median
  [24] Late Arriving    :processing_lag_hours flagged, timestamp correct

Input  : bronze.events
Output : silver.events_ts_clean      (same columns + event_timestamp_raw
                                      + ts_correction_applied + ts_quarantined)
================================================================================
*/
CREATE OR REPLACE TABLE silver.events_ts_clean AS

WITH

-- 1. node median processing lag 
-- used to impute lag_smear rows (155.5h injected value)
-- computed from clean rows only (no extreme lag, no smear)
node_lag_medians AS (
    SELECT
        node_id,
        PERCENTILE_CONT(0.5) WITHIN GROUP (
            ORDER BY processing_lag_hours
        ) AS median_lag
    FROM  bronze.events
    WHERE flag_extreme_lag  = FALSE
      AND flag_lag_smear = FALSE
      AND processing_lag_hours IS NOT NULL
    GROUP BY node_id
),

-- 2. apply timestamp corrections 
corrected AS (
    SELECT
        e.*,

        -- preserve original for audit trail
        e.event_timestamp AS event_timestamp_raw,

        -- corrected timestamp:
        -- utc_drift rows: add 5h30m to convert UTC back to IST
        -- all other anomalous timestamps: leave as-is, quarantine flag handles them
        CASE
            WHEN e.flag_utc_drift = TRUE
            THEN e.event_timestamp + INTERVAL '5 hours 30 minutes'
            ELSE e.event_timestamp
        END AS event_timestamp,

        -- which correction was applied (for Silver audit log)
        CASE
            WHEN e.flag_utc_drift = TRUE THEN 'utc_to_ist_plus_5h30m'
            ELSE 'none'
        END AS ts_correction_applied,

        -- ts_quarantined: TRUE means timestamp is anomalous and uncorrectable
        -- these rows are excluded from time-series aggregations in Gold
        (
            e.flag_future_timestamp   OR
            e.flag_batch_heartbeat    OR
            e.flag_midnight_rollover
        ) AS ts_quarantined,

        -- corrected processing_lag_hours:
        -- lag_smear rows (155.5h) replaced with node median
        -- late_arriving rows (48-72h) flagged but value preserved (real delay)
        -- decimal_separator rows: already cast correctly in bronze TRY_CAST
        CASE
            WHEN e.flag_lag_smear = TRUE
            THEN COALESCE(nlm.median_lag, 1.5)  -- fallback 1.5h if no median
            ELSE e.processing_lag_hours
        END AS processing_lag_hours

    FROM bronze.events e
    LEFT JOIN node_lag_medians nlm ON e.node_id = nlm.node_id
) SELECT * FROM corrected; -- 3. write silver timezone-clean table  


-- 4. sanity checks  
SELECT
    ts_correction_applied,
    COUNT(*) AS row_count
FROM silver.events_ts_clean
GROUP BY ts_correction_applied
;

SELECT
    ts_quarantined,
    COUNT(*) AS row_count,
    MIN(event_timestamp) AS min_ts,
    MAX(event_timestamp) AS max_ts
FROM silver.events_ts_clean
GROUP BY ts_quarantined
;

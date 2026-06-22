/*
================================================================================
PhantomProof — Bronze Layer
File   : bronze_02_ingest_nodes.sql
Purpose: Ingest nodes_chaotic.csv into bronze_nodes table.
         Applies city corruption flag, validates node hierarchy integrity,
         cross-references with clean dim_node for silver join key.

Input  : raw.nodes_chaotic (external table or staged CSV — 120 rows)
         raw.dim_node (clean master — source of truth for joins)
         raw.dim_hub_hierarchy (for parent_node_id integrity check)

Output : bronze.nodes (120 rows, 22 columns)

Run order : bronze_01 before or alongside bronze_02.
            Both must complete before any silver script runs.

Dialect: Standard SQL (DuckDB).
================================================================================
*/
CREATE OR REPLACE TABLE bronze.nodes AS
WITH

--  1. raw cast layer  
-- cast all columns to correct types
-- nodes_chaotic has the same schema as dim_node except city may be corrupted

raw_cast AS (
    SELECT
        -- identity
        TRIM(node_id) AS node_id,
        TRIM(node_type) AS node_type,
        TRIM(node_name) AS node_name,

        -- chaotic city field, preserved as-is, flag added below
        city AS city,

        -- geography
        TRIM(zone) AS zone,
        TRIM(zone_type) AS zone_type,
        TRIM(tier) AS tier,
        TRIM(parent_node_id) AS parent_node_id,

        -- capacity columns
        TRY_CAST(capacity_units AS INTEGER) AS capacity_units,
        TRY_CAST(capacity_cold_units AS INTEGER) AS capacity_cold_units,
        TRY_CAST(capacity_beverage_units  AS INTEGER) AS capacity_beverage_units,
        TRY_CAST(capacity_dry_units AS INTEGER) AS capacity_dry_units,

        -- coordinates
        TRY_CAST(lat AS DOUBLE) AS lat,
        TRY_CAST(lon AS DOUBLE) AS lon,

        -- operational
        TRIM(timezone) AS timezone,
        TRY_CAST(operational_since AS DATE) AS operational_since

    FROM raw.nodes_chaotic
),

-- 2. clean city from dim_node 
-- chaos 2.3 corrupted 3 node city fields with emoji and special characters
-- the clean city value always exists in dim_node (the uncorrupted master)
-- bronze records which nodes were corrupted; silver joins dim_node for clean city

clean_cities AS (
    SELECT node_id, city AS city_clean
    FROM   raw.dim_node
),

-- 3. hierarchy integrity check  
-- verify each non-mother-hub node has a parent that actually exists
-- orphaned nodes (parent_node_id not in dim_node) are flagged, not rejected

valid_node_ids AS (
    SELECT node_id FROM raw.dim_node
),

-- 4. capacity consistency check  
-- zone capacities (cold + beverage + dry) must not exceed total capacity
-- this was enforced by NodeSchema Pydantic validator at generation time
-- re-checked here as a data contract verification at ingestion

capacity_check AS (
    SELECT
        node_id,
        capacity_units,
        capacity_cold_units + capacity_beverage_units + capacity_dry_units
            AS zone_capacity_sum,
        CASE
            WHEN capacity_cold_units + capacity_beverage_units + capacity_dry_units
                 > capacity_units
            THEN TRUE
            ELSE FALSE
        END AS flag_capacity_overflow
    FROM raw_cast
),

-- 5. flag application  

flagged AS (
    SELECT
        r.*,

        -- clean city from dim_node 
        cc.city_clean,

        -- flag_city_corrupt: city contains non-alphabetic characters
        -- physical cause: cracked scanner touchscreen introduced emoji/special chars
        -- regex: city should only contain letters, spaces, and hyphens
        CASE
        -- Replaced 'WHEN r.city REGEXP ...' with:
        WHEN regexp_matches(r.city, '[^a-zA-Z\s\-]') THEN TRUE
            ELSE FALSE
        END AS flag_city_corrupt,

        -- flag_invalid_node_type: node_type not one of the three valid values
        CASE
            WHEN r.node_type NOT IN ('darkstore', 'regional_hub', 'mother_hub')
            THEN TRUE
            ELSE FALSE
        END AS flag_invalid_node_type,

        -- flag_orphaned_node: parent_node_id does not exist in dim_node
        -- mother_hubs legitimately have NULL parent; exclude from this flag
        CASE
            WHEN r.node_type != 'mother_hub'
             AND r.parent_node_id IS NOT NULL
             AND r.parent_node_id NOT IN (SELECT node_id FROM valid_node_ids)
            THEN TRUE
            ELSE FALSE
        END AS flag_orphaned_node,

        -- flag_capacity_overflow: zone capacities exceed total capacity
        -- should never happen post-Pydantic validation; if seen, data was modified
        cc2.flag_capacity_overflow,

        -- flag_missing_coordinates: lat or lon is null
        CASE
            WHEN r.lat IS NULL OR r.lon IS NULL
            THEN TRUE
            ELSE FALSE
        END AS flag_missing_coordinates,

        -- flag_out_of_india: coordinates outside India's geographic bounding box
        -- lat: 8.4 to 37.6, lon: 68.0 to 97.5 (same bounds as NodeSchema validator)
        CASE
            WHEN r.lat IS NOT NULL AND r.lon IS NOT NULL
             AND (r.lat NOT BETWEEN 8.4 AND 37.6
               OR r.lon NOT BETWEEN 68.0 AND 97.5)
            THEN TRUE
            ELSE FALSE
        END AS flag_out_of_india

    FROM raw_cast r
    LEFT JOIN clean_cities cc  ON r.node_id = cc.node_id
    LEFT JOIN capacity_check cc2 ON r.node_id = cc2.node_id
),

-- ── 6. ingestion metadata ─────────────────────────────────────────────────────
final AS (
    SELECT
        f.*,
        CURRENT_TIMESTAMP AS ingested_at,
        'nodes_chaotic.csv' AS source_file,

        -- any_flag: quick filter for Silver
        (
            flag_city_corrupt OR
            flag_invalid_node_type OR
            flag_orphaned_node OR
            flag_capacity_overflow OR
            flag_missing_coordinates  OR
            flag_out_of_india
        ) AS any_flag

    FROM flagged f
) SELECT * FROM final; -- 7. write to bronze.nodes  



-- 8. quick sanity check  
SELECT
    node_type,
    COUNT(*) AS node_count,
    SUM(CAST(any_flag AS INTEGER)) AS flagged,
    SUM(CAST(flag_city_corrupt AS INTEGER)) AS city_corrupt,
    SUM(CAST(flag_orphaned_node AS INTEGER)) AS orphaned
FROM bronze.nodes
GROUP BY node_type
ORDER BY node_type
;

-- 9. city corruption detail  
-- show which nodes were corrupted and what the clean city value should be
SELECT
    node_id,
    city AS city_chaotic,
    city_clean AS city_from_dim_node,
    node_type,
    tier
FROM bronze.nodes
WHERE flag_city_corrupt = TRUE
;

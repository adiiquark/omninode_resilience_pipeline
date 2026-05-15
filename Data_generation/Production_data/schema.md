dim_product
---
|Column Name | data type | info|
| :--- | :--- | :--- | 
|product_id  | str | PK| 
|name | str | | 
|category | str| enum values| 
|brand | str | | 
|unit_of_measure| str| enum - units/kg/litre |
|base_price| float| >0 |
|pack_size_ml_or_g | int | nullable |
|weight_grams| int| >0 |
|shelf_life_days | int | > 0 |
|storage_zone | str | enum - cold/dry/beverage |
|reorder_point_units | int | >0 |
|supplier_id | str | FK -> sim_supplier|


dim_supplier
---
|Column Name | data type | info|
| :--- | :--- | :--- | 
| supplier_id | str | PK |
| supplier_name | str | |
| city | str | dispatch city (not HQ) |
| edi_format | str | enum 4 values
| data_quality_score | float | 0.0 to 1.0|
| onboarded_date | date | |
| categories_supplied | str | comma-separated|
| serves_mother_hubs_ids | str | comma-separated| 


dim_node
---
Column Name | data type | info
| :--- | :--- | :--- | 
| node_id | str | PK |
| node_type | str | enum - darkstore/regional_hub/mother_hun
| node_name | str | |
| city | str | |
| zone | str | enum - residential/commercial/it_park_adjacent/transit_hub/warehouse
| tier | str | enum - metropolitan/tier_1/tier_2
| parent_node_id| str | nullable -None from mother hubs
| capacity_units| int | >0|
| capacity_cold_units| int | >=0|
| capacity_beverage_units | int | >=0|
| capacity_dry_units| int | >=0| 
| latitude | float | |
|longitude| float | | 
| timezone | str | "Asia/Kolkata" | 
| operational_since| date| | 


dim_scanner
---
|Column Name | data type | info| 
| :--- | :--- | :--- | 
| device_id| str| PK|
|assigned_node_id| str| FK -> dim_node|
| scanner_zone| str| enum - inbound/outbound/returns/stock_count|
| firmware_version| str| enum - 4 values|
| firmware_release_date | date | |
| battery_backed_rtc| bool | |
| avg_sync_latency_ms | int| >0|
| is_degraded| bool | | 
| chaos_affinity| str| |
| last_calibrated| date| |
| failure_count_30d| int| >=0| 


dim_hub_hierarchy
---
|Column Name | data type | info| 
| :--- | :--- | :--- | 
| darkstore_id| str| FK -> dim_node|
| darkstore_node| str| |
| darkstore_city| str| |
| tier| str| |
| regional_hub_id| str| FK -> dim_node|
| regional_hub_city| str| |
| mother_hub_id| str| FK -> dim_node|
| mother_hub_zone| str| |

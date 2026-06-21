CREATE SCHEMA IF NOT EXISTS raw;

CREATE OR REPLACE TABLE raw.events_chaotic AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/events_chaotic.csv');

CREATE OR REPLACE TABLE raw.dim_scanner AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/dim_scanner.csv');

CREATE OR REPLACE TABLE raw.dim_product AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/dim_product.csv');

CREATE OR REPLACE TABLE raw.dim_supplier AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/dim_supplier.csv');

--- ADDITIONS FOR BRONZE 02
CREATE OR REPLACE TABLE raw.nodes_chaotic AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/nodes_chaotic.csv');

CREATE OR REPLACE TABLE raw.dim_node AS
SELECT * FROM read_csv_auto('Data_generation/Production_data/dim_node.csv');
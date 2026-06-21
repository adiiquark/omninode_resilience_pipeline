#!/usr/bin/env python3
"""
PhantomProof pipeline runner.

Executes every step in a layer folder, in filename order, against ONE shared
DuckDB database file. A "step" is a .sql file (executed directly
via the duckdb Python API).

Folder layout expected (relative to this script):
    bronze/  01_xxx.sql | 01_xxx.ipynb, 02_xxx.sql, ...
    silver/  01_xxx.sql | 01_xxx.ipynb, 02_xxx.sql, ...
    (gold/   same idea, optional)

Naming: zero-pad the numeric prefix (01_, 02_, ... 10_) so plain alphabetical
sort gives the correct run order.

Usage:
    python run_pipeline.py # run all layers, in order
    python run_pipeline.py bronze # run just bronze
    python run_pipeline.py bronze silver # run bronze then silver

Requires:
    pip install duckdb

"""


import sys
import logging
from pathlib import Path

import duckdb

logging.basicConfig(level=logging.INFO, format="%(asctime)s | %(levelname)s | %(message)s")
log = logging.getLogger("pipeline")

PIPELINE_DIR = Path(__file__).resolve().parent
DB_PATH = PIPELINE_DIR / "phantomproof.duckdb"
ALL_LAYERS = ["bronze", "silver", "gold"]


def ensure_schemas(conn):
    conn.execute("CREATE SCHEMA IF NOT EXISTS raw;")
    conn.execute("CREATE SCHEMA IF NOT EXISTS bronze;")
    conn.execute("CREATE SCHEMA IF NOT EXISTS silver;")
    conn.execute("CREATE SCHEMA IF NOT EXISTS gold;")


def run_sql_file(conn, path: Path) -> None:
    sql_text = path.read_text(encoding="utf-8")
    conn.execute(sql_text)


def run_layer(layer: str) -> None:
    layer_dir = PIPELINE_DIR / layer
    if not layer_dir.exists():
        log.warning(f"skip '{layer}' -- folder not found: {layer_dir}")
        return

    steps = sorted(
        p for p in layer_dir.iterdir()
        if p.suffix == ".sql" and not p.name.startswith(".")
    )
    if not steps:
        log.warning(f"no .sql files found in {layer_dir}")
        return

    log.info(f"=== {layer.upper()} ({len(steps)} steps) ===")
    with duckdb.connect(str(DB_PATH)) as conn:
        ensure_schemas(conn)

        for step in steps:
            log.info(f" -> {step.name}")
            try:
                run_sql_file(conn, step)
                log.info("    ok")
            except Exception as exc:
                log.error(f"    FAILED on {step.name}: {exc}")
                raise SystemExit(1)


def main() -> None:
    requested = sys.argv[1:] or ALL_LAYERS
    log.info(f"DuckDB file: {DB_PATH}")
    for layer in requested:
        run_layer(layer)
    log.info("pipeline complete")


if __name__ == "__main__":
    main()
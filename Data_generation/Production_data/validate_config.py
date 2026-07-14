# validate_config.py
# the goal is to validate the configurations set in config.py

def validate_config(cfg): 
    errors = []

    #1. Fractions that must sum to 1.0
    dist = cfg["city_distribution"] 
    total = dist["metropolitan"] + dist["tier_1"] + dist["tier_2"]
    if abs(total - 1.0) > 1e-6: 
        errors.append(f"city_distribution sums to {total}, expected 1.0")

    edi = cfg["suppliers"]["edi_formats"]
    edi_total = sum(v["fraction"] for v in edi.values()) 
    if abs(edi_total - 1.0) > 1e-6:
        errors.append(f"edi_formats fractions sum to {edi_total}, expected 1.0")

    sz = cfg["scanner_zone_types"]
    sz_total = sum(v["fraction"] for v in sz.values()) 
    if abs(sz_total - 1.0) > 1e-6:
        errors.append(f"scanner_zone_types fractions sum to {sz_total}, expected 1.0")

    
    # 2. Date sanity
    from datetime import date
    sim_start = date.fromisoformat(cfg["simulation"]["start_date"])
    sim_end = date.fromisoformat(cfg["simulation"]["end_date"])
    if sim_start >= sim_end:
        errors.append(f"start_date {sim_start} is not before end_date {sim_end}")

    #3. Range sanity (min <= max), sweep every [a,b] pair generically
    def check_range(path, r):
        if not isinstance(r, list) or len(r) != 2:
            errors.append(f"{path}: expected 2 element [min, max] got {r!r}")
            return
        if r[0] > r[1]:
            errors.append(f"{path}: min {r[0]} > max {r[1]}")

    for node_type in ["mother_hubs", "regional_hubs", "darkstores"]:
        node_cfg = cfg[node_type]
        for key in ["capacity_total_units", "cold_fraction", "beverage_fraction"]:
            val = node_cfg.get(key)
            if isinstance(val, dict):
                for tier, r in val.items():
                    check_range(f"{node_type}.{key}.{tier}", r)
            else:
                check_range(f"{node_type}.{key}", val)

    # 3b. Ranges that existed but were never swept
    for fmt, spec in cfg["suppliers"]["edi_formats"].items():
        check_range(f"suppliers.edi_formats.{fmt}.quality_score_range",
                     spec.get("quality_score_range"))

    check_range("products.price_range",
                 [cfg["products"]["price_range"]["min"], cfg["products"]["price_range"]["max"]])

    for cat, spec in cfg["product_categories"].items():
        check_range(f"product_categories.{cat}.shelf_life_days", spec.get("shelf_life_days"))

    for level, r in cfg["scanner"]["latency_ms"].items():
        check_range(f"scanner.latency_ms.{level}", r)

    # 4. demand_spike_events shape
    valid_categories = set(cfg["product_categories"].keys())
    valid_scopes = {"national", "metropolitan", "tier_1", "tier_2"}
    valid_zone_types = {"residential", "commercial", "it_park_adjacent", "transit_hub", "warehouse"}
    valid_cities = (
        set(cfg["cities"]["metropolitan"].keys())
        | set(cfg["cities"]["tier_1"].keys())
        | set(cfg["cities"]["tier_2"].keys())
    )

    for i, ev in enumerate(cfg["demand_spike_events"]):
        path = f"demand_spike_events[{i}]"

        # -- date window check, either shape --
        if "date_range" in ev:
            dr = ev["date_range"]
            if len(dr) != 2 or date.fromisoformat(dr[0]) >= date.fromisoformat(dr[1]):
                errors.append(f"{path}: bad date_range {dr}")
            else:
                d0, d1 = date.fromisoformat(dr[0]), date.fromisoformat(dr[1])
                if d0 < sim_start or d1 > sim_end:
                    errors.append(f"{path}: date_range {dr} falls outside simulation window")
        elif "date" in ev:
            d = date.fromisoformat(ev["date"])
            if d < sim_start or d > sim_end:
                errors.append(f"{path}: date {ev['date']} falls outside simulation window")
        else:
            errors.append(f"{path}: must have either 'date' or 'date_range'")

        # -- category check, now applies to BOTH shapes --
        if "product_category" not in ev:
            errors.append(f"{path}: missing product_category")
        else:
            cats = ev["product_category"]
            cats = cats if isinstance(cats, list) else [cats]
            bad = set(cats) - valid_categories
            if bad:
                errors.append(f"{path}: unknown category {bad}")

        # -- vocab checks --
        if "scope" in ev and ev["scope"] not in valid_scopes:
            errors.append(f"{path}: unknown scope '{ev['scope']}'")
        if "zone_type" in ev and ev["zone_type"] not in valid_zone_types:
            errors.append(f"{path}: unknown zone_type '{ev['zone_type']}'")
        if "cities" in ev:
            bad_cities = set(ev["cities"]) - valid_cities
            if bad_cities:
                errors.append(f"{path}: unknown cities {bad_cities}")
    # 5. Final verdict
    if errors:
        raise ValueError("Config validation failed:\n" + "\n".join(f" - {e}" for e in errors))
    return True
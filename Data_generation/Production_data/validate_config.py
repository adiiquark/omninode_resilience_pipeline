# validate_config.py
# the goal is to validate the configurations set in config.py

def validate_config(cfg): 
    errors = []

    #1. Fractions that must sum to 1.0
    dist = cfg["city_distribution"] # again cfg thing
    total = dist["metropolitan"] + dist["tier_1"] + dist["tier_2"]
    if abs(total - 1.0) > 1e-6: # 1e-6 thing
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
    start = date.fromisoformat(cfg["simulation"]["start_date"])
    end = date.fromisoformat(cfg["simulation"]["end_date"])
    if start >= end:
        errors.append(f"start_date {start} is not before end_date {end}")

    #3. Range sanity (min <= max), sweep every [a,b] pair generically
    def check_range(path, r):
        if isinstance(r, list) and len(r) == 2 and r[0] > r[1]: # get this one
            errors.append(f"{path}: min {r[0]} > max {r[1]}")

        for node_type in ["mother_hubs", "regional_hubs", "darkstores"]:
            node_cfg = cfg[node_type]
            for key in ["capacity_total_units", "cold_fraction", "beverage_fraction"]:
                val = node_cfg.get(key)
                if isinstance(val, dict): # tiered, eg: regional_hubs
                    for tier, r in val.items():
                        check_range(f"{node_type}.{key}.{tier}", r)
                else:
                    check_range(f"{node_type}.{key}", val)

        # 4. demand_spike_events shape
        for i, ev in enumerate(cfg["demand_spike_events"]):
            if "date_range" in ev:
                dr = ev["date_range"]
                if len(dr) != 2 or date.fromisoformat(dr[0]) >= date.fromisoformat(dr[1]):
                    errors.append(f"demand_spike_events[{i}]: bad date_range {dr}")
                valid_categories = set(cfg["product_categories"].keys())
                cats = ev["product_category"]
                cats = cats if isinstance(cats, list) else [cats]
                bad = set(cats) - valid_categories
                if bad:
                    errors.append(f"demand_spike_events[{i}]: unknown category {bad}")

            if errors:
                raise ValueError("Config validation failed:\n" + "\n".join(f" - {e}" for e in errors))
            return True
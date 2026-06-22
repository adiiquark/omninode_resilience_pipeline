"""
Zone Coordinates
----------------
Hardcoded approximate coordinates for all zones and cities in the simulation.
Used by 01_master_data_generation generator to assign latitudes and 
longitudes to the dim_node rows.

Not in config.yaml because coordinates are geographic facts that don't change. 

Usage in 01_master_data_generation:
    from coordinates import zone_coordinates, get_coordinates
"""

import random

zone_coordinates = {
    # ---------Mumbai--------------
    "Andheri": (19.1136, 72.8697),
    "Bandra": (19.0596, 72.8295),
    "Thane": (19.2183, 72.9781),
    "Kurla": (19.0726, 72.8845),
    "Malad": (19.1863, 72.8484),
    "Borivali": (19.2307, 72.8567),
    "Bhiwandi": (19.2967, 73.0631),


    # ---------Delhi---------------
    "Rohini": (28.7041, 77.1025),
    "Lajpat Nagar": (28.5672, 77.2436),
    "Dwarka": (28.5921, 77.0460),
    "Saket": (28.5244, 77.2066),
    "Janakpuri": (28.6289, 77.0826),
    'Kundli':  (28.8700, 77.0100),


    #----------Bangalore-----------
    "Koramangala": (12.9352, 77.6245),
    "Whitefield": (12.9698, 77.7499),
    "Indiranagar": (12.9784, 77.6408),
    "HSR Layout": (12.9116, 77.6389),
    "Dobaspet": (13.1100, 77.4100),


    # ---------Hyderabad-----------
    "Banjara Hills": (17.4156, 78.4347),
    "Kondapur": (17.4601, 78.3511),
    "Madhapur": (17.4486, 78.3908),
    "Gachibowli": (17.4401, 78.3489),
    "Patancheru": (17.5345, 78.2642),


    # ---------Chennai-------------
    "Anna Nagar": (13.0850, 80.2101),
    "T Nagar": (13.0418, 80.2341),
    "Velachery": (12.9815, 80.2180),
    "Adyar": (13.0012, 80.2565),
    "Sriperumbudur": (12.9675, 79.9494),


    # ---------Kolkata-------------
    "Salt Lake": (22.5810, 88.4220),
    "Park Street": (22.5513, 88.3527),
    "New Town": (22.5830, 88.4891),
    "Behala": (22.4983, 88.3132),
    "Dankuni": (22.6833, 88.2833),


    # ---------Pune----------------
    "Kothrud": (18.5074, 73.8077),
    "Wakad": (18.5985, 73.7611),
    "Baner": (18.5590, 73.7868),
    "Hadapsar": (18.5018, 73.9239),
    "Chakan": (18.7626, 73.8673),

    # ---------Ahmedabad-----------
    "Navrangpura": (23.0395, 72.5634),
    "Satellite": (23.0204, 72.5130),
    "Bopal": (23.0350, 72.4671),
    "Prahlad Nagar": (23.0124, 72.5074),
    "Sanand": (22.9925, 72.3846),

    # ---------Jaipur--------------
    "Malviya Nagar": (26.8467, 75.8164),
    "Vaishali": (26.9124, 75.7873),
    "C-Scheme": (26.9124, 75.8121),


    # ---------Lucknow--------------
    "Gomti Nagar": (26.8467, 81.0137),
    "Hazratganj": (26.8467, 80.9462),
    "Aliganj": (26.8819, 80.9590),


    # --------Chandigarh------------
    "Sector 17": (30.7414, 76.7682),
    "Sector 35": (30.7192, 76.7423),
    "Mohali Phase 7": (30.7046, 76.7179),


    # --------Surat-----------------
    "Vesu": (21.1459, 72.7862),
    "Adajan": (21.1959, 72.7987),
    "Citylight": (21.1724, 72.8262),


    # --------Tier-2 city centroids---
    "Mohali": (30.7046, 76.7179),
    "Indore": (22.7196, 75.8577),
    "Nagpur": (21.1458, 79.0882),
    "Coimbatore": (11.0168, 76.9558),
    "Bhopal": (23.2599, 77.4126),
    "Patna": (25.5941, 85.1376),
    "Agra": (27.1767, 78.0081)
}

def get_coordinates(
        zone_name: str,
        city_name: str,
        node_type: str,
        jitter: bool = True
) -> tuple[float, float]:
    """
    Returns (latiude, longitude) for a given zone or city.

    Lookup prioriy:
    1. zone_name - used for darkstores and regional hubs
    2. city_name - fallback for tier-2 cities with no zone
    3. Raises if neither found

    Jitter:
    Applied only to darkstores so multiple stores in same
    zone don't stack on the same powerbi pin. 
    +- 0.008 degrees almost equal to +-900 metres -stays within
    the same neighborhood. 

    Args:
    zone_name: zone string e.g. "Andheri", "Koramangala"
    city_name: city string e.g. "Mumbai" - used as fallback
    node_type: "darkstore" / "regional_hub" / "mother_hub"
    jitter: whether to add random offset (default True for darkstores)

    Returns:
        (lat, lon) rounded to 6 decimal places
    """
    if zone_name and zone_name in zone_coordinates:
        lat, lon = zone_coordinates[zone_name]
    elif city_name in zone_coordinates:
        lat, lon = zone_coordinates[city_name]
    else:
        raise ValueError(
            f"No coordinates found for zone '{zone_name}'"
            f"or city '{city_name}' - add to zone_coordinates"
        )
    
    if node_type == "darkstore" and jitter:
        lat += random.uniform(-0.008, 0.008)
        lon += random.uniform(-0.008, 0.008)

    return round(lat, 6), round(lon, 6)
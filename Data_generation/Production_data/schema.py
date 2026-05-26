"""
PhantomProof - Pydantic Schema Definitions
------------------------------------------
Defines and validates the structure of all five master data tables generated.
Every row produced by the generator passes through the relevant schema 
before being appended to the output DataFrame. 

Tables covered:
- dim_product
- dim_supplier
- dim_node
- dim_scanner
- dim_hub_hierarchy

Import in 01_master_data_generation.ipynb:
from schemas import(ProductSchema, SupplierSchema, NodeSchema, ScannerSchema, HubHierarchySchema)

"""


from pydantic import BaseModel, Field, field_validator, model_validator
from typing import Literal, Optional
from datetime import date
import re



# ---SIMULATION CONSTRAINTS------
SIM_START = date(2025,12,1)
SIM_END = date(2026,6,30)


# ---dim_product---
class ProductSchema(BaseModel):
    """ One row per SKU in the product catalog. 
    100 products generated across 7 categories. 
"""
    product_id: str
    name: str
    category: Literal["dairy", "beverages", "staples", "snacks", "personal_care", "household", "frozen"]
    brand: str
    unit_of_measure: Literal["units", "kg", "litre"]
    base_price: float = Field(gt=0)
    pack_size_ml_or_g: Optional[int] = Field(default=None, gt=0) 
    weight_grams: int = Field(gt=0)
    shelf_life_days: int = Field(gt=0)
    storage_zone: Literal["cold","dry","beverage"]
    reorder_point_units: int = Field(gt=0)
    supplier_id: str

    @field_validator("product_id")
    @classmethod
    def product_id_format(cls, v: str) -> str:
        if not re.match(r"^PROD_\d{3}$", v):
            raise ValueError(f"product_id must match PROD_NNN, got '{v}'")
        return v 
    
    @field_validator("name")
    @classmethod
    def name_must_not_be_empty(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("Product name cannot be empty or whitespace")
        return v.strip()
    
    @model_validator(mode="after")
    def storage_zone_matches_category(self) -> "ProductSchema":
        """
        Ensures storage_zone is consistent with category.
        dairy and frozen myst be cold.
        beverages must be beverages.
        All others must be dry.
        """
        expected = {
            "dairy": "cold",
            "frozen": "cold",
            "beverages": "beverage",
            "staples": "dry",
            "snacks": "dry",
            "personal_care": "dry",
            "household": "dry"
        }
        if self.storage_zone != expected[self.category]:
            raise ValueError(
                f"Category '{self.category}' must use storage_zone"
                f"'{expected[self.category]}', got '{self.storage_zone}'"
            )
        return self

# ----- dim_supplier -------------
class SupplierSchema(BaseModel):
    """
    One row per supplier. 19 suppliers generated.
    EDI format determines data quality and NB3 (chaos engine) chaos targetting:
        email_manual suppliers are the primary schema poisoning target.  
    """
    supplier_id: str
    supplier_name: str
    city: str # dispatch city, not HQ
    edi_format: Literal["API", "SFTP_CSV", "SFTP_XML", "email_manual"]
    data_quality_score: float = Field(ge=0.0, le=1.0)
    onboarded_date: date
    categories_supplied: str # comma separated
    serves_mother_hub_ids: str # comma separated

    @field_validator("supplier_id")
    @classmethod
    def supplier_id_format(cls, v: str) -> str:
        if not re.match(r"^SUP_\d{3}$", v):
            raise ValueError(
                f"supplier_id must match format SUP_NNN, got '{v}'"
            )
        return v
    
    @field_validator("onboarded_date")
    @classmethod
    def onboarded_before_sim_start(cls, v: date) -> date:
        if v >= SIM_START:
            raise ValueError(
                f"onboarded_date {v} must be before sim start {SIM_START}"
            )
        return v

    @model_validator(mode="after")
    def quality_score_consistent_with_edi(self) -> "SupplierSchema":
        """
        Soft guardrail: API suppliers should not have very low quality scores
        and email_manula suppliers should not have very high ones.
        Catches generator misconfiguration early. 
        """
        if self.edi_format == "API" and self.data_quality_score < 0.60:
            raise ValueError(
                f"API supplier has suspiciously low quality score "
                f"{self.data_quality_score} - check generator config"
            )
        
        if self.edi_format == "email_manual" and self.data_quality_score > 0.60:
            raise ValueError(
                f"email_manual supplier has suspiciously high quality score "
                f"{self.data_quality_score} - check generator config"
            )
        return self

# -----dim_node-----------


class NodeSchema(BaseModel):
    """
    one table covers all three node types.
    node_type distinguishes them; parent_node_id builds the hoerarchy.

    Hierarchy:
    mother_hub -> parent_node_id = NONE
    regional_hub -> parent_node_id = mother_hub node_id
    darkstore -> parent_node_id = regional_hub node_id
    """
    node_id: str
    node_type: Literal["darkstore", "regional_hub", "mother_hub"]
    node_name: str
    city: str
    zone: Optional[str] = None # None for mother hubs
    zone_type: Literal["residential", "commercial", "it_park_adjacent", "transit_hub", "warehouse"]
    tier: Literal["metropolitan", "tier_1", "tier_2"]
    parent_node_id: Optional[str] = None
    capacity_units: int= Field(gt=0)
    capacity_cold_units: int = Field(ge=0)
    capacity_beverage_units: int = Field(ge=0)
    capacity_dry_units: int = Field(ge=0)
    latitude: float
    longitude: float
    timezone: str = "Asia/Kolkata"
    operational_since: date

    @field_validator("latitude")
    @classmethod
    def latitude_must_be_india(cls, v:float) -> float:
        if not (8.4 <= v <= 37.6):
            raise ValueError(
                f"Latitude {v} is outside India's range (8.4 to 37.6)"
            )
        return round(v,6)
    
    @field_validator("longitude")
    @classmethod
    def longitude_must_be_india(cls, v: float) -> float:
        if not (68.0 <= v <= 97.5):
            raise ValueError(
                f"Longitude {v} is outside India's range (68.0 to 97.5)"
            )
        return round(v, 6)
    
    @field_validator("operational_since")
    @classmethod
    def operational_since_must_be_before_sim_end(cls, v: date) -> date:
        if v >= SIM_END:
            raise ValueError(
                f"operational_since {v} must be before simulation end {SIM_END}"
            )
        return v
    
    @model_validator(mode="after")
    def zone_capacities_must_not_exceed_total(self) -> "NodeSchema":
        zone_total = (
            self.capacity_cold_units + self.capacity_beverage_units + self.capacity_dry_units
        )

        if zone_total > self.capacity_units:
            raise ValueError(
                f"Zone capacities sum to {zone_total} but "
                f"total capacity is only {self.capacity_units} "
                f"for node '{self.node_id}'"
            )
        return self
    

    @model_validator(mode="after")
    def mother_hub_has_no_parent(self) -> "NodeSchema":
        if self.node_type == "mother_hub" and self.parent_node_id is not None:
            raise ValueError(
                f"mother_hub '{self.node_id}' must have parent_node_id = None"
            )
        return self
    
    @model_validator(mode="after")
    def non_mother_hub_must_have_parent(self) -> "NodeSchema":
        if self.node_type in ("darkstore", "regional_hub") \
            and self.parent_node_id is None:
            raise ValueError(
                f"'{self.node_type}' node '{self.node_id}'"
                f"must have a parent_node_id"
            )
        return self
        
    @model_validator(mode="after")
    def mother_hub_zone_type_is_warehouse(self) -> "NodeSchema":
        if self.node_type == "mother_hub" and self.zone_type != "warehouse":
            raise ValueError(
                f"mother_hub nodes must have zone_type 'warehouse'"
                f"got '{self.zone_type}'"
                )
        return self


# ------dim_scanner-----------------

class ScannerSchema(BaseModel):
    """
    One row per physical scanner device.
    scanner_zone
    """
    device_id: str
    assigned_node_id: str
    scanner_zone: Literal["inbound", "outbound", "returns", "stock_count"] #inbound/outbound/reurns/stock_count
    firmware_version: Literal["v1.1.0", "v1.2.3", "v2.0.1", "v2.1.4"]
    firmware_release_date: date
    battery_backed_rtc: bool
    avg_sync_latency_ms: int = Field(gt=0, le=2000)
    is_degraded: bool
    chaos_affinity: Literal["utc_drift", "duplicate_echo", "null_rto_reason", "batch_heartbeat"]
    last_calibrated: date
    failure_count_30d: int = Field(ge=0)

    @model_validator(mode="after")
    def degraded_flag_consistent_with_latency(self) -> "ScannerSchema":
        """
        is_degraded must agree with avg_sync_latency_ms. 
        Degraded thershold is 400ms (from YAML latency_ms.degraded lower bound)
        Catches silent contradictions between the two related fields.
        """
        degraded_threshold = 400
        if self.is_degraded and self.avg_sync_latency_ms < degraded_threshold:
            raise ValueError(
                f"is_degraded = True but avg_sync_latency_ms is "
                f"{self.avg_sync_latency_ms}ms - below degraded threshold "
                f"of {degraded_threshold}ms"
            )
        if not self.is_degraded and self.avg_sync_latency_ms >= degraded_threshold:
            raise ValueError(
                f"is_degraded = False but avg_sync_latency_ms is "
                f"{self.avg_sync_latency_ms}ms - at or above degraded threshold "
                f"of {degraded_threshold}ms"
            )
        return self
    
    @model_validator(mode="after")
    def chaos_affinity_matches_scanner_zone(self) -> "ScannerSchema":
        """
        Each scanner_zone maps to exactly one chaos_affinity.
        Catching mismatches here means NB3 (chaos generator) never gets contradictory targetting
        """
        expected_affinity = {
            "inbound": "utc_drift",
            "outbound": "duplicate_echo",
            "returns": "null_rto_reason",
            "stock_count": "batch_heartbeat"
        }
        if self.chaos_affinity != expected_affinity[self.scanner_zone]:
            raise ValueError(
                f"scanner_zone '{self.scanner_zone}' must have "
                f"chaos_affinity '{expected_affinity[self.scanner_zone]}', "
                f"got '{self.chaos_affinity}'"
            )
        return self
    
    @model_validator(mode="after")
    def calibration_before_sim_start(self) -> "ScannerSchema":
        if self.last_calibrated > SIM_START:
            raise ValueError(
                f"last_calibrated {self.last_calibrated} cannot be "
                f"after simulation start {SIM_START}"
            )
        return self
    
    @model_validator(mode="after")
    def degraded_scanner_must_have_failures(self) -> "ScannerSchema":
        """
        Degraded scanners should have atleast some failure history.
        Catches a generator that marks a scanner degraded but gives it 
        zero failures - a silent logival inconsistency.
        """
        if self.is_degraded and self.failure_count_30d == 0:
            raise ValueError(
                f"Degraded scanner '{self.device_id}' has "
                f"failure_count_30d = 0 - degraded scanners must have "
                f"at leaast 1 recorded failure."
            )
        return self



# ------dim_hub_hierarchy-----------------

class HubHierarchySchema(BaseModel):
    """
    Flattened three-tier hierarchy - one row per darkstore.
    Eliminates recursive CTEs in Gold layer SQL queries.
    Generated after all dim_node rows are created by walking parent_node_id.
    """
    darkstore_id: str
    darkstore_zone: str
    darkstore_city: str
    tier: Literal["metropolitan", "tier_1", "tier_2"]
    regional_hub_id: str
    regional_hub_city: str
    mother_hub_id: str
    mother_hub_zone: str # eg. Bhiwandi, Kundli etc 

    @model_validator(mode="after")
    def ids_must_be_distinct(self) -> "HubHierarchySchema":
        ids = [self.darkstore_id, self.regional_hub_id, self.mother_hub_id]
        if len(set(ids)) !=3:
            raise ValueError(
                f"darkstore_id, regional_hub_id, and mother_hub_id"
                f"must all be different - got {ids}"
            )
        return self
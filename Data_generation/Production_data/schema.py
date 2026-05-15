from pydantic import BaseModel, Field, field_validator
from typing import Literal, Optional
from datetime import date

class ProductSchema(BaseModel):
    product_id: str
    name: str
    category: str
    brand: str
    unit_of_measure: Literal["units", "kg", "litre"]
    base_price: float = Field(gt=0)
    pack_size_ml_or_g: Optional[int] = None 
    weight_grams: int = Field(gt=0)
    shelf_life_days: int = Field(gt=0)
    storage_zone: Literal["cold","dry","beverage"]
    reorder_point_units: int = Field(gt=0)
    supplier_id: str
# PhantomProof - Supply Chain Data Reliability Engine
Simulating, breaking, detecting and healing inventory data the way it behaves in real quick-commerce operations across a multi-node, scanner attributed supply chain. 

---

### The problem
In 2026, quick commerce companies like Blinkit, Zepto and Instamart promise 10 minute delivery to millions of customers daily. That promise breaks when digital inventory record and physical warehouse shelf stop agreeing. 

A customer in Koramangala orders milk because the app shows 4 units available, However those units damaged 2 hours ago and the damage was never logged because of the scanner having no wifi. Since the order is placed and it cannot be fulfilled, the cost is lost sale, delivery fuel, reverse logistics overhead, and permanent customer trust damage. 

The project focuses exclusively on supply chain and logistics side of quick-commerce, specifically the data reliability problems that make real-time inventory management unreliable at scale. 


##### The eight problems this pipeline solves

| Problem | Description | What it costs |
|:--- | :--- | :---|
| Phantom Inventory | Digital system claims stock that physically does not exist| Failed deliveries, RTO surge, customer churn|
| Data Divergence | Physical reality and ERP records stop agreeing | Cascading stockouts, wrong reorder triggers|
| High RTO Costs | Returns logged without reason codes, untraceable | No root cause, same failures repeat | 
| Sytem Blindness | Dashboard is wrong but no one knows why | IT teams debug SQL instead of fixing hardware | 
| Data Contract Violations | Scanners and manual feeds send dirty data types, emojis, and invalid UOMs| Silent corruption reaches dashboards unchecked| 
| Late Arriving Data (LAD) | A scanner with bad Wifi uploads Monday's data on Wednesday| Tuesday report has a hole, wednesday has a spike|
 | Semantic Drift | PROD_001 becomes PROD_001_OLD_SKU during migration | Historical trend lines break silently. | 
 | Observability gap | No link between a data error and the device that caused it | Root cause analysis is guess work. | 

 ### Why this Project exists 
 Most data projects assume the data source is clean. This one assumes that the data source is hostile.  

 PhantomProof builds the immune system of a supply chain pipeline. It is a system that not only processes data but also expects failure, identifies its origin, and heals it with traceable logic. Every anomaly injected in this project is attributed to a physical cause: a scanner with a dead RTC battery, a vendor sending manual spreadsheets, a node that lost connectivity for 4 days etc. 

 The result is a pipeline where one can run a SQL query and answer "Which firmware version caused the most inventory discrepancies last month, and which darkstores were affected"

 ---

 ### Architecture

 config.yaml + schema.py + coordinates.py
            |
            |
|-------------------------------------|
| Notebook 1 : Master data generation | -> dim product, dim_supplier,
|-------------------------------------|    dim_node, dim_scanner,                                         dim_hub_hierarchy
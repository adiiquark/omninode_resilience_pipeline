

### CHAOS LIBRARY

#### What this document is? 
This is the specification document for each "chaos" (fault) that is to be injected in the Ideal baseline data created in 02_baseline.ipynb
Every failure mode documented here reflects a real operational, hardware or integration failure observed in quick commerce supply chains. 



Each failure is defined by four things:
- Physical cause: what actually went wrong in the physical (real) world that caused the error
- Data Symptom: What corrupted data looks like
- Targeting logic: Which rows get affected and why (because it's not random)
- Detection signal: how it can be detected. 

**The improved idea is to have all the failure modes documented along with their symptoms in this library and document
the predetermined logic** 


---
## Category 1. Temporal Chaos
These are the time related chaos. The faults where the "when" of an event is logged wrong. These errors can corrupt time-series analysis. A report made with such errors gives an inaccurate timeline and trend lines may look wrong and individual rows may appear broken. 

##### *1.1 UTC/ITC Drift*
*Physical cause*: Warehouse scanners have a Real-Time Clock (RTC) chip with its own small battery that keeps time even when the device is powered off. When that battery dies the clock resets to a default time when powered on. If the scanner's
firmware does not force a network time sync on boot, it falls back to
whatever the OS clock says — which is often UTC. India is UTC+5:30, so
every timestamp from that scanner is 5 hours 30 minutes behind reality.

**Data symptom:**
```
Baseline:  2026-03-15 14:32:00   (IST, correct)
Corrupted: 2026-03-15 09:02:00   (UTC, 5h30m behind)
```
Sales appear to happen before the darkstore opens. Morning snapshots appear
at 00:30 instead of 06:00.

**Targeting logic:**
`dim_scanner` where `battery_backed_rtc = False`
All events from those device_ids get timestamp shifted backward by 5h30m.

**Detection signal:**
Events from a device_id where `battery_backed_rtc = False` with timestamps
clustering in the 00:00-05:30 window on working days.

---

### 1.2 Timezone Double-Conversion

**Physical cause:**
A system integrator converts UTC to IST on ingest. A second system downstream
assumes the data is still UTC and converts again. The timestamp is now
UTC+11:00 — 11 hours ahead of reality.

**Data symptom:**
```
Baseline:  2026-03-15 14:32:00
Corrupted: 2026-03-16 01:32:00   (crossed into next day)
```
This is more dangerous than UTC drift because it silently crosses day boundaries.
March 15th events appear on March 16th, making March 15th look like a low-demand
day and March 16th look like a double-demand day.

**Targeting logic:**
`firmware_version = v1.1.0` scanners (oldest firmware, most integration issues)
2% of their rows.

**Detection signal:**
Events from the same session_id appearing on two different calendar dates.

---

### 1.3 Batch Heartbeat

**Physical cause:**
A scanner loses Wi-Fi connectivity for several hours (common in basement
storage areas and during network maintenance windows). When connectivity
returns, the scanner uploads all buffered events simultaneously. The WMS
(Warehouse Management System) stamps all of them with the upload time
rather than the event time.

**Data symptom:**
All events from a scanner on a given day share the exact same timestamp:
`2026-03-15 23:59:59` regardless of when the events actually occurred.

**Targeting logic:**
`avg_sync_latency_ms > 500` scanners on 3 randomly selected dates.
All their events on those dates get timestamp forced to 23:59:59.

**Detection signal:**
More than 10 events from the same device_id sharing the exact same timestamp
within a single day.

---

### 1.4 Future Timestamp

**Physical cause:**
Scanner clock is set incorrectly: drifted forward instead of backward.
Common after a firmware update that resets clock settings, or after a
battery replacement where the technician sets the wrong date.

**Data symptom:**
```
Baseline:  2026-03-15 14:32:00   (today)
Corrupted: 2026-04-22 14:32:00   (38 days in the future)
```
Events appear to have happened before the stock existed. Downstream
forecasting models trained on this data learn incorrect lead times.

**Targeting logic:**
`firmware_version = v1.1.0` scanners (oldest, most likely to have clock issues)
2% of their rows shifted forward by 2-45 random days.

**Detection signal:**
`event_timestamp` > pipeline run date. Any event timestamped in the future
is definitionally corrupt.

---

### 1.5 Midnight Rollover

**Physical cause:**
Older ERP systems and some scanner firmware versions truncate datetime
to date-only during export. The time component is dropped and replaced
with 00:00:00. This was common in systems built before real-time tracking
became standard.

**Data symptom:**
```
Baseline:  2026-03-15 14:32:00
Corrupted: 2026-03-15 00:00:00
```
All events for a day look like they happened at midnight. Intraday
analysis (peak hour detection, shift performance) becomes impossible.

**Targeting logic:**
`firmware_version = v1.1.0` scanners, 5% of their rows.

**Detection signal:**
Disproportionate clustering of events at exactly 00:00:00 from specific
device_ids.

---

### 1.6 Processing Lag Smear

**Physical cause:**
A degraded scanner or slow network connection causes significant delay
between when an event occurs and when it reaches the central system.
A scan at 09:00 might not be processed until 20:30 the same day —
or even the next day in extreme cases.

**Data symptom:**
`processing_lag_hours` = 155.5 (approximately 6.5 days) on 2% of rows.

**Targeting logic:**
`is_degraded = True` scanners, 2% of their rows.

**Detection signal:**
`processing_lag_hours` exceeding 24 hours (any event processed more than
a day after it occurred violates operational SLAs).

---

## Category 2.  Structural and Schema Chaos

Failures where the *shape* of the data is wrong. These break pipelines
immediately and are the most visible class of failure — but also the
easiest to heal if the source is known.

---

### 2.1 Schema Poisoning: Unit Suffix

**Physical cause:**
A supplier using `email_manual` EDI format sends a spreadsheet where
someone has typed "130 units" in the quantity column instead of the
number 130. This is the most common schema violation in manual data entry.

**Data symptom:**
```
Baseline:  units_sold = 130        (integer)
Corrupted: units_sold = "130 units" (string)
```
Any downstream `SUM()` or arithmetic operation on this column crashes
or returns NULL.

**Targeting logic:**
Products where `supplier_id` maps to a supplier with `edi_format = email_manual`.
50 randomly selected rows from those products.

**Detection signal:**
`units_sold` column dtype becomes object (mixed types). Silver layer
applies regex `REPLACE(units_sold, ' units', '')` and TRY_CAST to INT.

---

### 2.2 Schema Poisoning : Wrong Decimal Separator

**Physical cause:**
European locale settings use commas as decimal separators (1,234.56 becomes
1.234,56). A supplier system with European locale settings sends price data
that looks like an integer to an Indian system expecting dot separators.

**Data symptom:**
```
Baseline:  base_price = 249.99
Corrupted: base_price = "249,99"   (string, European format)
```

**Targeting logic:**
`SFTP_XML` supplier products (XML schema drift). 3% of their price rows.

**Detection signal:**
`base_price` contains a comma character. Silver layer replaces comma
with dot before casting.

---

### 2.3 Address and City Corruption

**Physical cause:**
A scanner's touchscreen is cracked or wet. The operator's input is
garbled, producing emoji, special characters, or tab characters in
text fields. Common in dark store environments where scanners are
handled roughly.

**Data symptom:**
```
Baseline:  city = "Andheri"
Corrupted: city = "🚚 Hub-Alpha"
           city = "Sector 12 || 🏠"
           city = "Industrial Area\tPhase-1"
```
Tab characters (`\t`) break CSV parsing. Emoji break VARCHAR constraints
in SQL Server that use non-Unicode collations.

**Targeting logic:**
`dim_node` directly — 3 nodes with `failure_count_30d > 3` scanners.

**Detection signal:**
City field contains non-alphanumeric characters outside of expected
set (spaces, hyphens, digits).

---

### 2.4 Null RTO Reason

**Physical cause:**
The returns counter at a darkstore is busy. The staff member processing
a return skips the mandatory reason dropdown to move faster. The WMS
accepts the return but the reason field is NULL.

**Data symptom:**
`units_rto > 0` but `rto_reason = NULL` on the same row.
A return happened but no one recorded why.

**Targeting logic:**
Events where `event_type = rto_return` AND the logging `device_id`
has `scanner_zone = returns`. 20 rows.

**Detection signal:**
`units_rto > 0 AND rto_reason IS NULL` — a direct integrity check.
Silver layer imputes the most probable reason based on product category
and historical RTO patterns for that node.

---

### 2.5 UoM Mismatch

**Physical cause:**
A supplier sends stock quantities in cases (24 units per case) but
the WMS expects individual units. 100 cases of milk become 100 units
of milk instead of 2,400 units. Common when supplier onboarding
documentation is unclear about the unit of measure.

**Data symptom:**
```
Baseline:  units_transferred = 2400   (individual units, correct)
Corrupted: units_transferred = 100    (cases, looks like a small transfer)
```
The transfer looks like a small replenishment when it was actually a
full truckload. Reorder logic triggers incorrectly.

**Targeting logic:**
`inbound_transfer` events from `email_manual` suppliers on 5 random dates.
Transfer quantity divided by 24 (case size).

**Detection signal:**
Transfer quantity is an exact multiple of 24 from a specific supplier.
Cross-reference against expected reorder quantities for that product.

---

## Category 3. Operational and Logic Chaos

Failures where the *business logic* of the data is violated. Individual
fields look valid but their combination is impossible or contradictory.
These are the hardest to detect because no single column is obviously wrong.

---

### 3.1 Ghost Inventory

**Physical cause:**
A warehouse worker processes a sale in the system before the inbound
scan has confirmed the stock arrived. The supplier truck is at the
loading dock but the inbound scanner has not logged the receipt yet.
The sale goes through against stock that does not officially exist.

**Data symptom:**
`units_sold` exceeds `stock_on_hand` on the same row. The system
sold more than it had.

**Targeting logic:**
20 random `customer_fulfillment` rows. `units_sold` set to
`stock_on_hand + random(50, 500)`.

**Detection signal:**
`units_sold > stock_on_hand`, a direct logical impossibility.
Requires cross-row context to diagnose as ghost inventory vs
data entry error.

---

### 3.2 Duplicate Transaction Echoes

**Physical cause:**
A scanner's submit button is touched twice due to screen lag. The WMS
has no deduplication at the ingest layer, so both events are recorded.
The result is double-counting of sales or transfers.

**Data symptom:**
Two identical rows with the same `node_id`, `product_id`, `units_sold`,
and `session_id`, with `event_timestamp` either identical or differing
by milliseconds.

**Targeting logic:**
`outbound` scanner zone rows — 100 exact duplicates.
Additional 50 near-duplicates with ±millisecond timestamp variation
(these evade simple `df.duplicated()` detection).

**Detection signal:**
Exact duplicates: `GROUP BY node_id, product_id, units_sold, session_id
HAVING COUNT(*) > 1`.
Near-duplicates: same fields but `ABS(DATEDIFF(ms, ts1, ts2)) < 1000`.

---

### 3.3 Node Blackout

**Physical cause:**
A darkstore's entire scanner network goes offline for several days.
This happens during power outages, internet provider failures, or
when a router is damaged. No events are recorded during the blackout
period — not even snapshots.

**Data symptom:**
Complete absence of rows for a specific `node_id` on 4 consecutive days.
The gap is not zero stock — it is zero records. The difference matters
because a genuine stockout still produces snapshots showing zero units.

**Targeting logic:**
`node_id = DS_ROH_01` (or equivalent), days 10-13 of the simulation.
All rows for that node on those dates deleted from the dataframe.

**Detection signal:**
Expected 4 snapshots per active darkstore per day. Any darkstore with
0 records on a day it was operational is flagged. Bronze layer adds
`ingested_at` metadata so late-arriving data can be distinguished from
true blackouts.

---

### 3.4 Reverse Logistics Void

**Physical cause:**
A return is logged (units_rto > 0) but the warehouse staff forgets
to physically put the returned stock back on the shelf and scan it in.
The system records the return but the stock_on_hand does not increase.
The stock is in limbo — returned but not restocked.

**Data symptom:**
`units_rto = 100` but `stock_on_hand` remains at 2 (the pre-return level).
The balance does not add up: `stock_before + units_rto ≠ stock_on_hand`.

**Targeting logic:**
15 random `rto_return` rows. `units_rto` set to 100, `stock_on_hand`
left at baseline low value.

**Detection signal:**
For RTO rows: `stock_on_hand_after < stock_on_hand_before + units_rto`.
Requires joining consecutive rows by node_id and product_id.

---

### 3.5 Phantom Replenishment

**Physical cause:**
A transfer is logged in the system but the physical stock never arrived.
The truck broke down, or the wrong darkstore was entered in the transfer
request. The system shows stock increased but the shelf is empty.

**Data symptom:**
`inbound_transfer` event shows `units_transferred = 200` and
`stock_on_hand` increases accordingly, but the next snapshot
shows stock has not changed (the actual physical count contradicts
the system record).

**Targeting logic:**
10 random `inbound_transfer` rows. Transfer recorded but stock_on_hand
on the following snapshot is set to pre-transfer level.

**Detection signal:**
`stock_on_hand` in snapshot immediately following an inbound_transfer
does not reflect the transferred quantity.

---

### 3.6 Lateral Transfer Without Deduction

**Physical cause:**
A stock transfer from DS1 to DS2 is logged on DS2 as received
(units_transferred > 0) but no corresponding deduction event
exists for DS1. This creates phantom stock — the total inventory
in the system exceeds what physically exists across both nodes.

**Data symptom:**
DS2 has an `inbound_transfer` with `source_node = DS1` but DS1
has no corresponding outbound transfer event on the same date
for the same product.

**Targeting logic:**
5 random `inbound_transfer` events. Source node deduction event
deleted from the dataframe.

**Detection signal:**
For every `inbound_transfer` with a `source_node`, a corresponding
deduction must exist at the source node within the same transfer window.

---

## Category 4. Market and Integrity Chaos

Failures where the *meaning* of values drifts over time. These are the
slowest-moving and hardest-to-detect failures because each individual row
looks valid, the corruption only becomes visible when comparing across time.

---

### 4.1 GST Math Drift

**Physical cause:**
A supplier's ERP system is reconfigured to include GST (18%) in the
unit price after a tax compliance update. The PhantomProof pipeline
expects ex-GST prices. Revenue calculations are now 18% inflated
for all products from that supplier.

**Data symptom:**
```
Baseline:  revenue = units_sold × base_price = 100 × 249 = 24,900
Corrupted: revenue = 24,900 × 1.18 = 29,382   (GST included)
```
Historical trend lines show a sudden revenue jump that looks like
genuine demand growth but is actually a pricing error.

**Targeting logic:**
Products from `SFTP_XML` suppliers (EDI schema drift is the mechanism).
15% of their revenue rows multiplied by 1.18.

**Detection signal:**
Revenue per unit for affected products shows a step-change increase
after a specific date. Cross-reference against `base_price` in dim_product.

---

### 4.2 SKU Migration: Identity Crisis

**Physical cause:**
A product is renamed or recategorised during a system migration.
`PROD_001` (Amul Full Cream Milk 500ml) becomes `PROD_001_OLD_SKU`
in the source system after March 10th. Downstream analytics sum
them as two different products, making historical trend lines appear
to break mid-simulation.

**Data symptom:**
```
Before March 10:  product_id = "PROD_001"
After March 10:   product_id = "PROD_001_OLD_SKU"
```
Total milk sales appear to drop to zero in mid-March and a new
product appears with no history.

**Targeting logic:**
`product_id = PROD_001`, all rows before March 10th. product_id
changed to `PROD_001_OLD_SKU`.

**Detection signal:**
A product_id that appears before a cutoff date but not after,
combined with a new product_id appearing after the same date
with no prior history. Gold layer handles this as SCD Type 2.

---

### 4.3 Fat Finger Outlier

**Physical cause:**
A scanner's touchscreen is physically damaged — a crack or pressure
point causes the digit 9 to register multiple times. A staff member
enters 99 units and the system records 999,999.

**Data symptom:**
`units_sold = 999999` on 2 rows. This is 10,000x a typical daily
sale volume.

**Targeting logic:**
Scanners where `failure_count_30d > 5`. 2 rows.

**Detection signal:**
`units_sold > 3 × (node_daily_capacity / 100)`. Statistical outlier
detection (Z-score > 4) on units_sold by node and category.

---

### 4.4 Price Drift: Supplier Rounding Error

**Physical cause:**
A supplier's pricing feed rounds prices differently after a system
update. Prices that were 2 decimal places (₹249.99) become integers
(₹249) or gain extra precision (₹249.994318). This breaks revenue
reconciliation against invoices.

**Data symptom:**
```
Baseline:  base_price = 249.99
Corrupted: base_price = 249.994318   (floating point precision error)
```

**Targeting logic:**
`SFTP_CSV` supplier products. 8% of price rows gain extra decimal noise
of ±0.05.

**Detection signal:**
Price values with more than 2 decimal places for products that should
have fixed retail prices.

---

### 4.5 Negative Stock Drift

**Physical cause:**
Stock adjustment entries (write-offs for expired or damaged goods)
are entered as positive instead of negative. Stock is written down
instead of up, pushing `stock_on_hand` below zero.

**Data symptom:**
`stock_on_hand = -47` which is physically impossible.

**Targeting logic:**
10 random snapshot rows for dairy and frozen products (highest expiry rate).
`stock_on_hand` set to a random negative value between -5 and -200.

**Detection signal:**
`stock_on_hand < 0` a hard constraint violation.

---

### 4.6 Seasonal Demand Masking

**Physical cause:**
A node's data feed is throttled during peak periods to reduce server
load. Events are sampled at 50% during high-demand windows (IPL
evenings, festival days). The data shows lower demand precisely when
real demand is highest.

**Data symptom:**
During demand spike windows, affected nodes show 50% fewer fulfillment
events than expected — the opposite of what the spike should produce.

**Targeting logic:**
5 random darkstores. During `date_range` spike events, 50% of their
fulfillment rows deleted.

**Detection signal:**
Nodes that show declining sales during periods when all surrounding
nodes show increases. Anomaly detection on spatial demand correlation.

---

## Category 5. Late-Arriving and Out-of-Order Data

Failures where the data is correct but arrives in the wrong sequence.
These break streaming pipelines and incremental load strategies.

---

### 5.1 Late-Arriving Event (LAD)

**Physical cause:**
A scanner in a basement storage area has intermittent connectivity.
Monday's events are buffered locally and uploaded on Wednesday when
the device comes back online. The Wednesday pipeline run receives
events timestamped Monday — after Monday's report has already closed.

**Data symptom:**
Events with `event_timestamp` = Monday but `ingested_at` = Wednesday.
The Monday report is already published with incomplete data.

**Targeting logic:**
`is_degraded = True` scanners. 3% of their rows have `processing_lag_hours`
set to 48-72 hours (2-3 days late).

**Detection signal:**
`ingested_at - event_timestamp > 24 hours`. Bronze layer records both
timestamps enabling time-travel queries: "what did we know on Monday
vs what actually happened on Monday."

---

### 5.2 Out of Order Sequence

**Physical cause:**
Two events from the same session arrive in reverse order — the
fulfillment event arrives before the inbound transfer that restocked
the product. In a strictly-ordered pipeline, the fulfillment looks
like it happened against zero stock.

**Data symptom:**
```
Event A (arrived first):  fulfillment at 14:00, stock_on_hand = 45
Event B (arrived second): inbound_transfer at 09:00, +200 units
```
Processed in arrival order, A says stock was 45 before the transfer
that should have brought it to 245.

**Targeting logic:**
10 random `inbound_transfer` + `customer_fulfillment` pairs for the
same node and product on the same day. Timestamps swapped so
fulfillment timestamp < transfer timestamp but fulfillment arrives
first in the data.

**Detection signal:**
A fulfillment event whose `stock_on_hand` is lower than what the
preceding transfer should have produced. Requires ordering by
`event_timestamp` not `ingested_at`.

---

## Summary Table

| # | Name | Category | Rows Affected | Silver Healing |
|---|------|----------|--------------|----------------|
| 1 | UTC/IST Drift | Temporal | ~10% of RTC-dead scanner rows | Timezone normalisation |
| 2 | Timezone Double-Convert | Temporal | 2% of v1.1.0 rows | Timezone normalisation |
| 3 | Batch Heartbeat | Temporal | All rows from high-latency scanners on 3 dates | Timestamp reconstruction |
| 4 | Future Timestamp | Temporal | 2% of v1.1.0 rows | Future date rejection |
| 5 | Midnight Rollover | Temporal | 5% of v1.1.0 rows | Time component recovery |
| 6 | Processing Lag Smear | Temporal | 2% of degraded scanner rows | Lag threshold flagging |
| 7 | Schema Poisoning — Unit Suffix | Structural | 50 rows from email_manual products | Regex sanitisation |
| 8 | Schema Poisoning — Decimal | Structural | 3% of SFTP_XML price rows | Decimal normalisation |
| 9 | Address Corruption | Structural | 3 nodes | Character class validation |
| 10 | Null RTO Reason | Structural | 20 rto_return rows | Category-based imputation |
| 11 | UoM Mismatch | Structural | 5 transfer events | Case-to-unit conversion |
| 12 | Ghost Inventory | Operational | 20 fulfillment rows | Stock balance validation |
| 13 | Duplicate Echoes | Operational | 100 exact + 50 near-duplicate rows | Deduplication |
| 14 | Node Blackout | Operational | 4 days × 1 node deleted | Gap detection + audit flag |
| 15 | Reverse Logistics Void | Operational | 15 rto_return rows | RTO balance reconciliation |
| 16 | Phantom Replenishment | Operational | 10 transfer rows | Transfer pair validation |
| 17 | Lateral Transfer Without Deduction | Operational | 5 transfer rows | Source-destination reconciliation |
| 18 | GST Math Drift | Market | 15% of SFTP_XML revenue rows | Price normalisation |
| 19 | SKU Migration | Market | All PROD_001 rows before March 10 | SCD Type 2 lineage |
| 20 | Fat Finger Outlier | Market | 2 rows | Statistical outlier detection |
| 21 | Price Drift | Market | 8% of SFTP_CSV price rows | Precision rounding |
| 22 | Negative Stock Drift | Market | 10 snapshot rows | Floor constraint enforcement |
| 23 | Seasonal Demand Masking | Market | 50% of spike-window rows for 5 nodes | Spatial demand correlation |
| 24 | Late-Arriving Event | LAD | 3% of degraded scanner rows | Dual-timestamp audit trail |
| 25 | Out-of-Order Sequence | LAD | 10 transfer/fulfillment pairs | Event sequence reconstruction |

---

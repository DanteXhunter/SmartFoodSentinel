# Smart Supermarket Discount System — PostgreSQL Docker Setup

A self-contained PostgreSQL 16 database for a system that automatically calculates and applies progressive discounts to perishable supermarket products as they approach their expiration date.

---

## Quick Start

```bash
docker compose up --build
```

That's it. On first run the container executes `init.sql`, which:
1. Creates all tables, indexes, and views
2. Seeds 15 product types across 5 categories
3. Inserts 40 batches in three states: **fresh**, **actively discounting**, and **disposed**
4. Populates `discount_events` (with multiple snapshots per batch showing discount growth) and `disposal_log` for all expired batches

Subsequent `docker compose up` calls reuse the named volume and skip init — data is persistent.

---

## Connect to the Database

**psql (from your host machine):**
```bash
psql -h localhost -p 5432 -U supermarket_user -d supermarket_db
# password: supermarket_pass
```

**Inside the running container:**
```bash
docker exec -it supermarket_discount_db psql -U supermarket_user -d supermarket_db
```

**Connection string (for apps / ORMs):**
```
postgresql://supermarket_user:supermarket_pass@localhost:5432/supermarket_db
```

---

## Credentials

| Parameter | Value              |
|-----------|--------------------|
| Host      | `localhost`        |
| Port      | `5432`             |
| Database  | `supermarket_db`   |
| User      | `supermarket_user` |
| Password  | `supermarket_pass` |

---

## Schema Overview

```
product_types          ← one row per SKU type (Whole Milk 1L, Sourdough Loaf, …)
    │
    └── batches        ← one row per received shipment
            │
            ├── discount_events   ← time-series log of discount snapshots per batch
            └── disposal_log      ← what happened when a batch expired
```

### Key business logic

- **Price floor**: a batch is never sold below `buy_cost × 1.08` (8% minimum operational margin).
- **Discount curve**: exponential-style growth (`progress^1.6`) — discounts start slow and accelerate as discard_at approaches.
- **Computed helper**: `compute_discounted_price(optimal_price, buy_cost, discount_start, discard_at, at_timestamp)` returns `(discount_pct, sale_price)` for any point in time. Use this in your application to recalculate live prices.

---

## Useful Queries

**What's on discount right now?**
```sql
SELECT * FROM current_discounted_products_view ORDER BY current_discount_pct DESC;
```

**All active batches with their status:**
```sql
SELECT * FROM active_batches_view ORDER BY status, discard_at;
```

**Discount history for a specific batch:**
```sql
SELECT calculated_at, discount_percentage, discounted_price
FROM discount_events
WHERE batch_id = 11
ORDER BY calculated_at;
```

**Disposal summary by method:**
```sql
SELECT disposal_method, COUNT(*) AS batches, SUM(quantity_disposed) AS total_units
FROM disposal_log
GROUP BY disposal_method;
```

**Recalculate current price for all discounting batches using the helper function:**
```sql
SELECT
    b.id,
    pt.name,
    pt.optimal_price,
    d.discount_pct,
    d.sale_price
FROM batches b
JOIN product_types pt ON pt.id = b.product_type_id
JOIN LATERAL compute_discounted_price(
    pt.optimal_price, pt.buy_cost,
    b.discount_starts_at, b.discard_at,
    NOW()
) d ON TRUE
WHERE NOW() BETWEEN b.discount_starts_at AND b.discard_at;
```

---

## Teardown

```bash
# Stop and remove containers (data volume preserved)
docker compose down

# Stop, remove containers AND wipe the volume (full reset)
docker compose down -v
```

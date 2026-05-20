# Supermarket Discount System — AI Agent Context

You are connected to a PostgreSQL 16 database that manages automatic progressive discounts for perishable supermarket products. This document is everything you need to query, interpret, and act on the data correctly.

---

## Connection

```
postgresql://supermarket_user:supermarket_pass@localhost:5432/supermarket_db
```

| Parameter | Value              |
|-----------|--------------------|
| Host      | `localhost`        |
| Port      | `5432`             |
| Database  | `supermarket_db`   |
| User      | `supermarket_user` |
| Password  | `supermarket_pass` |

---

## Domain Model

### What this system does

Each product type (e.g. "Whole Milk 1L") defines shelf-life windows. When a shipment arrives, a **batch** is created. As the batch ages through its discount window, the system logs **discount events** — snapshots of the price at that moment. When a batch expires, a **disposal log** entry records what happened to it.

### Business rules you must never violate

| Rule | Detail |
|------|--------|
| **Price floor** | A batch is never sold below `buy_cost × 1.08` (8% minimum margin). |
| **Discount curve** | Discounts follow an exponential-style curve: `discount% = max_discount% × progress^1.6`, where `progress` is how far through the discount window the batch is (0 → 1). Discounts start slow and accelerate near expiry. |
| **Discount window** | Discounting begins at `discount_starts_at` and ends at `discard_at`. Outside this window, the product sells at `optimal_price`. |
| **Live price** | Always use the helper function (see below) to get a current price. Stored `discount_events` rows are historical snapshots, not necessarily current. |

---

## Schema

### `product_types` — one row per SKU

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL PK | — |
| `name` | TEXT | e.g. `"Whole Milk 1L"` |
| `category` | TEXT | One of: `Dairy`, `Bakery`, `Produce`, `Meat`, `Canned` |
| `buy_cost` | NUMERIC(10,2) | Wholesale cost |
| `optimal_price` | NUMERIC(10,2) | Full shelf price (always > buy_cost) |
| `days_until_start_of_discount` | INT | Days after receipt when discounting begins |
| `days_until_discard` | INT | Days after receipt when batch must be disposed |

**Typical shelf lives by category:**

| Category | Discount starts | Discard at |
|----------|----------------|------------|
| Dairy    | ~10–11 days    | ~14–15 days |
| Bakery   | ~2–3 days      | ~4–5 days  |
| Produce  | ~6–7 days      | ~9–10 days |
| Meat     | ~4–5 days      | ~6–7 days  |
| Canned   | ~540 days      | ~730 days  |

---

### `batches` — one row per received shipment

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL PK | — |
| `product_type_id` | INT FK | References `product_types.id` |
| `quantity_received` | INT | Units in the shipment |
| `quantity_remaining` | INT | Units still in stock (≤ quantity_received) |
| `received_at` | TIMESTAMPTZ | When the batch arrived |
| `discount_starts_at` | TIMESTAMPTZ | When discounting begins |
| `discard_at` | TIMESTAMPTZ | Deadline — after this the batch must be disposed |

**Batch status** (derived, not stored — compute it from timestamps vs `NOW()`):

| Status | Condition |
|--------|-----------|
| `fresh` | `NOW() < discount_starts_at` |
| `discounting` | `NOW() BETWEEN discount_starts_at AND discard_at` |
| `expired` | `NOW() > discard_at` |

---

### `discount_events` — time-series log of price snapshots

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL PK | — |
| `batch_id` | INT FK | References `batches.id` |
| `discount_percentage` | NUMERIC(5,2) | e.g. `23.50` means 23.5% off |
| `discounted_price` | NUMERIC(10,2) | Actual sale price at the time of the snapshot |
| `calculated_at` | TIMESTAMPTZ | When this snapshot was recorded |

> **Important:** these are historical snapshots. To get the *current* price, use `compute_discounted_price()` (see below), not the latest row here.

---

### `disposal_log` — what happened to expired batches

| Column | Type | Description |
|--------|------|-------------|
| `id` | SERIAL PK | — |
| `batch_id` | INT FK | References `batches.id` |
| `disposal_method` | ENUM | One of: `discarded`, `donated`, `animal_feed` |
| `quantity_disposed` | INT | Units disposed |
| `disposed_at` | TIMESTAMPTZ | When disposal occurred |
| `notes` | TEXT | Optional free-text notes |

---

## Views

### `active_batches_view`

All batches whose `discard_at` is still in the future. Includes `status` (`fresh` or `discounting`), plus `latest_discount_pct` and `latest_discounted_price` from the most recent `discount_events` row (NULL if the batch hasn't entered its discount window yet).

```sql
SELECT * FROM active_batches_view ORDER BY status, discard_at;
```

### `current_discounted_products_view`

Only batches currently inside their discount window, with stock remaining. Includes `price_floor`, `current_discount_pct`, `current_price`, and `last_calculated_at`. Use this to answer "what's on discount right now?" or to power a discount display.

```sql
SELECT * FROM current_discounted_products_view ORDER BY current_discount_pct DESC;
```

---

## Helper Function

### `compute_discounted_price(optimal_price, buy_cost, discount_start, discard_at, at_timestamp)`

Returns `(discount_pct, sale_price)` for any point in time. Use this whenever you need a live or hypothetical price — do not rely solely on stored snapshots.

```sql
-- Get the current live price for all actively discounting batches
SELECT
    b.id,
    pt.name,
    pt.optimal_price,
    d.discount_pct,
    d.sale_price
FROM batches b
JOIN product_types pt ON pt.id = b.product_type_id
JOIN LATERAL compute_discounted_price(
    pt.optimal_price,
    pt.buy_cost,
    b.discount_starts_at,
    b.discard_at,
    NOW()
) d ON TRUE
WHERE NOW() BETWEEN b.discount_starts_at AND b.discard_at;
```

You can also call it with a future timestamp to predict what a price will be:

```sql
-- What will the price be 2 hours from now?
SELECT * FROM compute_discounted_price(
    1.09, 0.62,
    '2025-01-10 08:00:00+00',
    '2025-01-14 08:00:00+00',
    NOW() + INTERVAL '2 hours'
);
```

---

## Common Query Patterns

**Products expiring soonest (prioritise for promotion or donation):**
```sql
SELECT batch_id, product_name, category, quantity_remaining, discard_at,
       discard_at - NOW() AS time_remaining
FROM active_batches_view
ORDER BY discard_at ASC;
```

**Discount history for a specific batch:**
```sql
SELECT calculated_at, discount_percentage, discounted_price
FROM discount_events
WHERE batch_id = <id>
ORDER BY calculated_at;
```

**Disposal summary (waste reporting):**
```sql
SELECT disposal_method, COUNT(*) AS batches, SUM(quantity_disposed) AS total_units
FROM disposal_log
GROUP BY disposal_method;
```

**All fresh batches by category:**
```sql
SELECT * FROM active_batches_view
WHERE status = 'fresh'
ORDER BY category, discard_at;
```

**Low-stock discounting batches (needs restocking attention):**
```sql
SELECT batch_id, product_name, quantity_remaining, current_discount_pct, discard_at
FROM current_discounted_products_view
WHERE quantity_remaining < 5
ORDER BY quantity_remaining ASC;
```

---

## Data State Reference

The database is seeded with **40 batches** across all 15 product types in three states:

| State | Description |
|-------|-------------|
| **Fresh** | Received recently; not yet in the discount window |
| **Discounting** | Currently between `discount_starts_at` and `discard_at`; has discount event history |
| **Disposed** | Past `discard_at`; has a `disposal_log` entry; no longer in `active_batches_view` |

All timestamps are anchored to `NOW()` at container first-start, so data ages naturally over time.

---

## What You Can and Cannot Do

| Allowed | Not allowed |
|---------|-------------|
| `SELECT` anything | Modify `buy_cost` or `optimal_price` directly (use a migration) |
| Call `compute_discounted_price()` | Set `discounted_price` below `buy_cost × 1.08` |
| Insert new `discount_events` rows | Insert a batch with `discard_at ≤ discount_starts_at` |
| Insert `disposal_log` entries | Delete `product_types` rows that have linked batches |
| Update `quantity_remaining` on a batch | Set `quantity_remaining > quantity_received` |

---

## Glossary

| Term | Meaning |
|------|---------|
| **Batch** | A single shipment of a product type; has its own expiry timeline |
| **Discount window** | The period between `discount_starts_at` and `discard_at` |
| **Price floor** | `buy_cost × 1.08` — the minimum permissible sale price |
| **Progress** | How far through the discount window a batch is, from 0.0 to 1.0 |
| **Optimal price** | The full shelf price charged before discounting begins |
| **Discard at** | Hard deadline; after this the batch must be disposed of, not sold |

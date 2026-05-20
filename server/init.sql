-- =============================================================
--  Smart Supermarket Discount System — Database Initialisation
--  PostgreSQL 16
-- =============================================================

-- ---------------------------------------------------------------
-- 0. Extensions & helpers
-- ---------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gives us gen_random_uuid() if needed

-- ---------------------------------------------------------------
-- 1. ENUMS
-- ---------------------------------------------------------------
CREATE TYPE disposal_method_enum AS ENUM ('discarded', 'donated', 'animal_feed');

-- ---------------------------------------------------------------
-- 2. TABLES
-- ---------------------------------------------------------------

CREATE TABLE product_types (
    id                          SERIAL PRIMARY KEY,
    name                        TEXT        NOT NULL,
    category                    TEXT        NOT NULL,
    buy_cost                    NUMERIC(10,2) NOT NULL CHECK (buy_cost > 0),
    optimal_price               NUMERIC(10,2) NOT NULL CHECK (optimal_price > buy_cost),
    days_until_start_of_discount INTEGER     NOT NULL CHECK (days_until_start_of_discount >= 0),
    days_until_discard           INTEGER     NOT NULL CHECK (days_until_discard > days_until_start_of_discount),
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE batches (
    id                  SERIAL PRIMARY KEY,
    product_type_id     INTEGER       NOT NULL REFERENCES product_types(id) ON DELETE RESTRICT,
    quantity_received   INTEGER       NOT NULL CHECK (quantity_received > 0),
    quantity_remaining  INTEGER       NOT NULL CHECK (quantity_remaining >= 0),
    received_at         TIMESTAMPTZ   NOT NULL,
    discard_at          TIMESTAMPTZ   NOT NULL,
    discount_starts_at  TIMESTAMPTZ   NOT NULL,
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT NOW(),

    CONSTRAINT qty_remaining_lte_received CHECK (quantity_remaining <= quantity_received),
    CONSTRAINT discard_after_discount_start CHECK (discard_at > discount_starts_at)
);

CREATE TABLE discount_events (
    id                  SERIAL PRIMARY KEY,
    batch_id            INTEGER         NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
    discount_percentage NUMERIC(5,2)    NOT NULL CHECK (discount_percentage >= 0 AND discount_percentage <= 100),
    discounted_price    NUMERIC(10,2)   NOT NULL CHECK (discounted_price > 0),
    calculated_at       TIMESTAMPTZ     NOT NULL
);

CREATE TABLE disposal_log (
    id                SERIAL PRIMARY KEY,
    batch_id          INTEGER               NOT NULL REFERENCES batches(id) ON DELETE CASCADE,
    disposal_method   disposal_method_enum  NOT NULL,
    quantity_disposed INTEGER               NOT NULL CHECK (quantity_disposed > 0),
    disposed_at       TIMESTAMPTZ           NOT NULL,
    notes             TEXT
);

-- ---------------------------------------------------------------
-- 3. INDEXES
-- ---------------------------------------------------------------

-- product_types
CREATE INDEX idx_product_types_category ON product_types(category);

-- batches
CREATE INDEX idx_batches_product_type_id    ON batches(product_type_id);
CREATE INDEX idx_batches_received_at        ON batches(received_at);
CREATE INDEX idx_batches_discard_at         ON batches(discard_at);
CREATE INDEX idx_batches_discount_starts_at ON batches(discount_starts_at);

-- discount_events
CREATE INDEX idx_discount_events_batch_id      ON discount_events(batch_id);
CREATE INDEX idx_discount_events_calculated_at ON discount_events(calculated_at);

-- disposal_log
CREATE INDEX idx_disposal_log_batch_id   ON disposal_log(batch_id);
CREATE INDEX idx_disposal_log_disposed_at ON disposal_log(disposed_at);

-- ---------------------------------------------------------------
-- 4. VIEWS
-- ---------------------------------------------------------------

-- All batches not yet at discard date, with live discount status
CREATE OR REPLACE VIEW active_batches_view AS
SELECT
    b.id                                               AS batch_id,
    pt.name                                            AS product_name,
    pt.category,
    pt.buy_cost,
    pt.optimal_price,
    b.quantity_received,
    b.quantity_remaining,
    b.received_at,
    b.discount_starts_at,
    b.discard_at,
    CASE
        WHEN NOW() < b.discount_starts_at THEN 'fresh'
        WHEN NOW() BETWEEN b.discount_starts_at AND b.discard_at THEN 'discounting'
        ELSE 'expired'   -- should not appear here but safety net
    END                                                AS status,
    -- Latest discount snapshot for this batch (NULL if not yet discounting)
    (
        SELECT de.discount_percentage
        FROM discount_events de
        WHERE de.batch_id = b.id
        ORDER BY de.calculated_at DESC
        LIMIT 1
    )                                                  AS latest_discount_pct,
    (
        SELECT de.discounted_price
        FROM discount_events de
        WHERE de.batch_id = b.id
        ORDER BY de.calculated_at DESC
        LIMIT 1
    )                                                  AS latest_discounted_price
FROM batches b
JOIN product_types pt ON pt.id = b.product_type_id
WHERE NOW() < b.discard_at;


-- Batches currently inside their discount window, with latest price
CREATE OR REPLACE VIEW current_discounted_products_view AS
SELECT
    b.id                AS batch_id,
    pt.name             AS product_name,
    pt.category,
    pt.optimal_price,
    pt.buy_cost,
    ROUND(pt.buy_cost * 1.08, 2)  AS price_floor,
    b.quantity_remaining,
    b.discount_starts_at,
    b.discard_at,
    de.discount_percentage AS current_discount_pct,
    de.discounted_price    AS current_price,
    de.calculated_at       AS last_calculated_at
FROM batches b
JOIN product_types pt ON pt.id = b.product_type_id
JOIN LATERAL (
    SELECT discount_percentage, discounted_price, calculated_at
    FROM discount_events
    WHERE batch_id = b.id
    ORDER BY calculated_at DESC
    LIMIT 1
) de ON TRUE
WHERE NOW() BETWEEN b.discount_starts_at AND b.discard_at
  AND b.quantity_remaining > 0;


-- ---------------------------------------------------------------
-- 5. MOCK DATA — product_types (15 products, 5 categories)
-- ---------------------------------------------------------------
--
--  Category shelf-life targets:
--    Dairy  : discard ~14d, discount starts ~10d
--    Bakery : discard ~5d,  discount starts ~3d
--    Produce: discard ~10d, discount starts ~7d
--    Meat   : discard ~7d,  discount starts ~5d
--    Canned : discard ~730d, discount starts ~540d
--
--  Markup targets:
--    Dairy   1.6x–1.9x
--    Bakery  1.5x–1.8x
--    Produce 1.4x–1.7x
--    Meat    1.7x–2.2x
--    Canned  1.5x–1.8x
--
INSERT INTO product_types
    (name, category, buy_cost, optimal_price, days_until_start_of_discount, days_until_discard)
VALUES
-- Dairy (3 products)
('Whole Milk 1L',           'Dairy',   0.62,  1.09, 10, 14),
('Greek Yoghurt 500g',      'Dairy',   0.95,  1.65, 10, 14),
('Cheddar Cheese 400g',     'Dairy',   2.10,  3.79, 11, 15),

-- Bakery (3 products)
('Sourdough Loaf 800g',     'Bakery',  1.20,  2.09,  3,  5),
('Croissants x6',           'Bakery',  1.45,  2.49,  2,  4),
('Blueberry Muffins x4',    'Bakery',  0.98,  1.79,  3,  5),

-- Produce (3 products)
('Baby Spinach 200g',       'Produce', 0.55,  0.89,  7, 10),
('Vine Tomatoes 500g',      'Produce', 0.60,  0.99,  7, 10),
('Broccoli Head',           'Produce', 0.45,  0.75,  6,  9),

-- Meat (3 products)
('Chicken Breast 500g',     'Meat',    2.40,  4.49,  5,  7),
('Beef Mince 400g',         'Meat',    2.80,  5.29,  5,  7),
('Pork Sausages x8',        'Meat',    1.90,  3.59,  4,  6),

-- Canned (3 products)
('Chopped Tomatoes 400g',   'Canned',  0.28,  0.49, 540, 730),
('Chickpeas 400g',          'Canned',  0.30,  0.52, 540, 730),
('Tuna Chunks in Brine',    'Canned',  0.65,  1.15, 540, 730);


-- ---------------------------------------------------------------
-- 6. HELPER FUNCTION — compute discounted price at a given moment
-- ---------------------------------------------------------------
--
--  Uses an exponential-style growth: discount % increases faster
--  as the product approaches discard_at.
--
--    progress  = elapsed_in_window / window_length   ∈ [0,1]
--    raw_disc% = max_discount% × progress^1.6
--    floor     = (buy_cost × 1.08 / optimal_price)  ← never go below
--    disc%     = LEAST(raw_disc%, 1 - floor)
--    price     = optimal_price × (1 - disc%)
--
CREATE OR REPLACE FUNCTION compute_discounted_price(
    p_optimal_price   NUMERIC,
    p_buy_cost        NUMERIC,
    p_discount_start  TIMESTAMPTZ,
    p_discard_at      TIMESTAMPTZ,
    p_at              TIMESTAMPTZ
)
RETURNS TABLE (discount_pct NUMERIC, sale_price NUMERIC)
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_window_secs   FLOAT;
    v_elapsed_secs  FLOAT;
    v_progress      FLOAT;
    v_floor_ratio   FLOAT;
    v_max_disc      FLOAT;
    v_raw_disc      FLOAT;
    v_final_disc    FLOAT;
    v_price         NUMERIC;
BEGIN
    v_window_secs  := EXTRACT(EPOCH FROM (p_discard_at - p_discount_start));
    v_elapsed_secs := EXTRACT(EPOCH FROM (p_at - p_discount_start));

    IF v_window_secs <= 0 OR v_elapsed_secs <= 0 THEN
        discount_pct := 0;
        sale_price   := p_optimal_price;
        RETURN NEXT;
        RETURN;
    END IF;

    v_progress   := LEAST(v_elapsed_secs / v_window_secs, 1.0);
    v_floor_ratio := (p_buy_cost * 1.08) / p_optimal_price;   -- e.g. 0.61 means floor is 61% of optimal
    v_max_disc   := 1.0 - v_floor_ratio;                       -- maximum possible discount fraction
    v_raw_disc   := v_max_disc * POWER(v_progress, 1.6);       -- exponential growth
    v_final_disc := LEAST(v_raw_disc, v_max_disc);

    v_price := ROUND(p_optimal_price * (1.0 - v_final_disc), 2);

    -- ensure we never dip below floor
    IF v_price < ROUND(p_buy_cost * 1.08, 2) THEN
        v_price := ROUND(p_buy_cost * 1.08, 2);
    END IF;

    discount_pct := ROUND(v_final_disc * 100, 2);
    sale_price   := v_price;
    RETURN NEXT;
END;
$$;


-- ---------------------------------------------------------------
-- 7. BATCHES (40 batches spread over last 60 days)
-- ---------------------------------------------------------------
--
--  Status categories we need:
--    FRESH     : received_at recent enough that NOW() < discount_starts_at
--    DISCOUNTING: NOW() is between discount_starts_at and discard_at
--    DISPOSED  : discard_at is in the past
--
--  We achieve this by controlling received_at relative to NOW().
--
--  All timestamps anchored to NOW() so they stay correct whenever
--  the container is first started.
--
DO $$
DECLARE
    -- product_type ids
    pt_milk       INT := 1;   -- Dairy  discard=14d, disc_start=10d
    pt_yoghurt    INT := 2;   -- Dairy  discard=14d, disc_start=10d
    pt_cheddar    INT := 3;   -- Dairy  discard=15d, disc_start=11d
    pt_sourdough  INT := 4;   -- Bakery discard=5d,  disc_start=3d
    pt_croissant  INT := 5;   -- Bakery discard=4d,  disc_start=2d
    pt_muffin     INT := 6;   -- Bakery discard=5d,  disc_start=3d
    pt_spinach    INT := 7;   -- Produce discard=10d, disc_start=7d
    pt_tomato     INT := 8;   -- Produce discard=10d, disc_start=7d
    pt_broccoli   INT := 9;   -- Produce discard=9d,  disc_start=6d
    pt_chicken    INT := 10;  -- Meat discard=7d, disc_start=5d
    pt_beef       INT := 11;  -- Meat discard=7d, disc_start=5d
    pt_sausage    INT := 12;  -- Meat discard=6d, disc_start=4d
    pt_tomcan     INT := 13;  -- Canned discard=730d, disc_start=540d
    pt_chickpea   INT := 14;  -- Canned discard=730d, disc_start=540d
    pt_tuna       INT := 15;  -- Canned discard=730d, disc_start=540d

    v_id INT;
BEGIN

-- =====================================================================
-- FRESH batches — received recently, not yet in discount window
-- =====================================================================

-- Batch 1 : Milk, received 5 days ago  → disc starts day 10 (5 days away)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_milk, 200, 170, NOW() - INTERVAL '5 days', NOW() - INTERVAL '5 days' + INTERVAL '14 days', NOW() - INTERVAL '5 days' + INTERVAL '10 days')
RETURNING id INTO v_id;

-- Batch 2 : Yoghurt, received 3 days ago
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_yoghurt, 150, 140, NOW() - INTERVAL '3 days', NOW() - INTERVAL '3 days' + INTERVAL '14 days', NOW() - INTERVAL '3 days' + INTERVAL '10 days')
RETURNING id INTO v_id;

-- Batch 3 : Cheddar, received 4 days ago
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_cheddar, 120, 105, NOW() - INTERVAL '4 days', NOW() - INTERVAL '4 days' + INTERVAL '15 days', NOW() - INTERVAL '4 days' + INTERVAL '11 days')
RETURNING id INTO v_id;

-- Batch 4 : Sourdough, received TODAY (fresh)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sourdough, 80, 72, NOW(), NOW() + INTERVAL '5 days', NOW() + INTERVAL '3 days')
RETURNING id INTO v_id;

-- Batch 5 : Croissants, received 1 day ago (disc starts day 2 = tomorrow)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_croissant, 60, 48, NOW() - INTERVAL '1 day', NOW() - INTERVAL '1 day' + INTERVAL '4 days', NOW() - INTERVAL '1 day' + INTERVAL '2 days')
RETURNING id INTO v_id;

-- Batch 6 : Spinach, received 2 days ago (disc starts day 7 = 5 days away)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_spinach, 100, 90, NOW() - INTERVAL '2 days', NOW() - INTERVAL '2 days' + INTERVAL '10 days', NOW() - INTERVAL '2 days' + INTERVAL '7 days')
RETURNING id INTO v_id;

-- Batch 7 : Chicken, received 1 day ago (disc starts day 5 = 4 days away)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_chicken, 90, 82, NOW() - INTERVAL '1 day', NOW() - INTERVAL '1 day' + INTERVAL '7 days', NOW() - INTERVAL '1 day' + INTERVAL '5 days')
RETURNING id INTO v_id;

-- Batch 8 : Canned tomatoes (fresh — disc starts 540d from now, not relevant for a while)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_tomcan, 500, 490, NOW() - INTERVAL '10 days', NOW() - INTERVAL '10 days' + INTERVAL '730 days', NOW() - INTERVAL '10 days' + INTERVAL '540 days')
RETURNING id INTO v_id;

-- Batch 9 : Chickpeas (fresh canned)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_chickpea, 400, 385, NOW() - INTERVAL '20 days', NOW() - INTERVAL '20 days' + INTERVAL '730 days', NOW() - INTERVAL '20 days' + INTERVAL '540 days')
RETURNING id INTO v_id;

-- Batch 10: Tuna (fresh canned)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_tuna, 350, 330, NOW() - INTERVAL '15 days', NOW() - INTERVAL '15 days' + INTERVAL '730 days', NOW() - INTERVAL '15 days' + INTERVAL '540 days')
RETURNING id INTO v_id;


-- =====================================================================
-- DISCOUNTING batches — currently inside discount window
-- =====================================================================

-- Batch 11: Milk — received 12 days ago (disc started 2d ago, discards in 2d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_milk, 180, 60, NOW() - INTERVAL '12 days', NOW() - INTERVAL '12 days' + INTERVAL '14 days', NOW() - INTERVAL '12 days' + INTERVAL '10 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '2 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '12 days' + INTERVAL '10 days', NOW() - INTERVAL '12 days' + INTERVAL '14 days', NOW() - INTERVAL '2 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '12 days' + INTERVAL '10 days', NOW() - INTERVAL '12 days' + INTERVAL '14 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '12 days' + INTERVAL '10 days', NOW() - INTERVAL '12 days' + INTERVAL '14 days', NOW()) d;

-- Batch 12: Yoghurt — received 11 days ago (disc started 1d ago, discards in 3d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_yoghurt, 140, 55, NOW() - INTERVAL '11 days', NOW() - INTERVAL '11 days' + INTERVAL '14 days', NOW() - INTERVAL '11 days' + INTERVAL '10 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(1.65, 0.95, NOW() - INTERVAL '11 days' + INTERVAL '10 days', NOW() - INTERVAL '11 days' + INTERVAL '14 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(1.65, 0.95, NOW() - INTERVAL '11 days' + INTERVAL '10 days', NOW() - INTERVAL '11 days' + INTERVAL '14 days', NOW()) d;

-- Batch 13: Sourdough — received 3.5 days ago (disc started 0.5d ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sourdough, 70, 30, NOW() - INTERVAL '84 hours', NOW() - INTERVAL '84 hours' + INTERVAL '5 days', NOW() - INTERVAL '84 hours' + INTERVAL '3 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '12 hours'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '84 hours' + INTERVAL '3 days', NOW() - INTERVAL '84 hours' + INTERVAL '5 days', NOW() - INTERVAL '12 hours') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '84 hours' + INTERVAL '3 days', NOW() - INTERVAL '84 hours' + INTERVAL '5 days', NOW()) d;

-- Batch 14: Croissants — received 2.5 days ago (disc started 0.5d ago, discards in 1.5d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_croissant, 55, 20, NOW() - INTERVAL '60 hours', NOW() - INTERVAL '60 hours' + INTERVAL '4 days', NOW() - INTERVAL '60 hours' + INTERVAL '2 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '12 hours'
FROM compute_discounted_price(2.49, 1.45, NOW() - INTERVAL '60 hours' + INTERVAL '2 days', NOW() - INTERVAL '60 hours' + INTERVAL '4 days', NOW() - INTERVAL '12 hours') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(2.49, 1.45, NOW() - INTERVAL '60 hours' + INTERVAL '2 days', NOW() - INTERVAL '60 hours' + INTERVAL '4 days', NOW()) d;

-- Batch 15: Muffins — received 4 days ago (disc started 1d ago, discards in 1d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_muffin, 65, 18, NOW() - INTERVAL '4 days', NOW() - INTERVAL '4 days' + INTERVAL '5 days', NOW() - INTERVAL '4 days' + INTERVAL '3 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '22 hours'
FROM compute_discounted_price(1.79, 0.98, NOW() - INTERVAL '4 days' + INTERVAL '3 days', NOW() - INTERVAL '4 days' + INTERVAL '5 days', NOW() - INTERVAL '22 hours') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '10 hours'
FROM compute_discounted_price(1.79, 0.98, NOW() - INTERVAL '4 days' + INTERVAL '3 days', NOW() - INTERVAL '4 days' + INTERVAL '5 days', NOW() - INTERVAL '10 hours') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(1.79, 0.98, NOW() - INTERVAL '4 days' + INTERVAL '3 days', NOW() - INTERVAL '4 days' + INTERVAL '5 days', NOW()) d;

-- Batch 16: Spinach — received 8 days ago (disc started 1d ago, discards in 2d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_spinach, 110, 35, NOW() - INTERVAL '8 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW() - INTERVAL '8 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '8 days' + INTERVAL '7 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '8 days' + INTERVAL '7 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW()) d;

-- Batch 17: Vine Tomatoes — received 8 days ago (disc started 1d ago, discards in 2d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_tomato, 130, 44, NOW() - INTERVAL '8 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW() - INTERVAL '8 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '8 days' + INTERVAL '7 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '8 days' + INTERVAL '7 days', NOW() - INTERVAL '8 days' + INTERVAL '10 days', NOW()) d;

-- Batch 18: Broccoli — received 7 days ago (disc started 1d ago, discards in 2d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_broccoli, 95, 28, NOW() - INTERVAL '7 days', NOW() - INTERVAL '7 days' + INTERVAL '9 days', NOW() - INTERVAL '7 days' + INTERVAL '6 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(0.75, 0.45, NOW() - INTERVAL '7 days' + INTERVAL '6 days', NOW() - INTERVAL '7 days' + INTERVAL '9 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(0.75, 0.45, NOW() - INTERVAL '7 days' + INTERVAL '6 days', NOW() - INTERVAL '7 days' + INTERVAL '9 days', NOW()) d;

-- Batch 19: Chicken — received 6 days ago (disc started 1d ago, discards in 1d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_chicken, 85, 22, NOW() - INTERVAL '6 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW() - INTERVAL '6 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '6 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '6 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW()) d;

-- Batch 20: Beef Mince — received 6 days ago (disc started 1d ago, discards in 1d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_beef, 100, 30, NOW() - INTERVAL '6 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW() - INTERVAL '6 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '6 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '6 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days' + INTERVAL '7 days', NOW()) d;

-- Batch 21: Pork Sausages — received 5 days ago (disc started 1d ago, discards in 1d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sausage, 75, 18, NOW() - INTERVAL '5 days', NOW() - INTERVAL '5 days' + INTERVAL '6 days', NOW() - INTERVAL '5 days' + INTERVAL '4 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(3.59, 1.90, NOW() - INTERVAL '5 days' + INTERVAL '4 days', NOW() - INTERVAL '5 days' + INTERVAL '6 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(3.59, 1.90, NOW() - INTERVAL '5 days' + INTERVAL '4 days', NOW() - INTERVAL '5 days' + INTERVAL '6 days', NOW()) d;

-- Batch 22: Cheddar — received 12 days ago (disc started 1d ago, discards in 3d)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_cheddar, 100, 40, NOW() - INTERVAL '12 days', NOW() - INTERVAL '12 days' + INTERVAL '15 days', NOW() - INTERVAL '12 days' + INTERVAL '11 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '1 day'
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '12 days' + INTERVAL '11 days', NOW() - INTERVAL '12 days' + INTERVAL '15 days', NOW() - INTERVAL '1 day') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW()
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '12 days' + INTERVAL '11 days', NOW() - INTERVAL '12 days' + INTERVAL '15 days', NOW()) d;


-- =====================================================================
-- DISPOSED batches — discard_at is in the past
-- =====================================================================

-- Batch 23: Milk — received 18 days ago, discarded 4 days ago
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_milk, 200, 0, NOW() - INTERVAL '18 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '18 days' + INTERVAL '10 days')
RETURNING id INTO v_id;
-- Discount events during the window (days 10–14 from received = 8 days ago to 4 days ago)
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '8 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '18 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '8 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '7 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '18 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '7 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '18 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '18 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days' - INTERVAL '1 hour'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '18 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days', NOW() - INTERVAL '18 days' + INTERVAL '14 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 12, NOW() - INTERVAL '4 days', 'Remaining stock donated to local food bank before discard time');

-- Batch 24: Yoghurt — received 20 days ago
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_yoghurt, 130, 0, NOW() - INTERVAL '20 days', NOW() - INTERVAL '20 days' + INTERVAL '14 days', NOW() - INTERVAL '20 days' + INTERVAL '10 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '10 days'
FROM compute_discounted_price(1.65, 0.95, NOW() - INTERVAL '20 days' + INTERVAL '10 days', NOW() - INTERVAL '20 days' + INTERVAL '14 days', NOW() - INTERVAL '10 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '8 days'
FROM compute_discounted_price(1.65, 0.95, NOW() - INTERVAL '20 days' + INTERVAL '10 days', NOW() - INTERVAL '20 days' + INTERVAL '14 days', NOW() - INTERVAL '8 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '7 days'
FROM compute_discounted_price(1.65, 0.95, NOW() - INTERVAL '20 days' + INTERVAL '10 days', NOW() - INTERVAL '20 days' + INTERVAL '14 days', NOW() - INTERVAL '7 days') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 8, NOW() - INTERVAL '6 days', NULL);

-- Batch 25: Sourdough — received 9 days ago (discard 4 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sourdough, 65, 0, NOW() - INTERVAL '9 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '9 days' + INTERVAL '3 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '9 days' + INTERVAL '3 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '9 days' + INTERVAL '3 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days' - INTERVAL '2 hours'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '9 days' + INTERVAL '3 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'animal_feed', 5, NOW() - INTERVAL '4 days', 'Unsold loaves sent to local farm');

-- Batch 26: Croissants — received 8 days ago (discard 4 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_croissant, 50, 0, NOW() - INTERVAL '8 days', NOW() - INTERVAL '8 days' + INTERVAL '4 days', NOW() - INTERVAL '8 days' + INTERVAL '2 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(2.49, 1.45, NOW() - INTERVAL '8 days' + INTERVAL '2 days', NOW() - INTERVAL '8 days' + INTERVAL '4 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(2.49, 1.45, NOW() - INTERVAL '8 days' + INTERVAL '2 days', NOW() - INTERVAL '8 days' + INTERVAL '4 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days' - INTERVAL '1 hour'
FROM compute_discounted_price(2.49, 1.45, NOW() - INTERVAL '8 days' + INTERVAL '2 days', NOW() - INTERVAL '8 days' + INTERVAL '4 days', NOW() - INTERVAL '8 days' + INTERVAL '4 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 6, NOW() - INTERVAL '4 days', 'Donated to community café');

-- Batch 27: Muffins — received 9 days ago (discard 4 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_muffin, 60, 0, NOW() - INTERVAL '9 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '9 days' + INTERVAL '3 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(1.79, 0.98, NOW() - INTERVAL '9 days' + INTERVAL '3 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(1.79, 0.98, NOW() - INTERVAL '9 days' + INTERVAL '3 days', NOW() - INTERVAL '9 days' + INTERVAL '5 days', NOW() - INTERVAL '5 days') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 4, NOW() - INTERVAL '4 days', NULL);

-- Batch 28: Spinach — received 15 days ago (discard 5 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_spinach, 100, 0, NOW() - INTERVAL '15 days', NOW() - INTERVAL '15 days' + INTERVAL '10 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '8 days'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days' + INTERVAL '10 days', NOW() - INTERVAL '8 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '7 days'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days' + INTERVAL '10 days', NOW() - INTERVAL '7 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days' + INTERVAL '10 days', NOW() - INTERVAL '6 days') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 15, NOW() - INTERVAL '5 days', 'Badly wilted — composted');

-- Batch 29: Vine Tomatoes — received 14 days ago (discard 4 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_tomato, 120, 0, NOW() - INTERVAL '14 days', NOW() - INTERVAL '14 days' + INTERVAL '10 days', NOW() - INTERVAL '14 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '7 days'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '14 days' + INTERVAL '7 days', NOW() - INTERVAL '14 days' + INTERVAL '10 days', NOW() - INTERVAL '7 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '14 days' + INTERVAL '7 days', NOW() - INTERVAL '14 days' + INTERVAL '10 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days' - INTERVAL '1 hour'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '14 days' + INTERVAL '7 days', NOW() - INTERVAL '14 days' + INTERVAL '10 days', NOW() - INTERVAL '14 days' + INTERVAL '10 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 18, NOW() - INTERVAL '4 days', 'Donated to soup kitchen');

-- Batch 30: Broccoli — received 12 days ago (discard 3 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_broccoli, 90, 0, NOW() - INTERVAL '12 days', NOW() - INTERVAL '12 days' + INTERVAL '9 days', NOW() - INTERVAL '12 days' + INTERVAL '6 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(0.75, 0.45, NOW() - INTERVAL '12 days' + INTERVAL '6 days', NOW() - INTERVAL '12 days' + INTERVAL '9 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(0.75, 0.45, NOW() - INTERVAL '12 days' + INTERVAL '6 days', NOW() - INTERVAL '12 days' + INTERVAL '9 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days'
FROM compute_discounted_price(0.75, 0.45, NOW() - INTERVAL '12 days' + INTERVAL '6 days', NOW() - INTERVAL '12 days' + INTERVAL '9 days', NOW() - INTERVAL '4 days') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'animal_feed', 10, NOW() - INTERVAL '3 days', 'Sent to local farm');

-- Batch 31: Chicken — received 12 days ago (discard 5 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_chicken, 80, 0, NOW() - INTERVAL '12 days', NOW() - INTERVAL '12 days' + INTERVAL '7 days', NOW() - INTERVAL '12 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '7 days'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '12 days' + INTERVAL '5 days', NOW() - INTERVAL '12 days' + INTERVAL '7 days', NOW() - INTERVAL '7 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '12 days' + INTERVAL '5 days', NOW() - INTERVAL '12 days' + INTERVAL '7 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days' - INTERVAL '1 hour'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '12 days' + INTERVAL '5 days', NOW() - INTERVAL '12 days' + INTERVAL '7 days', NOW() - INTERVAL '12 days' + INTERVAL '7 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 3, NOW() - INTERVAL '5 days', 'Regulatory requirement — meat past use-by date');

-- Batch 32: Beef Mince — received 15 days ago (discard 8 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_beef, 95, 0, NOW() - INTERVAL '15 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '10 days'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '15 days' + INTERVAL '5 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '10 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '9 days'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '15 days' + INTERVAL '5 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '9 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '8 days' - INTERVAL '1 hour'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '15 days' + INTERVAL '5 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days' + INTERVAL '7 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 5, NOW() - INTERVAL '8 days', 'Past use-by date');

-- Batch 33: Pork Sausages — received 10 days ago (discard 4 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sausage, 70, 0, NOW() - INTERVAL '10 days', NOW() - INTERVAL '10 days' + INTERVAL '6 days', NOW() - INTERVAL '10 days' + INTERVAL '4 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '6 days'
FROM compute_discounted_price(3.59, 1.90, NOW() - INTERVAL '10 days' + INTERVAL '4 days', NOW() - INTERVAL '10 days' + INTERVAL '6 days', NOW() - INTERVAL '6 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '5 days'
FROM compute_discounted_price(3.59, 1.90, NOW() - INTERVAL '10 days' + INTERVAL '4 days', NOW() - INTERVAL '10 days' + INTERVAL '6 days', NOW() - INTERVAL '5 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '4 days' - INTERVAL '1 hour'
FROM compute_discounted_price(3.59, 1.90, NOW() - INTERVAL '10 days' + INTERVAL '4 days', NOW() - INTERVAL '10 days' + INTERVAL '6 days', NOW() - INTERVAL '10 days' + INTERVAL '6 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 4, NOW() - INTERVAL '4 days', 'Donated to food pantry day before discard');

-- Batch 34: Cheddar — received 25 days ago (discard 10 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_cheddar, 110, 0, NOW() - INTERVAL '25 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days', NOW() - INTERVAL '25 days' + INTERVAL '11 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '14 days'
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '25 days' + INTERVAL '11 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days', NOW() - INTERVAL '14 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '13 days'
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '25 days' + INTERVAL '11 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days', NOW() - INTERVAL '13 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '11 days'
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '25 days' + INTERVAL '11 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days', NOW() - INTERVAL '11 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '10 days' - INTERVAL '1 hour'
FROM compute_discounted_price(3.79, 2.10, NOW() - INTERVAL '25 days' + INTERVAL '11 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days', NOW() - INTERVAL '25 days' + INTERVAL '15 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 7, NOW() - INTERVAL '10 days', NULL);

-- Batch 35: Milk — received 30 days ago (discard 16 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_milk, 190, 0, NOW() - INTERVAL '30 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '20 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days', NOW() - INTERVAL '20 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '18 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days', NOW() - INTERVAL '18 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '17 days'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days', NOW() - INTERVAL '17 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '16 days' - INTERVAL '1 hour'
FROM compute_discounted_price(1.09, 0.62, NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days', NOW() - INTERVAL '30 days' + INTERVAL '14 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 20, NOW() - INTERVAL '16 days', 'Large surplus donated');

-- Batch 36: Chicken — received 20 days ago (discard 13 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_chicken, 75, 0, NOW() - INTERVAL '20 days', NOW() - INTERVAL '20 days' + INTERVAL '7 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '15 days'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '20 days' + INTERVAL '7 days', NOW() - INTERVAL '15 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '14 days'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '20 days' + INTERVAL '7 days', NOW() - INTERVAL '14 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '13 days' - INTERVAL '1 hour'
FROM compute_discounted_price(4.49, 2.40, NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '20 days' + INTERVAL '7 days', NOW() - INTERVAL '20 days' + INTERVAL '7 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 2, NOW() - INTERVAL '13 days', 'Past use-by — destroyed per food safety policy');

-- Batch 37: Sourdough — received 20 days ago (discard 15 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_sourdough, 60, 0, NOW() - INTERVAL '20 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '20 days' + INTERVAL '3 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '17 days'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '20 days' + INTERVAL '3 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '17 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '16 days'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '20 days' + INTERVAL '3 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '16 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '15 days' - INTERVAL '2 hours'
FROM compute_discounted_price(2.09, 1.20, NOW() - INTERVAL '20 days' + INTERVAL '3 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days', NOW() - INTERVAL '20 days' + INTERVAL '5 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'animal_feed', 3, NOW() - INTERVAL '15 days', NULL);

-- Batch 38: Beef Mince — received 25 days ago (discard 18 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_beef, 90, 0, NOW() - INTERVAL '25 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '25 days' + INTERVAL '5 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '20 days'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '25 days' + INTERVAL '5 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '20 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '19 days'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '25 days' + INTERVAL '5 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '19 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '18 days' - INTERVAL '1 hour'
FROM compute_discounted_price(5.29, 2.80, NOW() - INTERVAL '25 days' + INTERVAL '5 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 6, NOW() - INTERVAL '18 days', 'Past use-by date');

-- Batch 39: Baby Spinach — received 25 days ago (discard 15 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_spinach, 115, 0, NOW() - INTERVAL '25 days', NOW() - INTERVAL '25 days' + INTERVAL '10 days', NOW() - INTERVAL '25 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '18 days'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '25 days' + INTERVAL '10 days', NOW() - INTERVAL '18 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '16 days'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '25 days' + INTERVAL '10 days', NOW() - INTERVAL '16 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '15 days' - INTERVAL '1 hour'
FROM compute_discounted_price(0.89, 0.55, NOW() - INTERVAL '25 days' + INTERVAL '7 days', NOW() - INTERVAL '25 days' + INTERVAL '10 days', NOW() - INTERVAL '25 days' + INTERVAL '10 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'discarded', 20, NOW() - INTERVAL '15 days', 'Unusable — composted');

-- Batch 40: Vine Tomatoes — received 30 days ago (discard 20 days ago)
INSERT INTO batches (product_type_id, quantity_received, quantity_remaining, received_at, discard_at, discount_starts_at)
VALUES (pt_tomato, 125, 0, NOW() - INTERVAL '30 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '7 days')
RETURNING id INTO v_id;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '23 days'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '30 days' + INTERVAL '7 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '23 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '22 days'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '30 days' + INTERVAL '7 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '22 days') d;
INSERT INTO discount_events (batch_id, discount_percentage, discounted_price, calculated_at)
SELECT v_id, d.discount_pct, d.sale_price, NOW() - INTERVAL '20 days' - INTERVAL '1 hour'
FROM compute_discounted_price(0.99, 0.60, NOW() - INTERVAL '30 days' + INTERVAL '7 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days', NOW() - INTERVAL '30 days' + INTERVAL '10 days' - INTERVAL '1 hour') d;
INSERT INTO disposal_log (batch_id, disposal_method, quantity_disposed, disposed_at, notes)
VALUES (v_id, 'donated', 30, NOW() - INTERVAL '20 days', 'Good condition — donated to local shelter');

END;
$$;

-- ---------------------------------------------------------------
-- 8. VERIFICATION — quick row counts (visible in docker logs)
-- ---------------------------------------------------------------
DO $$
DECLARE
    c_pt  INT; c_b INT; c_de INT; c_dl INT;
BEGIN
    SELECT COUNT(*) INTO c_pt FROM product_types;
    SELECT COUNT(*) INTO c_b  FROM batches;
    SELECT COUNT(*) INTO c_de FROM discount_events;
    SELECT COUNT(*) INTO c_dl FROM disposal_log;
    RAISE NOTICE 'Init complete — product_types: %, batches: %, discount_events: %, disposal_log: %',
        c_pt, c_b, c_de, c_dl;
END;
$$;

/**
 * server/src/index.ts
 *
 * Express API server that sits between the Expo app and PostgreSQL.
 * React Native cannot connect to Postgres directly — this bridge handles all
 * DB communication and returns clean camelCase JSON.
 *
 * Endpoints
 * ─────────────────────────────────────────────────────────────────────────────
 * GET  /health                          → liveness probe
 * GET  /api/product-types               → all product types (SKU catalogue)
 * GET  /api/batches/active              → active_batches_view
 * GET  /api/batches/expiring?limit=n    → soonest-expiring active batches
 * GET  /api/batches/:id/history         → discount_events for one batch
 * GET  /api/products/discounted         → current_discounted_products_view
 * GET  /api/products/low-stock?threshold=n
 * GET  /api/disposal/summary            → disposal_log aggregate
 * GET  /api/price/compute?batchId=&atTimestamp=
 */

import express, { Request, Response, NextFunction } from 'express';
import { Pool } from 'pg';

// ─── DB Connection ────────────────────────────────────────────────────────────

const pool = new Pool({
  host:     process.env.DB_HOST     ?? 'localhost',
  port:     Number(process.env.DB_PORT ?? 5432),
  database: process.env.DB_NAME     ?? 'supermarket_db',
  user:     process.env.DB_USER     ?? 'supermarket_user',
  password: process.env.DB_PASSWORD ?? 'supermarket_pass',
});

// ─── App ─────────────────────────────────────────────────────────────────────

const app  = express();
const PORT = Number(process.env.PORT ?? 3001);

app.use(express.json());

// Allow requests from the Expo dev server on any origin (dev only).
app.use((_req, res, next) => {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  next();
});

// ─── Response helpers ─────────────────────────────────────────────────────────

function ok<T>(res: Response, data: T): void {
  res.json({ data, error: null });
}

function fail(res: Response, status: number, message: string): void {
  res.status(status).json({ data: null, error: message });
}

// ─── /health ─────────────────────────────────────────────────────────────────

app.get('/health', async (_req, res) => {
  try {
    await pool.query('SELECT 1');
    ok(res, { status: 'ok' });
  } catch {
    fail(res, 503, 'Database unreachable');
  }
});

// ─── GET /api/product-types ──────────────────────────────────────────────────

app.get('/api/product-types', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        id,
        name,
        category,
        buy_cost::float            AS "buyCost",
        optimal_price::float       AS "optimalPrice",
        days_until_start_of_discount AS "daysUntilStartOfDiscount",
        days_until_discard           AS "daysUntilDiscard"
      FROM product_types
      ORDER BY category, name
    `);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/batches/active ─────────────────────────────────────────────────

app.get('/api/batches/active', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        batch_id                            AS "batchId",
        product_name                        AS "productName",
        category,
        quantity_received                   AS "quantityReceived",
        quantity_remaining                  AS "quantityRemaining",
        received_at                         AS "receivedAt",
        discount_starts_at                  AS "discountStartsAt",
        discard_at                          AS "discardAt",
        status,
        latest_discount_pct::float          AS "latestDiscountPct",
        latest_discounted_price::float      AS "latestDiscountedPrice",
        EXTRACT(EPOCH FROM (discard_at - NOW()))::int AS "secondsUntilDiscard"
      FROM active_batches_view
      ORDER BY status, discard_at
    `);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/batches/expiring ───────────────────────────────────────────────

app.get('/api/batches/expiring', async (req, res) => {
  const limit = Math.min(Number(req.query.limit ?? 10), 100);
  try {
    const { rows } = await pool.query(`
      SELECT
        batch_id                            AS "batchId",
        product_name                        AS "productName",
        category,
        quantity_received                   AS "quantityReceived",
        quantity_remaining                  AS "quantityRemaining",
        received_at                         AS "receivedAt",
        discount_starts_at                  AS "discountStartsAt",
        discard_at                          AS "discardAt",
        status,
        latest_discount_pct::float          AS "latestDiscountPct",
        latest_discounted_price::float      AS "latestDiscountedPrice",
        EXTRACT(EPOCH FROM (discard_at - NOW()))::int AS "secondsUntilDiscard"
      FROM active_batches_view
      ORDER BY discard_at ASC
      LIMIT $1
    `, [limit]);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/batches/:id/history ────────────────────────────────────────────

app.get('/api/batches/:id/history', async (req, res) => {
  const batchId = Number(req.params.id);
  if (!Number.isInteger(batchId) || batchId <= 0) {
    return fail(res, 400, 'batchId must be a positive integer');
  }
  try {
    const { rows } = await pool.query(`
      SELECT
        id,
        batch_id                  AS "batchId",
        discount_percentage::float AS "discountPercentage",
        discounted_price::float    AS "discountedPrice",
        calculated_at              AS "calculatedAt"
      FROM discount_events
      WHERE batch_id = $1
      ORDER BY calculated_at ASC
    `, [batchId]);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/products/discounted ────────────────────────────────────────────

app.get('/api/products/discounted', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        batch_id                       AS "batchId",
        product_name                   AS "productName",
        category,
        quantity_remaining             AS "quantityRemaining",
        optimal_price::float           AS "optimalPrice",
        buy_cost::float                AS "buyCost",
        price_floor::float             AS "priceFloor",
        current_discount_pct::float    AS "currentDiscountPct",
        current_price::float           AS "currentPrice",
        discount_starts_at             AS "discountStartsAt",
        discard_at                     AS "discardAt",
        last_calculated_at             AS "lastCalculatedAt",
        EXTRACT(EPOCH FROM (discard_at - NOW()))::int AS "secondsUntilDiscard"
      FROM current_discounted_products_view
      ORDER BY current_discount_pct DESC
    `);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/products/low-stock ─────────────────────────────────────────────

app.get('/api/products/low-stock', async (req, res) => {
  const threshold = Math.max(1, Number(req.query.threshold ?? 5));
  try {
    const { rows } = await pool.query(`
      SELECT
        batch_id                       AS "batchId",
        product_name                   AS "productName",
        category,
        quantity_remaining             AS "quantityRemaining",
        optimal_price::float           AS "optimalPrice",
        buy_cost::float                AS "buyCost",
        price_floor::float             AS "priceFloor",
        current_discount_pct::float    AS "currentDiscountPct",
        current_price::float           AS "currentPrice",
        discount_starts_at             AS "discountStartsAt",
        discard_at                     AS "discardAt",
        last_calculated_at             AS "lastCalculatedAt",
        EXTRACT(EPOCH FROM (discard_at - NOW()))::int AS "secondsUntilDiscard"
      FROM current_discounted_products_view
      WHERE quantity_remaining < $1
      ORDER BY quantity_remaining ASC
    `, [threshold]);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/disposal/summary ───────────────────────────────────────────────

app.get('/api/disposal/summary', async (_req, res) => {
  try {
    const { rows } = await pool.query(`
      SELECT
        disposal_method  AS "disposalMethod",
        COUNT(*)::int    AS "batches",
        SUM(quantity_disposed)::int AS "totalUnits"
      FROM disposal_log
      GROUP BY disposal_method
      ORDER BY disposal_method
    `);
    ok(res, rows);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── GET /api/price/compute ───────────────────────────────────────────────────
// Uses the DB helper compute_discounted_price() for an authoritative price.

app.get('/api/price/compute', async (req, res) => {
  const batchId = Number(req.query.batchId);
  if (!Number.isInteger(batchId) || batchId <= 0) {
    return fail(res, 400, 'batchId must be a positive integer');
  }

  // atTimestamp is optional; fall back to NOW()
  const atTimestamp: string | null =
    typeof req.query.atTimestamp === 'string' ? req.query.atTimestamp : null;

  try {
    const { rows } = await pool.query(`
      SELECT
        d.discount_pct::float  AS "discountPct",
        d.sale_price::float    AS "salePrice"
      FROM batches b
      JOIN product_types pt ON pt.id = b.product_type_id
      JOIN LATERAL compute_discounted_price(
        pt.optimal_price,
        pt.buy_cost,
        b.discount_starts_at,
        b.discard_at,
        $2::timestamptz
      ) d ON TRUE
      WHERE b.id = $1
    `, [batchId, atTimestamp ?? 'NOW()']);

    if (rows.length === 0) return fail(res, 404, `Batch ${batchId} not found`);
    ok(res, rows[0]);
  } catch (err) {
    fail(res, 500, String(err));
  }
});

// ─── 404 catch-all ───────────────────────────────────────────────────────────

app.use((req, res) => {
  fail(res, 404, `Route ${req.method} ${req.path} not found`);
});

// ─── Error handler ────────────────────────────────────────────────────────────

app.use((err: Error, _req: Request, res: Response, _next: NextFunction) => {
  console.error(err);
  fail(res, 500, err.message);
});

// ─── Start ───────────────────────────────────────────────────────────────────

app.listen(PORT, () => {
  console.log(`Supermarket API server running on http://localhost:${PORT}`);
});

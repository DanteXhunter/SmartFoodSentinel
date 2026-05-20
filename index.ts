// ─── Domain Types ────────────────────────────────────────────────────────────
// Derived 1-to-1 from the schema documented in AGENT_CONTEXT.md.
// All numeric DB columns arrive as strings from pg; the API layer parses them
// to numbers before handing them to consumers.

export type ProductCategory = 'Dairy' | 'Bakery' | 'Produce' | 'Meat' | 'Canned';

export type BatchStatus = 'fresh' | 'discounting' | 'expired';

export type DisposalMethod = 'discarded' | 'donated' | 'animal_feed';

// ─── product_types table ─────────────────────────────────────────────────────

export interface ProductType {
  id: number;
  name: string;
  category: ProductCategory;
  /** Wholesale cost */
  buyCost: number;
  /** Full shelf price before discounting */
  optimalPrice: number;
  /** Days after receipt when discounting begins */
  daysUntilStartOfDiscount: number;
  /** Days after receipt when the batch must be disposed */
  daysUntilDiscard: number;
}

// ─── batches table ───────────────────────────────────────────────────────────

export interface Batch {
  id: number;
  productTypeId: number;
  quantityReceived: number;
  quantityRemaining: number;
  receivedAt: string;       // ISO-8601
  discountStartsAt: string; // ISO-8601
  discardAt: string;        // ISO-8601
  /** Derived from timestamps vs NOW() — not stored in DB */
  status: BatchStatus;
}

// ─── discount_events table ───────────────────────────────────────────────────

export interface DiscountEvent {
  id: number;
  batchId: number;
  /** e.g. 23.50 means 23.5% off */
  discountPercentage: number;
  discountedPrice: number;
  calculatedAt: string; // ISO-8601
}

// ─── disposal_log table ──────────────────────────────────────────────────────

export interface DisposalLog {
  id: number;
  batchId: number;
  disposalMethod: DisposalMethod;
  quantityDisposed: number;
  disposedAt: string; // ISO-8601
  notes: string | null;
}

// ─── View: active_batches_view ───────────────────────────────────────────────
// All batches whose discard_at is still in the future.

export interface ActiveBatch {
  batchId: number;
  productName: string;
  category: ProductCategory;
  quantityReceived: number;
  quantityRemaining: number;
  receivedAt: string;
  discountStartsAt: string;
  discardAt: string;
  status: 'fresh' | 'discounting';
  /** Null if batch hasn't entered its discount window yet */
  latestDiscountPct: number | null;
  /** Null if batch hasn't entered its discount window yet */
  latestDiscountedPrice: number | null;
  /** Convenience: seconds until discard from now */
  secondsUntilDiscard: number;
}

// ─── View: current_discounted_products_view ──────────────────────────────────
// Only batches currently inside their discount window, with stock remaining.

export interface DiscountedProduct {
  batchId: number;
  productName: string;
  category: ProductCategory;
  quantityRemaining: number;
  optimalPrice: number;
  buyCost: number;
  /** buy_cost × 1.08 — never sell below this */
  priceFloor: number;
  currentDiscountPct: number;
  currentPrice: number;
  discountStartsAt: string;
  discardAt: string;
  lastCalculatedAt: string;
  /** Convenience: seconds until discard from now */
  secondsUntilDiscard: number;
}

// ─── compute_discounted_price() result ───────────────────────────────────────

export interface ComputedPrice {
  discountPct: number;
  salePrice: number;
}

// ─── Disposal summary (waste reporting) ──────────────────────────────────────

export interface DisposalSummary {
  disposalMethod: DisposalMethod;
  batches: number;
  totalUnits: number;
}

// ─── API Response envelope ───────────────────────────────────────────────────
// Every endpoint wraps its payload in { data } or { error }.

export type ApiOk<T> = { data: T; error: null };
export type ApiErr    = { data: null; error: string };
export type ApiResponse<T> = ApiOk<T> | ApiErr;

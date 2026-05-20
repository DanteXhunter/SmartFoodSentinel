/**
 * api/supermarket.ts
 *
 * Every function here maps 1-to-1 to an Express endpoint on the server.
 * Hooks call these; the visual layer calls hooks.
 *
 * Naming convention:  verb + noun(s)
 *   fetchActiveBatches()        → GET /api/batches/active
 *   fetchDiscountedProducts()   → GET /api/products/discounted
 *   fetchBatchHistory(id)       → GET /api/batches/:id/history
 *   fetchDisposalSummary()      → GET /api/disposal/summary
 *   fetchExpiringBatches(n)     → GET /api/batches/expiring?limit=n
 *   fetchLowStockDiscounting(n) → GET /api/products/low-stock?threshold=n
 *   fetchProductTypes()         → GET /api/product-types
 *   computeLivePrice(params)    → GET /api/price/compute?...
 */

import { apiClient } from './client';
import type {
  ActiveBatch,
  DiscountedProduct,
  DiscountEvent,
  DisposalSummary,
  ComputedPrice,
  ProductType,
} from '../types';

// ─── Active batches (fresh + discounting) ────────────────────────────────────

export function fetchActiveBatches(): Promise<ActiveBatch[]> {
  return apiClient.get<ActiveBatch[]>('/api/batches/active');
}

// ─── Currently discounting products ──────────────────────────────────────────

export function fetchDiscountedProducts(): Promise<DiscountedProduct[]> {
  return apiClient.get<DiscountedProduct[]>('/api/products/discounted');
}

// ─── Discount event history for a single batch ───────────────────────────────

export function fetchBatchHistory(batchId: number): Promise<DiscountEvent[]> {
  return apiClient.get<DiscountEvent[]>(`/api/batches/${batchId}/history`);
}

// ─── Products expiring soonest ───────────────────────────────────────────────
// Returns batches ordered by discard_at ASC, optionally limited.

export function fetchExpiringBatches(limit = 10): Promise<ActiveBatch[]> {
  return apiClient.get<ActiveBatch[]>(`/api/batches/expiring?limit=${limit}`);
}

// ─── Low-stock discounting batches ───────────────────────────────────────────
// threshold: quantity_remaining < threshold

export function fetchLowStockDiscounting(threshold = 5): Promise<DiscountedProduct[]> {
  return apiClient.get<DiscountedProduct[]>(
    `/api/products/low-stock?threshold=${threshold}`,
  );
}

// ─── Disposal summary (waste reporting) ──────────────────────────────────────

export function fetchDisposalSummary(): Promise<DisposalSummary[]> {
  return apiClient.get<DisposalSummary[]>('/api/disposal/summary');
}

// ─── All product types (SKU catalogue) ───────────────────────────────────────

export function fetchProductTypes(): Promise<ProductType[]> {
  return apiClient.get<ProductType[]>('/api/product-types');
}

// ─── Live / hypothetical price computation ───────────────────────────────────
// Wraps compute_discounted_price() for a specific batch at a given timestamp.

export interface ComputePriceParams {
  batchId: number;
  /** ISO-8601; defaults to NOW() on the server if omitted */
  atTimestamp?: string;
}

export function computeLivePrice(params: ComputePriceParams): Promise<ComputedPrice> {
  const qs = new URLSearchParams({ batchId: String(params.batchId) });
  if (params.atTimestamp) qs.set('atTimestamp', params.atTimestamp);
  return apiClient.get<ComputedPrice>(`/api/price/compute?${qs}`);
}

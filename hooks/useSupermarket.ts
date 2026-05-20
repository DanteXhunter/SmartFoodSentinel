/**
 * hooks/useSupermarket.ts
 *
 * All domain hooks live here.  The visual layer imports only from this file
 * (and ../types).  It never touches the api/ layer directly.
 *
 * Each hook follows this contract:
 *   { data, loading, error, refetch }
 *
 * Polling hooks also accept a `pollIntervalMs` option so screens can keep
 * prices fresh without manually calling refetch.
 */

import { useCallback, useMemo } from 'react';
import { useQuery, QueryState } from './useQuery';
import {
  fetchActiveBatches,
  fetchDiscountedProducts,
  fetchBatchHistory,
  fetchExpiringBatches,
  fetchLowStockDiscounting,
  fetchDisposalSummary,
  fetchProductTypes,
  computeLivePrice,
  ComputePriceParams,
} from '../api/supermarket';
import type {
  ActiveBatch,
  DiscountedProduct,
  DiscountEvent,
  DisposalSummary,
  ComputedPrice,
  ProductType,
  BatchStatus,
  ProductCategory,
} from '../types';

// ─── Re-export types so consumers only need one import path ──────────────────
export type {
  ActiveBatch,
  DiscountedProduct,
  DiscountEvent,
  DisposalSummary,
  ComputedPrice,
  ProductType,
  BatchStatus,
  ProductCategory,
};

// ─── useActiveBatches ────────────────────────────────────────────────────────
/**
 * All non-expired batches (fresh + discounting).
 * Suitable for an overview / inventory screen.
 */
export function useActiveBatches(): QueryState<ActiveBatch[]> {
  return useQuery(fetchActiveBatches);
}

// ─── useDiscountedProducts ───────────────────────────────────────────────────
/**
 * Products currently inside their discount window with stock remaining.
 * Ordered by current_discount_pct DESC (biggest discounts first).
 * Use this to power a "Today's Deals" screen.
 *
 * @param pollIntervalMs  If provided, auto-refetches on that interval.
 *                        Prices change continuously — 60 000 ms is a good default.
 */
export function useDiscountedProducts(pollIntervalMs?: number): QueryState<DiscountedProduct[]> {
  const query = useQuery(fetchDiscountedProducts);

  // Polling via setInterval — only active when the component is mounted.
  const { refetch } = query;
  usePoll(refetch, pollIntervalMs);

  return query;
}

// ─── useBatchHistory ─────────────────────────────────────────────────────────
/**
 * Full discount event history for a specific batch.
 * Use this to render a price-over-time chart for a single product.
 */
export function useBatchHistory(batchId: number): QueryState<DiscountEvent[]> {
  const fetcher = useCallback(() => fetchBatchHistory(batchId), [batchId]);
  return useQuery(fetcher, [batchId]);
}

// ─── useExpiringBatches ──────────────────────────────────────────────────────
/**
 * Batches expiring soonest — good for a "needs attention" widget or
 * donation/promotion decisions.
 *
 * @param limit  How many batches to return (default 10).
 */
export function useExpiringBatches(limit = 10): QueryState<ActiveBatch[]> {
  const fetcher = useCallback(() => fetchExpiringBatches(limit), [limit]);
  return useQuery(fetcher, [limit]);
}

// ─── useLowStockDiscounting ──────────────────────────────────────────────────
/**
 * Discounting batches where quantity_remaining < threshold.
 * Useful for a restocking alert panel.
 *
 * @param threshold  quantity_remaining below this triggers inclusion (default 5).
 */
export function useLowStockDiscounting(threshold = 5): QueryState<DiscountedProduct[]> {
  const fetcher = useCallback(() => fetchLowStockDiscounting(threshold), [threshold]);
  return useQuery(fetcher, [threshold]);
}

// ─── useDisposalSummary ──────────────────────────────────────────────────────
/**
 * Aggregated waste report: batches + units per disposal method.
 * Powers a waste / sustainability dashboard.
 */
export function useDisposalSummary(): QueryState<DisposalSummary[]> {
  return useQuery(fetchDisposalSummary);
}

// ─── useProductTypes ─────────────────────────────────────────────────────────
/**
 * Full SKU catalogue. Rarely changes — fetch once on app start.
 */
export function useProductTypes(): QueryState<ProductType[]> {
  return useQuery(fetchProductTypes);
}

// ─── useLivePrice ────────────────────────────────────────────────────────────
/**
 * Live (or hypothetical) price for a single batch via compute_discounted_price().
 * The server applies the exponential curve and enforces the price floor.
 *
 * @param params.batchId       Which batch to price.
 * @param params.atTimestamp   Optional ISO-8601; if omitted, server uses NOW().
 * @param pollIntervalMs       Optional auto-refresh interval in ms.
 */
export function useLivePrice(
  params: ComputePriceParams,
  pollIntervalMs?: number,
): QueryState<ComputedPrice> {
  const fetcher = useCallback(() => computeLivePrice(params), [
    params.batchId,
    params.atTimestamp,
  ]);
  const query = useQuery(fetcher, [params.batchId, params.atTimestamp]);
  usePoll(query.refetch, pollIntervalMs);
  return query;
}

// ─── useCategoryFilter ───────────────────────────────────────────────────────
/**
 * Client-side filter on top of useDiscountedProducts.
 * Returns products filtered by category — no extra network call.
 *
 * @param category  Pass null / undefined to return all categories.
 */
export function useCategoryFilter(
  category?: ProductCategory | null,
): QueryState<DiscountedProduct[]> {
  const query = useDiscountedProducts();

  const filtered = useMemo(() => {
    if (!query.data) return null;
    if (!category) return query.data;
    return query.data.filter((p) => p.category === category);
  }, [query.data, category]);

  return { ...query, data: filtered };
}

// ─── Internal: polling helper ────────────────────────────────────────────────

import { useEffect } from 'react';

function usePoll(refetch: () => void, intervalMs?: number): void {
  useEffect(() => {
    if (!intervalMs) return;
    const id = setInterval(refetch, intervalMs);
    return () => clearInterval(id);
  }, [refetch, intervalMs]);
}

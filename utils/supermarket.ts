/**
 * utils/supermarket.ts
 *
 * Pure, framework-free helpers.  All business-rule knowledge lives here so the
 * visual layer stays declarative and easy to read.
 *
 * Every function is imported individually — no side effects.
 */

import type { BatchStatus, ProductCategory, DiscountedProduct, ActiveBatch } from '../types';

// ─── Price & currency ────────────────────────────────────────────────────────

/** Format a number as a locale currency string (MXN by default for León, GTO). */
export function formatPrice(amount: number, currency = 'MXN'): string {
  return new Intl.NumberFormat('es-MX', {
    style: 'currency',
    currency,
    minimumFractionDigits: 2,
  }).format(amount);
}

/** Format a discount percentage, e.g. 23.5 → "24% OFF" */
export function formatDiscountBadge(pct: number): string {
  return `${Math.round(pct)}% OFF`;
}

/**
 * Price-floor guard — returns true when a proposed price is safe to sell at.
 * Mirrors the DB rule: price >= buy_cost × 1.08
 */
export function isAbovePriceFloor(price: number, buyCost: number): boolean {
  return price >= buyCost * 1.08;
}

// ─── Time remaining ──────────────────────────────────────────────────────────

/** Human-readable countdown from now until a given ISO-8601 timestamp. */
export function formatTimeRemaining(isoTimestamp: string): string {
  const msLeft = new Date(isoTimestamp).getTime() - Date.now();
  if (msLeft <= 0) return 'Expired';

  const totalSeconds = Math.floor(msLeft / 1000);
  const days    = Math.floor(totalSeconds / 86_400);
  const hours   = Math.floor((totalSeconds % 86_400) / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);

  if (days > 0)    return `${days}d ${hours}h`;
  if (hours > 0)   return `${hours}h ${minutes}m`;
  return `${minutes}m`;
}

/**
 * How urgent is a batch's expiry?
 * Returns 'critical' | 'warning' | 'ok' for colour-coding in the UI.
 *
 *  critical  → < 4 hours remaining
 *  warning   → < 24 hours remaining
 *  ok        → everything else
 */
export function expiryUrgency(
  isoDiscard: string,
): 'critical' | 'warning' | 'ok' {
  const msLeft = new Date(isoDiscard).getTime() - Date.now();
  if (msLeft <= 0)           return 'critical';
  if (msLeft < 4 * 3_600_000)  return 'critical';
  if (msLeft < 24 * 3_600_000) return 'warning';
  return 'ok';
}

// ─── Status labels & colours ─────────────────────────────────────────────────

const STATUS_LABELS: Record<BatchStatus, string> = {
  fresh:        'Fresh',
  discounting:  'On Discount',
  expired:      'Expired',
};

export function statusLabel(status: BatchStatus): string {
  return STATUS_LABELS[status];
}

/** Suggested semantic colour token per status. Map to your design system. */
export function statusColor(status: BatchStatus): 'success' | 'warning' | 'error' {
  switch (status) {
    case 'fresh':       return 'success';
    case 'discounting': return 'warning';
    case 'expired':     return 'error';
  }
}

// ─── Category helpers ────────────────────────────────────────────────────────

const CATEGORY_EMOJI: Record<ProductCategory, string> = {
  Dairy:   '🥛',
  Bakery:  '🍞',
  Produce: '🥦',
  Meat:    '🥩',
  Canned:  '🥫',
};

export function categoryEmoji(category: ProductCategory): string {
  return CATEGORY_EMOJI[category];
}

// ─── Discount curve maths (client-side preview) ──────────────────────────────
/**
 * Mirrors the server-side formula so the UI can animate prices locally
 * without round-tripping on every frame.
 *
 * discount% = maxDiscount% × progress^1.6
 * where progress = (now - discountStart) / (discardAt - discountStart)  ∈ [0,1]
 *
 * Returns null if outside the discount window.
 */
export function computeClientSideDiscount(
  optimalPrice: number,
  buyCost: number,
  discountStartsAt: string,
  discardAt: string,
  atMs = Date.now(),
): { discountPct: number; salePrice: number } | null {
  const start  = new Date(discountStartsAt).getTime();
  const end    = new Date(discardAt).getTime();

  if (atMs < start || atMs > end) return null;

  const progress    = (atMs - start) / (end - start);
  const priceFloor  = buyCost * 1.08;
  const maxDiscount = ((optimalPrice - priceFloor) / optimalPrice) * 100;
  const discountPct = maxDiscount * Math.pow(progress, 1.6);
  const salePrice   = Math.max(priceFloor, optimalPrice * (1 - discountPct / 100));

  return { discountPct, salePrice };
}

// ─── Sorting helpers ─────────────────────────────────────────────────────────

/** Sort active batches by time remaining (soonest expiry first). */
export function sortByExpirySoonest<T extends { discardAt: string }>(items: T[]): T[] {
  return [...items].sort(
    (a, b) => new Date(a.discardAt).getTime() - new Date(b.discardAt).getTime(),
  );
}

/** Sort discounted products by discount % descending (best deal first). */
export function sortByBestDeal(items: DiscountedProduct[]): DiscountedProduct[] {
  return [...items].sort((a, b) => b.currentDiscountPct - a.currentDiscountPct);
}

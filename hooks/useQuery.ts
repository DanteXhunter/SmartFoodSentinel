/**
 * hooks/useQuery.ts
 *
 * Minimal async data-fetching hook.
 * Keeps the visual layer free of fetch boilerplate.
 *
 * Usage:
 *   const { data, loading, error, refetch } = useQuery(fetchDiscountedProducts);
 *
 * The `deps` array works like useEffect's dependency array — refetches whenever
 * any dep changes.  Pass [] for a one-time fetch on mount.
 */

import { useState, useEffect, useCallback, useRef, DependencyList } from 'react';
import { ApiError } from '../api/client';

export interface QueryState<T> {
  data: T | null;
  loading: boolean;
  /** Human-readable error message, null when healthy */
  error: string | null;
  /** Call to manually re-run the query */
  refetch: () => void;
}

export function useQuery<T>(
  fetcher: () => Promise<T>,
  deps: DependencyList = [],
): QueryState<T> {
  const [data, setData]       = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError]     = useState<string | null>(null);

  // Stable ref so the effect closure always has the latest fetcher without
  // needing it in the dep array (avoids infinite loops).
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;

  // Counter trick: incrementing triggers a refetch without changing deps.
  const [tick, setTick] = useState(0);
  const refetch = useCallback(() => setTick((n) => n + 1), []);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);

    fetcherRef.current()
      .then((result) => {
        if (!cancelled) {
          setData(result);
          setLoading(false);
        }
      })
      .catch((err: unknown) => {
        if (!cancelled) {
          setError(err instanceof ApiError ? err.message : String(err));
          setLoading(false);
        }
      });

    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tick, ...deps]);

  return { data, loading, error, refetch };
}

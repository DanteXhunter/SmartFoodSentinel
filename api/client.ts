/**
 * api/client.ts
 *
 * Thin fetch wrapper that:
 *  - Points at the Express server (configured via env var or fallback)
 *  - Unwraps the { data } / { error } envelope
 *  - Throws a typed Error on HTTP or application-level errors
 *
 * The visual layer never calls this directly — it goes through the hooks.
 */

import type { ApiResponse } from '../types';

// In development the Express server runs on the same machine.
// Set EXPO_PUBLIC_API_URL in your .env to override (e.g. for a real device).
const BASE_URL =
  (process.env.EXPO_PUBLIC_API_URL ?? 'http://localhost:3001').replace(/\/$/, '');

export class ApiError extends Error {
  constructor(
    public readonly status: number,
    message: string,
  ) {
    super(message);
    this.name = 'ApiError';
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const url = `${BASE_URL}${path}`;

  let response: Response;
  try {
    response = await fetch(url, {
      headers: { 'Content-Type': 'application/json', ...(init?.headers ?? {}) },
      ...init,
    });
  } catch (networkError) {
    throw new ApiError(0, `Network error: ${(networkError as Error).message}`);
  }

  const json: ApiResponse<T> = await response.json();

  if (!response.ok || json.error) {
    throw new ApiError(response.status, json.error ?? 'Unknown server error');
  }

  return (json as { data: T }).data;
}

export const apiClient = {
  get: <T>(path: string) => request<T>(path),
  post: <T>(path: string, body: unknown) =>
    request<T>(path, { method: 'POST', body: JSON.stringify(body) }),
};

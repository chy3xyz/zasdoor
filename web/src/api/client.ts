import axios, { type InternalAxiosRequestConfig } from 'axios';

import { ApiError } from '#ui/api/envelope';
import { APP_CONFIG } from '#ui/config';

let authToken: string | null = null;

export function setAuthToken(token: string | null) {
  authToken = token;
}

export function getAuthToken() {
  return authToken;
}

type UnauthorizedHandler = () => void;
let unauthorizedHandler: UnauthorizedHandler | null = null;

/**
 * Register a callback fired when an authenticated API call fails with 401
 * (expired/revoked token). The auth provider wires this up to clear the
 * session and redirect to sign-in.
 */
export function setUnauthorizedHandler(fn: UnauthorizedHandler | null) {
  unauthorizedHandler = fn;
}

/** Shared HTTP client for the zasdoor backend. */
export const http = axios.create({
  baseURL: APP_CONFIG.apiBaseUrl || undefined,
  timeout: 30_000,
  headers: {
    Accept: 'application/json',
    'Content-Type': 'application/json',
  },
});

http.interceptors.request.use((config: InternalAxiosRequestConfig) => {
  if (authToken) {
    config.headers.Authorization = `Bearer ${authToken}`;
  }
  return config;
});

http.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error.response?.status as number | undefined;
    const url = String(error.config?.url ?? '');
    // A 401 on login/register is a business failure (bad credentials), not a
    // session expiry — do not force logout for those.
    const isAuthRequest = url.includes('/auth/login') || url.includes('/auth/register');
    if (status === 401 && !isAuthRequest) {
      setAuthToken(null);
      unauthorizedHandler?.();
    }
    // A non-2xx response body can still be an envelope: unwrap it into an
    // ApiError so the UI shows the server's msg instead of axios's generic
    // "Request failed with status code 400".
    const data = error.response?.data;
    if (data && typeof data.code === 'number' && typeof data.msg === 'string' && data.msg) {
      return Promise.reject(new ApiError(data.code, data.msg));
    }
    return Promise.reject(error);
  },
);

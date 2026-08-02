/** App runtime config. */
function env(key: string, fallback = ''): string {
  const value = import.meta.env[key];
  return typeof value === 'string' && value.length > 0 ? value : fallback;
}

export const APP_CONFIG = {
  /** zenaipa backend origin, e.g. http://127.0.0.1:8600 */
  apiBaseUrl: env('PUBLIC_API_BASE_URL', ''),
  /** API path prefix registered by the Zig backend */
  apiPrefix: env('PUBLIC_API_PREFIX', '/api/v1'),
  storage: {
    token: 'zenaipa.token',
    user: 'zenaipa.user',
  },
} as const;

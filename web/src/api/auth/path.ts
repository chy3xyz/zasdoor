import { APP_CONFIG } from '#ui/config';

export const AUTH_PATH = {
  register: `${APP_CONFIG.apiPrefix}/auth/register`,
  login: `${APP_CONFIG.apiPrefix}/auth/login`,
  logout: `${APP_CONFIG.apiPrefix}/auth/logout`,
  forgotPassword: `${APP_CONFIG.apiPrefix}/auth/forgot-password`,
  resetPassword: `${APP_CONFIG.apiPrefix}/auth/reset-password`,
  me: `${APP_CONFIG.apiPrefix}/auth/me`,
} as const;

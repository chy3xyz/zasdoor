import { APP_CONFIG } from '#ui/config';

export const SYSTEM_PATH = {
  dashboard: `${APP_CONFIG.apiPrefix}/system/dashboard`,
  info: `${APP_CONFIG.apiPrefix}/system/info`,
} as const;

import { APP_CONFIG } from '#ui/config';

export const MFA_PATH = {
  totpEnroll: `${APP_CONFIG.apiPrefix}/mfa/totp/enroll`,
  totpVerify: `${APP_CONFIG.apiPrefix}/mfa/totp/verify`,
  verifyFactor: `${APP_CONFIG.apiPrefix}/mfa/verify`,
  recovery: `${APP_CONFIG.apiPrefix}/mfa/recovery`,
  policy: `${APP_CONFIG.apiPrefix}/mfa/policy`,
} as const;

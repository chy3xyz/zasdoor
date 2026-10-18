import { APP_CONFIG } from '#ui/config';

/** WebAuthn / passkey endpoints (base `/api/v1`). */
export const WEBAUTHN_PATH = {
  loginBegin: `${APP_CONFIG.apiPrefix}/mfa/webauthn/login/begin`,
  loginFinish: `${APP_CONFIG.apiPrefix}/mfa/webauthn/login/finish`,
  registerBegin: `${APP_CONFIG.apiPrefix}/mfa/webauthn/register/begin`,
  registerFinish: `${APP_CONFIG.apiPrefix}/mfa/webauthn/register/finish`,
  credentials: `${APP_CONFIG.apiPrefix}/mfa/webauthn/credentials`,
} as const;

/** `/mfa/webauthn/credentials/{id}` */
export const credentialPath = (id: number | string) => `${WEBAUTHN_PATH.credentials}/${id}`;

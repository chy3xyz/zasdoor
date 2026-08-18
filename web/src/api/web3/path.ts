import { APP_CONFIG } from '#ui/config';

export const WEB3_PATH = {
  nonce: `${APP_CONFIG.apiPrefix}/web3/siwe/nonce`,
  verify: `${APP_CONFIG.apiPrefix}/web3/siwe/verify`,
  bind: `${APP_CONFIG.apiPrefix}/web3/wallet/bind`,
} as const;
export interface SiweNonceRequest {
  address: string;
  domain: string;
}

export interface SiweNonceResult {
  nonce: string;
  ttl: number;
}

export interface SiweVerifyRequest {
  message: string;
  /** 130 hex chars: r(64) || s(64) || v(2), no 0x prefix. */
  signature: string;
  domain: string;
}

export interface SiweVerifyResult {
  token: string | null;
  user_id: number;
  needs_bind?: boolean;
}

export interface BindWalletRequest {
  chain: string;
  address: string;
}

export interface BindWalletResult {
  id: number;
  user_id: number;
  chain: string;
  address: string;
}
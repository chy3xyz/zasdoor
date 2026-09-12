export interface TotpEnrollResult {
  secret: string;
}

export interface VerifyCodeRequest {
  code: string;
}

export interface RecoveryCodesResult {
  codes: string[];
}

export interface MfaPolicy {
  require_mfa: boolean;
  allow_recovery_codes: boolean;
  allow_totp: boolean;
}

export interface SetPolicyRequest {
  require_mfa?: boolean;
  allow_recovery_codes?: boolean;
  allow_totp?: boolean;
}

/** Provider config stored as a JSON string inside the IdentityProvider row. */
export interface IdpConfig {
  authorize_url: string;
  token_url?: string;
  userinfo_url?: string;
  client_id: string;
  client_secret?: string;
  redirect_uri: string;
  scope?: string;
}

export interface IdpItem {
  id: number;
  name: string;
  provider_type: string;
  enabled: boolean;
}

export interface CreateIdpRequest {
  name: string;
  provider_type: string;
  /** JSON.stringify(IdpConfig) — the API stores this as the config blob. */
  config: string;
}

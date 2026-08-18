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

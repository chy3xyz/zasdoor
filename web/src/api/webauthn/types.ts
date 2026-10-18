/**
 * WebAuthn / passkey wire types.
 *
 * The `…/begin` endpoints return a raw
 * `PublicKeyCredential{Creation,Request}Options` object (NOT the usual
 * `{ code, msg, data }` envelope). Every binary field in those options is
 * base64url encoded **without padding**, matching the browser's
 * `ArrayBuffer` representation after `utils/webauthn` decodes it.
 */

/** Serialized `PublicKeyCredentialDescriptor` (base64url id). */
export interface PublicKeyCredentialDescriptorJSON {
  type: string;
  id: string;
  transports?: string[];
}

/** Serialized `PublicKeyCredentialCreationOptions` returned by `register/begin`. */
export interface PublicKeyCredentialCreationOptionsJSON {
  rp: { id?: string; name: string };
  user: { id: string; name: string; displayName: string };
  challenge: string;
  pubKeyCredParams: { type: string; alg: number }[];
  timeout?: number;
  attestation?: string;
  excludeCredentials?: PublicKeyCredentialDescriptorJSON[];
  authenticatorSelection?: {
    authenticatorAttachment?: string;
    residentKey?: string;
    requireResidentKey?: boolean;
    userVerification?: string;
  };
}

/** Serialized `PublicKeyCredentialRequestOptions` returned by `login/begin`. */
export interface PublicKeyCredentialRequestOptionsJSON {
  challenge: string;
  rpId?: string;
  timeout?: number;
  allowCredentials?: PublicKeyCredentialDescriptorJSON[];
  userVerification?: string;
}

export interface PasskeyLoginBeginRequest {
  email: string;
}

/** Body of `POST /mfa/webauthn/login/finish` (base64url, no padding). */
export interface PasskeyLoginFinishRequest {
  email: string;
  credential_id: string;
  client_data_json: string;
  authenticator_data: string;
  signature: string;
}

/** Body of `POST /mfa/webauthn/register/finish` (base64url, no padding). */
export interface PasskeyRegistrationFinishRequest {
  credential_id: string;
  client_data_json: string;
  attestation_object: string;
  name?: string;
}

/**
 * User DTO returned by `login/finish`. It is narrower than `AuthUser`
 * (the backend omits `verified`, `created_at` and `updated_at`), so the auth
 * provider re-fetches the full profile from `/auth/me` after signing in.
 */
export interface PasskeyLoginUser {
  id: number;
  name: string;
  email: string;
  admin: boolean;
  tenant_id: number;
}

/** Envelope payload of `POST /mfa/webauthn/login/finish`. */
export interface PasskeyLoginResult {
  token: string;
  user: PasskeyLoginUser;
}

/** A registered passkey as returned by `GET /mfa/webauthn/credentials`. */
export interface PasskeyCredential {
  id: number;
  name: string;
  credential_id: string;
  last_used_at: number;
}

import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { credentialPath, WEBAUTHN_PATH } from './path';
import type {
  PasskeyCredential,
  PasskeyLoginFinishRequest,
  PasskeyLoginResult,
  PasskeyRegistrationFinishRequest,
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialRequestOptionsJSON,
} from './types';

/**
 * The `begin` endpoints deliberately do NOT use the `{ code, msg, data }`
 * envelope: they return the raw `PublicKeyCredential*Options` object. Read
 * `response.data` directly instead of unwrapping it (unwrapping would throw
 * because there is no `code` field).
 */
async function postRaw<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<T>(path, body);
  return data;
}

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

/** Raw assertion options for `navigator.credentials.get` (base64url fields). */
export async function beginPasskeyLogin(email: string): Promise<PublicKeyCredentialRequestOptionsJSON> {
  return postRaw<PublicKeyCredentialRequestOptionsJSON>(WEBAUTHN_PATH.loginBegin, { email });
}

/** Verify the assertion server-side; resolves with a session JWT. */
export async function finishPasskeyLogin(body: PasskeyLoginFinishRequest): Promise<PasskeyLoginResult> {
  return postEnvelope<PasskeyLoginResult>(WEBAUTHN_PATH.loginFinish, body);
}

/** Raw creation options for `navigator.credentials.create` (base64url fields). */
export async function beginPasskeyRegistration(): Promise<PublicKeyCredentialCreationOptionsJSON> {
  return postRaw<PublicKeyCredentialCreationOptionsJSON>(WEBAUTHN_PATH.registerBegin, {});
}

/** Persist a newly created passkey for the signed-in user. */
export async function finishPasskeyRegistration(body: PasskeyRegistrationFinishRequest): Promise<void> {
  await postEnvelope<null>(WEBAUTHN_PATH.registerFinish, body);
}

/** Passkeys registered by the signed-in user. */
export async function listPasskeys(): Promise<PasskeyCredential[]> {
  return getEnvelope<PasskeyCredential[]>(WEBAUTHN_PATH.credentials);
}

/** Remove one of the signed-in user's passkeys by its row id. */
export async function deletePasskey(id: number): Promise<void> {
  const { data } = await http.delete<{ code: number; msg: string; data: null }>(credentialPath(id));
  unwrapEnvelope(data);
}

import { ApiError } from '#ui/api/envelope';
import type {
  PasskeyLoginFinishRequest,
  PasskeyRegistrationFinishRequest,
  PublicKeyCredentialCreationOptionsJSON,
  PublicKeyCredentialDescriptorJSON,
  PublicKeyCredentialRequestOptionsJSON,
} from '#ui/api/webauthn';

/**
 * WebAuthn wire helpers.
 *
 * The backend speaks JSON, the browser speaks `ArrayBuffer`s. Every binary
 * field on the wire is base64url encoded **without padding**
 * (Zig's `std.base64.url_safe_no_pad`), so these helpers are the single place
 * that converts between the two representations.
 */

/** Decode a base64url string (padding optional) into raw bytes. */
export function base64UrlToBytes(value: string): Uint8Array<ArrayBuffer> {
  const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
  const padLength = (4 - (normalized.length % 4)) % 4;
  const binary = atob(normalized + '='.repeat(padLength));
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

/** Encode raw bytes as unpadded base64url (backend/WebAuthn wire format). */
export function bytesToBase64Url(bytes: ArrayBuffer | Uint8Array): string {
  const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  // Chunk to keep String.fromCharCode's argument list small.
  const chunkSize = 0x2000;
  let binary = '';
  for (let i = 0; i < view.length; i += chunkSize) {
    binary += String.fromCharCode(...view.subarray(i, i + chunkSize));
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function decodeDescriptor(descriptor: PublicKeyCredentialDescriptorJSON): PublicKeyCredentialDescriptor {
  return {
    type: descriptor.type as PublicKeyCredentialType,
    id: base64UrlToBytes(descriptor.id),
    transports: descriptor.transports as AuthenticatorTransport[] | undefined,
  };
}

function decodeDescriptors(
  descriptors?: PublicKeyCredentialDescriptorJSON[],
): PublicKeyCredentialDescriptor[] | undefined {
  return descriptors?.map(decodeDescriptor);
}

/** Convert `register/begin` JSON options into browser-ready creation options. */
export function decodeCreationOptions(
  options: PublicKeyCredentialCreationOptionsJSON,
): PublicKeyCredentialCreationOptions {
  return {
    challenge: base64UrlToBytes(options.challenge),
    rp: { id: options.rp.id, name: options.rp.name },
    user: {
      id: base64UrlToBytes(options.user.id),
      name: options.user.name,
      displayName: options.user.displayName,
    },
    pubKeyCredParams: options.pubKeyCredParams.map((param) => ({
      type: param.type as PublicKeyCredentialType,
      alg: param.alg,
    })),
    timeout: options.timeout,
    attestation: options.attestation as AttestationConveyancePreference | undefined,
    excludeCredentials: decodeDescriptors(options.excludeCredentials),
    authenticatorSelection:
      options.authenticatorSelection as unknown as AuthenticatorSelectionCriteria | undefined,
  };
}

/** Convert `login/begin` JSON options into browser-ready request options. */
export function decodeRequestOptions(
  options: PublicKeyCredentialRequestOptionsJSON,
): PublicKeyCredentialRequestOptions {
  return {
    challenge: base64UrlToBytes(options.challenge),
    rpId: options.rpId,
    timeout: options.timeout,
    allowCredentials: decodeDescriptors(options.allowCredentials),
    userVerification: options.userVerification as UserVerificationRequirement | undefined,
  };
}

/**
 * Serialize a freshly created credential for `register/finish`.
 * `credential_id` is the rawId, exactly what the backend stores.
 */
export function serializeRegistrationCredential(
  credential: PublicKeyCredential,
  name: string,
): PasskeyRegistrationFinishRequest {
  const response = credential.response as AuthenticatorAttestationResponse;
  return {
    credential_id: bytesToBase64Url(credential.rawId),
    client_data_json: bytesToBase64Url(response.clientDataJSON),
    attestation_object: bytesToBase64Url(response.attestationObject),
    name,
  };
}

/** Serialize an assertion for `login/finish`. */
export function serializeLoginCredential(
  email: string,
  credential: PublicKeyCredential,
): PasskeyLoginFinishRequest {
  const response = credential.response as AuthenticatorAssertionResponse;
  return {
    email,
    credential_id: bytesToBase64Url(credential.rawId),
    client_data_json: bytesToBase64Url(response.clientDataJSON),
    authenticator_data: bytesToBase64Url(response.authenticatorData),
    signature: bytesToBase64Url(response.signature),
  };
}

/** True when this browser/context can run WebAuthn ceremonies. */
export function isWebAuthnSupported(): boolean {
  return (
    typeof window !== 'undefined' &&
    typeof window.PublicKeyCredential !== 'undefined' &&
    typeof navigator !== 'undefined' &&
    typeof navigator.credentials !== 'undefined' &&
    typeof navigator.credentials.create === 'function' &&
    typeof navigator.credentials.get === 'function'
  );
}

/** Map ceremony/API failures to a short user-facing message. */
export function passkeyErrorMessage(err: unknown): string {
  if (err instanceof ApiError) return err.message;
  if (typeof DOMException !== 'undefined' && err instanceof DOMException) {
    switch (err.name) {
      case 'NotAllowedError':
      case 'AbortError':
        return '操作已取消或验证超时。';
      case 'InvalidStateError':
        return '该通行密钥已注册，请直接使用它登录。';
      case 'SecurityError':
        return '当前页面来源不受信任，通行密钥仅支持 HTTPS 或 localhost。';
      case 'NotSupportedError':
        return '当前设备或浏览器不支持通行密钥。';
      case 'ConstraintError':
        return '该设备无法创建所需的通行密钥。';
      default:
        return `通行密钥操作失败（${err.name}）。`;
    }
  }
  if (err instanceof Error && err.message) return err.message;
  return '通行密钥操作失败，请重试。';
}

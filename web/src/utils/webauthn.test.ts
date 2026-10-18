import { describe, expect, it } from 'vitest';

import { ApiError } from '#ui/api/envelope';

import {
  base64UrlToBytes,
  bytesToBase64Url,
  decodeCreationOptions,
  decodeRequestOptions,
  passkeyErrorMessage,
  serializeLoginCredential,
  serializeRegistrationCredential,
} from './webauthn';

const bytes = (...values: number[]) => new Uint8Array(values);

function toBytes(source: BufferSource): number[] {
  const view =
    source instanceof ArrayBuffer
      ? new Uint8Array(source)
      : new Uint8Array(source.buffer, source.byteOffset, source.byteLength);
  return [...view];
}

function fakeCredential(): PublicKeyCredential {
  return {
    rawId: new Uint8Array([1, 2, 3]).buffer,
    response: {
      clientDataJSON: new Uint8Array([4, 5]).buffer,
      attestationObject: new Uint8Array([6, 7]).buffer,
      authenticatorData: new Uint8Array([8, 9]).buffer,
      signature: new Uint8Array([10, 11]).buffer,
    },
  } as unknown as PublicKeyCredential;
}

describe('base64url helpers', () => {
  it('encodes without padding', () => {
    expect(bytesToBase64Url(bytes(0x66, 0x6f, 0x6f))).toBe('Zm9v');
    expect(bytesToBase64Url(bytes(0x66, 0x6f))).toBe('Zm8');
    expect(bytesToBase64Url(bytes(0x66))).toBe('Zg');
  });

  it('uses the url-safe alphabet', () => {
    expect(bytesToBase64Url(bytes(0xfb, 0xff))).toBe('-_8');
  });

  it('round-trips arbitrary bytes', () => {
    const input = bytes(0, 1, 2, 250, 251, 252, 253, 254, 255);
    expect(toBytes(base64UrlToBytes(bytesToBase64Url(input)))).toEqual([...input]);
  });

  it('accepts padded input', () => {
    expect(toBytes(base64UrlToBytes('Zg=='))).toEqual([0x66]);
    expect(toBytes(base64UrlToBytes('Zm8='))).toEqual([0x66, 0x6f]);
    expect(toBytes(base64UrlToBytes(''))).toEqual([]);
  });
});

describe('option adapters', () => {
  it('turns base64url creation options into ArrayBuffers', () => {
    const options = decodeCreationOptions({
      challenge: 'AAEC',
      rp: { id: 'localhost', name: 'zasdoor' },
      user: { id: 'MQ', name: 'user@example.com', displayName: 'User' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      timeout: 60000,
      attestation: 'none',
      excludeCredentials: [{ type: 'public-key', id: 'AQID' }],
    });

    expect(toBytes(options.challenge)).toEqual([0, 1, 2]);
    expect(options.rp).toEqual({ id: 'localhost', name: 'zasdoor' });
    expect(toBytes(options.user.id)).toEqual([0x31]);
    expect(options.pubKeyCredParams).toEqual([{ type: 'public-key', alg: -7 }]);
    expect(toBytes(options.excludeCredentials![0]!.id)).toEqual([1, 2, 3]);
  });

  it('turns base64url request options into ArrayBuffers', () => {
    const options = decodeRequestOptions({
      challenge: 'AAEC',
      rpId: 'localhost',
      timeout: 60000,
      allowCredentials: [{ type: 'public-key', id: 'AQID' }],
      userVerification: 'preferred',
    });

    expect(toBytes(options.challenge)).toEqual([0, 1, 2]);
    expect(options.rpId).toBe('localhost');
    expect(options.userVerification).toBe('preferred');
    expect(toBytes(options.allowCredentials![0]!.id)).toEqual([1, 2, 3]);
  });

  it('leaves omitted descriptors undefined', () => {
    const options = decodeRequestOptions({ challenge: 'AAEC' });
    expect(options.allowCredentials).toBeUndefined();
    expect(options.timeout).toBeUndefined();
  });
});

describe('credential serializers', () => {
  it('serializes a registration credential', () => {
    const body = serializeRegistrationCredential(fakeCredential(), 'MacBook');
    expect(body).toEqual({
      credential_id: 'AQID',
      client_data_json: 'BAU',
      attestation_object: 'Bgc',
      name: 'MacBook',
    });
  });

  it('serializes an assertion', () => {
    const body = serializeLoginCredential('user@example.com', fakeCredential());
    expect(body).toEqual({
      email: 'user@example.com',
      credential_id: 'AQID',
      client_data_json: 'BAU',
      authenticator_data: 'CAk',
      signature: 'Cgs',
    });
  });
});

describe('passkeyErrorMessage', () => {
  it('passes ApiError messages through', () => {
    expect(passkeyErrorMessage(new ApiError(400, '通行密钥验证失败'))).toBe('通行密钥验证失败');
  });

  it('maps cancelled/unsupported DOM exceptions', () => {
    expect(passkeyErrorMessage(new DOMException('cancel', 'NotAllowedError'))).toBe(
      '操作已取消或验证超时。',
    );
    expect(passkeyErrorMessage(new DOMException('nope', 'SecurityError'))).toContain('HTTPS');
  });

  it('falls back for unknown errors', () => {
    expect(passkeyErrorMessage('boom')).toBe('通行密钥操作失败，请重试。');
  });
});

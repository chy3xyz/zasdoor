import { beforeEach, describe, expect, it, vi } from 'vitest';

const mocks = vi.hoisted(() => ({
  post: vi.fn(),
  get: vi.fn(),
  delete: vi.fn(),
}));

vi.mock('#ui/api/client', () => ({
  http: { post: mocks.post, get: mocks.get, delete: mocks.delete },
}));

import {
  beginPasskeyLogin,
  beginPasskeyRegistration,
  deletePasskey,
  finishPasskeyLogin,
  finishPasskeyRegistration,
  listPasskeys,
} from './query';

const user = {
  id: 1,
  name: 'User',
  email: 'user@example.com',
  admin: false,
  tenant_id: 1,
};

beforeEach(() => {
  vi.clearAllMocks();
});

describe('passkey begin endpoints', () => {
  it('reads raw login options instead of the envelope', async () => {
    const raw = {
      challenge: 'Y2g',
      rpId: 'localhost',
      allowCredentials: [{ type: 'public-key', id: 'aWQ' }],
    };
    mocks.post.mockResolvedValue({ data: raw });

    await expect(beginPasskeyLogin('user@example.com')).resolves.toEqual(raw);
    expect(mocks.post).toHaveBeenCalledWith('/api/v1/mfa/webauthn/login/begin', {
      email: 'user@example.com',
    });
  });

  it('reads raw registration options instead of the envelope', async () => {
    const raw = {
      challenge: 'Y2g',
      rp: { id: 'localhost', name: 'zasdoor' },
      user: { id: 'MQ', name: 'user@example.com', displayName: 'User' },
      pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
      excludeCredentials: [],
    };
    mocks.post.mockResolvedValue({ data: raw });

    await expect(beginPasskeyRegistration()).resolves.toEqual(raw);
    expect(mocks.post).toHaveBeenCalledWith('/api/v1/mfa/webauthn/register/begin', {});
  });
});

describe('passkey finish endpoints', () => {
  it('unwraps the login envelope', async () => {
    mocks.post.mockResolvedValue({
      data: { code: 0, msg: '登录成功', data: { token: 'tok', user } },
    });

    const result = await finishPasskeyLogin({
      email: 'user@example.com',
      credential_id: 'AQID',
      client_data_json: 'BAU',
      authenticator_data: 'CAk',
      signature: 'Cgs',
    });
    expect(result).toEqual({ token: 'tok', user });
  });

  it('unwraps a null registration envelope', async () => {
    mocks.post.mockResolvedValue({ data: { code: 0, msg: '通行密钥已注册', data: null } });

    await expect(
      finishPasskeyRegistration({
        credential_id: 'AQID',
        client_data_json: 'BAU',
        attestation_object: 'Bgc',
      }),
    ).resolves.toBeUndefined();
  });

  it('throws ApiError for a non-zero envelope', async () => {
    mocks.post.mockResolvedValue({
      data: { code: 401, msg: '通行密钥验证失败', data: null },
    });

    await expect(
      finishPasskeyLogin({
        email: 'user@example.com',
        credential_id: 'AQID',
        client_data_json: 'BAU',
        authenticator_data: 'CAk',
        signature: 'Cgs',
      }),
    ).rejects.toThrow('通行密钥验证失败');
  });
});

describe('passkey credential management', () => {
  it('lists credentials from the envelope', async () => {
    const credentials = [
      { id: 3, name: 'MacBook', credential_id: 'AQID', last_used_at: 1700000000 },
    ];
    mocks.get.mockResolvedValue({ data: { code: 0, msg: '', data: credentials } });

    await expect(listPasskeys()).resolves.toEqual(credentials);
    expect(mocks.get).toHaveBeenCalledWith('/api/v1/mfa/webauthn/credentials');
  });

  it('deletes a credential by row id', async () => {
    mocks.delete.mockResolvedValue({ data: { code: 0, msg: '已删除', data: null } });

    await expect(deletePasskey(3)).resolves.toBeUndefined();
    expect(mocks.delete).toHaveBeenCalledWith('/api/v1/mfa/webauthn/credentials/3');
  });
});

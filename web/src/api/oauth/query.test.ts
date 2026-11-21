import { describe, expect, it } from 'vitest';

import { consentPageUrl, type AuthorizeResult } from './query';

describe('consentPageUrl', () => {
  it('returns null unless the authorize result is consent_required', () => {
    const params = { client_id: 'app' };
    expect(consentPageUrl({ kind: 'redirect', url: 'https://client/cb', params })).toBeNull();
    expect(consentPageUrl({ kind: 'error', message: 'oops', params })).toBeNull();
  });

  it('preserves authorize params and fills scopes from the challenge', () => {
    const result: AuthorizeResult = {
      kind: 'consent_required',
      scopes: ['openid', 'email'],
      params: {
        client_id: 'my-app',
        redirect_uri: 'https://client.example/cb',
        state: 'abc',
        scope: 'openid',
      },
    };
    const url = consentPageUrl(result);
    expect(url).toContain('/oauth/consent?');
    const parsed = new URL(url!, 'http://localhost');
    expect(parsed.searchParams.get('client_id')).toBe('my-app');
    expect(parsed.searchParams.get('redirect_uri')).toBe('https://client.example/cb');
    expect(parsed.searchParams.get('state')).toBe('abc');
    expect(parsed.searchParams.get('scope')).toBe('openid');
  });

  it('uses challenge scopes when the original request had no scope param', () => {
    const url = consentPageUrl({
      kind: 'consent_required',
      scopes: ['openid', 'profile'],
      params: { client_id: 'app', redirect_uri: 'https://client/cb' },
    });
    const parsed = new URL(url!, 'http://localhost');
    expect(parsed.searchParams.get('scope')).toBe('openid profile');
  });
});

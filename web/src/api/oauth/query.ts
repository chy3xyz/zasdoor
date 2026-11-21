import type { AxiosResponse } from 'axios';

import { http } from '#ui/api/client';

import { ROUTE_PATH } from '#ui/constants';

import { OAUTH_PATH } from './path';

/** Params of the original /oauth/authorize request, preserved verbatim. */
export type AuthorizeParams = Record<string, string>;

/** HTTP 200 envelope returned when the backend needs explicit user consent. */
export interface ConsentRequiredResult {
  code: 0;
  msg: 'consent_required';
  data: {
    consent_required: true;
    scopes: string[];
  };
}

/** Envelope variant carrying an already-built redirect URL. */
export interface AuthorizeRedirect {
  code: 0;
  msg: string;
  data: {
    redirect_uri?: string;
    redirect_url?: string;
    redirect?: string;
    location?: string;
  };
}

export type AuthorizeResult =
  | { kind: 'consent_required'; scopes: string[]; params: AuthorizeParams }
  | { kind: 'redirect'; url: string; params: AuthorizeParams }
  | { kind: 'error'; message: string; params: AuthorizeParams };

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isConsentRequired(data: unknown): data is ConsentRequiredResult {
  if (!isRecord(data) || data.msg !== 'consent_required' || !isRecord(data.data)) return false;
  return data.data.consent_required === true;
}

function redirectFromData(data: unknown): string | null {
  if (!isRecord(data) || !isRecord(data.data)) return null;
  for (const key of ['redirect_uri', 'redirect_url', 'redirect', 'location']) {
    const value = data.data[key];
    if (typeof value === 'string' && value.length > 0) return value;
  }
  return null;
}

function errorMessage(error: unknown): string {
  if (isRecord(error) && isRecord(error.response) && isRecord(error.response.data)) {
    const body = error.response.data;
    if (typeof body.error_description === 'string' && body.error_description) return body.error_description;
    if (typeof body.msg === 'string' && body.msg) return body.msg;
    if (typeof body.error === 'string' && body.error) return body.error;
  }
  if (error instanceof Error && error.message) return error.message;
  return 'authorize request failed';
}

/**
 * Call GET /oauth/authorize with the original authorize params plus
 * `consent_granted` when approving. The current backend answers either with a
 * consent envelope (HTTP 200) or with a 302 to the client redirect URI; this
 * helper normalizes both into a discriminated result.
 */
export async function requestAuthorization(
  params: AuthorizeParams,
  consentGranted: boolean,
): Promise<AuthorizeResult> {
  const query = new URLSearchParams(params);
  if (consentGranted) query.set('consent_granted', 'true');
  const url = OAUTH_PATH.authorize + '?' + query.toString();

  let response: AxiosResponse<unknown>;
  try {
    response = await http.get<unknown>(url, {
      // The success path is a 302 whose Location is the client callback. Do not
      // let the browser/XHR follow it; the page navigates there explicitly.
      maxRedirects: 0,
      validateStatus: () => true,
    });
  } catch (err) {
    return { kind: 'error', message: errorMessage(err), params };
  }

  const body = response.data;
  if (isConsentRequired(body)) {
    return { kind: 'consent_required', scopes: body.data.scopes ?? [], params };
  }

  // A 302 usually arrives with an empty body and a Location header. Axios may
  // see the final 200 response instead if redirects are followed upstream, in
  // which case response.request?.responseURL / final URL carries the target.
  const location = response.headers?.['location'] ?? response.headers?.['Location'];
  if (typeof location === 'string' && location.length > 0) {
    return { kind: 'redirect', url: location, params };
  }
  const dataRedirect = redirectFromData(body);
  if (dataRedirect) return { kind: 'redirect', url: dataRedirect, params };
  const request = response.request as { responseURL?: string } | undefined;
  if (request?.responseURL) return { kind: 'redirect', url: request.responseURL, params };

  if (response.status >= 200 && response.status < 300) {
    return { kind: 'error', message: 'authorize response did not include a redirect URL', params };
  }
  return {
    kind: 'error',
    message: errorMessage({ response: { data: body } }) || 'HTTP ' + response.status,
    params,
  };
}

/**
 * Build the /oauth/consent URL that the console links to when the authorize
 * handler answers with a consent_required envelope. The original authorize
 * params (including client_id, redirect_uri and state) are preserved verbatim
 * so the consent page can retry the very same request with consent_granted.
 */
export function consentPageUrl(result: AuthorizeResult): string | null {
  if (result.kind !== 'consent_required') return null;
  const query = new URLSearchParams(result.params);
  if (result.scopes.length > 0 && !query.get('scope')) {
    query.set('scope', result.scopes.join(' '));
  }
  return ROUTE_PATH.oauthConsent + '?' + query.toString();
}

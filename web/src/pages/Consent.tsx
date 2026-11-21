import { useLocation } from '@solidjs/router';
import { For, Show, createMemo, createSignal, onMount } from 'solid-js';

import { listApplications, listProjects, requestAuthorization, toApiError } from '#ui/api';
import { ROUTE_PATH } from '#ui/constants';
import { useI18n, type TranslationKey } from '#ui/i18n';

const AUTHORIZE_PARAMS = [
  'client_id',
  'redirect_uri',
  'response_type',
  'scope',
  'state',
  'nonce',
  'code_challenge',
  'code_challenge_method',
] as const;

const SCOPE_DESCRIPTIONS: Record<string, TranslationKey> = {
  openid: 'oauth.consent.scope.openid',
  profile: 'oauth.consent.scope.profile',
  email: 'oauth.consent.scope.email',
  phone: 'oauth.consent.scope.phone',
  address: 'oauth.consent.scope.address',
  offline_access: 'oauth.consent.scope.offline_access',
};

function withQuery(url: string, params: URLSearchParams): string {
  try {
    const resolved = new URL(url, window.location.href);
    params.forEach((value, key) => resolved.searchParams.set(key, value));
    return resolved.toString();
  } catch {
    return url;
  }
}

function Consent() {
  const location = useLocation();
  const { t } = useI18n();

  // SolidJS Router parses `?` into location.query. Read the full browser URL
  // as well so a direct load (without the router having parsed yet) works.
  const incoming = createMemo<URLSearchParams>(() => {
    const query = location.query;
    const params = new URLSearchParams();
    if (query && typeof query === 'object') {
      for (const [key, value] of Object.entries(query)) {
        if (typeof value === 'string') params.set(key, value);
        else if (Array.isArray(value) && value.length > 0) params.set(key, String(value[0]));
      }
    }
    if (params.size === 0 && typeof window !== 'undefined') {
      return new URLSearchParams(window.location.search);
    }
    return params;
  });

  const authorizeParams = createMemo<Record<string, string>>(() => {
    const source = incoming();
    const result: Record<string, string> = {};
    for (const key of AUTHORIZE_PARAMS) {
      const value = source.get(key);
      if (value !== null) result[key] = value;
    }
    return result;
  });

  const clientId = createMemo(() => incoming().get('client_id') ?? '');
  const redirectUri = createMemo(() => incoming().get('redirect_uri') ?? '');
  const scopes = createMemo<string[]>(() => {
    const source = incoming().get('scope');
    return source ? source.split(/\s+/).filter(Boolean) : [];
  });
  const denyParams = createMemo(() => {
    const params = new URLSearchParams();
    const state = incoming().get('state');
    if (state) params.set('state', state);
    params.set('error', 'access_denied');
    params.set('error_description', 'user denied the request');
    return params;
  });

  const [clientName, setClientName] = createSignal('');
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [done, setDone] = createSignal(false);

  onMount(() => {
    // No global application-discovery endpoint exists: applications are listed
    // per project. Resolve the client id by scanning projects best-effort.
    if (!clientId()) return;
    void (async () => {
      try {
        const projects = await listProjects(1, 100);
        for (const project of projects.list) {
          try {
            const apps = await listApplications(project.id);
            const match = apps.find((app) => app.client_id === clientId());
            if (match) {
              setClientName(match.name);
              return;
            }
          } catch {
            // skip projects the current user cannot inspect
          }
        }
      } catch {
        // app name is optional metadata; consent still works without it
      }
    })();
  });

  const goBack = (url: string) => {
    window.location.href = url;
  };

  const onApprove = async () => {
    if (busy()) return;
    setError(null);
    setBusy(true);
    try {
      const result = await requestAuthorization(authorizeParams(), true);
      if (result.kind === 'redirect') {
        setDone(true);
        goBack(result.url);
        return;
      }
      if (result.kind === 'consent_required') {
        setError(t('oauth.consent.error', { message: 'consent_required' }));
        return;
      }
      setError(t('oauth.consent.error', { message: result.message }));
    } catch (err) {
      setError(t('oauth.consent.error', { message: toApiError(err).message }));
    } finally {
      setBusy(false);
    }
  };

  const onDeny = () => {
    const target = redirectUri();
    goBack(target ? withQuery(target, denyParams()) : ROUTE_PATH.index);
  };

  const missingParams = createMemo(() => !clientId() || !redirectUri());
  const scopeLabel = (scope: string) => {
    const key = SCOPE_DESCRIPTIONS[scope];
    return key ? t(key) : t('oauth.consent.scope.unknown', { scope });
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h1 class="card-title text-2xl">{t('oauth.consent.title')}</h1>
        <p class="text-sm text-base-content/60">{t('oauth.consent.subtitle')}</p>

        <Show when={error()}>
          <div role="alert" class="alert alert-error py-2 text-sm">{error()}</div>
        </Show>
        <Show when={done()}>
          <div role="status" class="alert alert-success py-2 text-sm">{t('oauth.consent.done')}</div>
        </Show>
        <Show when={missingParams()}>
          <div role="alert" class="alert alert-warning py-2 text-sm">
            {t('oauth.consent.missingParams')}
          </div>
        </Show>

        <div class="mt-2 space-y-3">
          <div>
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {t('oauth.consent.client')}
            </p>
            <p class="font-semibold">{clientName() || clientId() || '-'}</p>
            <Show when={clientName()}>
              <p class="break-all text-xs text-base-content/50">{clientId()}</p>
            </Show>
          </div>
          <div>
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {t('oauth.consent.redirectTo')}
            </p>
            <p class="break-all text-xs">{redirectUri() || '-'}</p>
          </div>
          <div>
            <p class="text-xs uppercase tracking-wide text-base-content/50">
              {t('oauth.consent.scopes')}
            </p>
            <Show
              when={scopes().length > 0}
              fallback={<p class="text-sm text-base-content/60">{t('oauth.consent.noScopes')}</p>}
            >
              <ul class="mt-1 space-y-1">
                <For each={scopes()}>
                  {(scope) => (
                    <li class="rounded-md bg-base-200 px-3 py-2 text-sm">
                      <span class="font-mono font-medium">{scope}</span>
                      <span class="text-base-content/60"> — {scopeLabel(scope)}</span>
                    </li>
                  )}
                </For>
              </ul>
            </Show>
          </div>
        </div>

        <div class="card-actions mt-4 flex-col gap-2 sm:flex-row">
          <button
            type="button"
            class="btn btn-primary flex-1"
            disabled={busy() || done() || missingParams()}
            onClick={onApprove}
          >
            {busy() ? t('oauth.consent.approving') : t('oauth.consent.approve')}
          </button>
          <button
            type="button"
            class="btn btn-outline flex-1"
            disabled={busy() || done()}
            onClick={onDeny}
          >
            {t('oauth.consent.deny')}
          </button>
        </div>

        <p class="mt-2 text-xs text-base-content/50">{t('oauth.consent.hint')}</p>
      </div>
    </div>
  );
}

export default Consent;

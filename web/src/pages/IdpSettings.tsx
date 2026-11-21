import { For, Show, createSignal, onMount } from 'solid-js';
import { useToast } from '#ui/components';

import { createIdp, listIdps, toApiError } from '#ui/api';
import type { IdpItem } from '#ui/api';
import { useI18n } from '#ui/i18n';

function IdpSettings() {
  const { t } = useI18n();
  const toast = useToast();
  const [idps, setIdps] = createSignal<IdpItem[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [creating, setCreating] = createSignal(false);
  const [showForm, setShowForm] = createSignal(false);

  // Create form
  const [name, setName] = createSignal('');
  const [providerType, setProviderType] = createSignal('oidc');
  const [authorizeUrl, setAuthorizeUrl] = createSignal('');
  const [tokenUrl, setTokenUrl] = createSignal('');
  const [userinfoUrl, setUserinfoUrl] = createSignal('');
  const [clientId, setClientId] = createSignal('');
  const [clientSecret, setClientSecret] = createSignal('');
  const [redirectUri, setRedirectUri] = createSignal('');
  const [scope, setScope] = createSignal('openid profile email');

  const load = async () => {
    setLoading(true);
    try {
      setIdps(await listIdps());
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setLoading(false);
    }
  };

  onMount(() => {
    void load();
  });

  const resetForm = () => {
    setName('');
    setProviderType('oidc');
    setAuthorizeUrl('');
    setTokenUrl('');
    setUserinfoUrl('');
    setClientId('');
    setClientSecret('');
    setRedirectUri('');
    setScope('openid profile email');
  };

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    const config = {
      authorize_url: authorizeUrl().trim(),
      token_url: tokenUrl().trim(),
      userinfo_url: userinfoUrl().trim(),
      client_id: clientId().trim(),
      client_secret: clientSecret().trim(),
      redirect_uri: redirectUri().trim(),
      scope: scope().trim(),
    };
    setCreating(true);
    try {
      await createIdp({
        name: name().trim(),
        provider_type: providerType().trim() || 'oidc',
        config: JSON.stringify(config),
      });
      toast.show(t('idp.created'), 'success');
      resetForm();
      setShowForm(false);
      await load();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-start justify-between">
        <div>
          <h2 class="text-xl font-semibold">{t('idp.title')}</h2>
          <p class="text-sm text-base-content/60">{t('idp.subtitle')}</p>
        </div>
        <button type="button" class="btn btn-primary btn-sm" onClick={() => setShowForm(!showForm())}>
          {showForm() ? t('common.cancel') : t('idp.new')}
        </button>
      </div>

      <Show when={showForm()}>
        <form onSubmit={onCreate} class="card bg-base-100 shadow-sm">
          <div class="card-body gap-3">
            <h3 class="card-title text-base">{t('idp.newTitle')}</h3>
            <div class="grid gap-3 md:grid-cols-2">
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('common.name')}</span>
                <input type="text" class="input input-bordered input-sm" value={name()} onInput={(e) => setName(e.currentTarget.value)} placeholder={t('idp.namePlaceholder')} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('idp.type')}</span>
                <select class="select select-bordered select-sm" value={providerType()} onChange={(e) => setProviderType(e.currentTarget.value)}>
                  <option value="oidc">oidc</option>
                  <option value="oauth2">oauth2</option>
                </select>
              </label>
              <label class="form-control w-full md:col-span-2">
                <span class="label-text mb-1">{t('idp.authorizeUrl')}</span>
                <input type="url" class="input input-bordered input-sm font-mono" value={authorizeUrl()} onInput={(e) => setAuthorizeUrl(e.currentTarget.value)} placeholder="https://idp.example.com/oauth2/authorize" required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('idp.tokenUrl')}</span>
                <input type="url" class="input input-bordered input-sm font-mono" value={tokenUrl()} onInput={(e) => setTokenUrl(e.currentTarget.value)} placeholder="https://idp.example.com/oauth2/token" />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('idp.userinfoUrl')}</span>
                <input type="url" class="input input-bordered input-sm font-mono" value={userinfoUrl()} onInput={(e) => setUserinfoUrl(e.currentTarget.value)} placeholder="https://idp.example.com/oauth2/userinfo" />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">Client ID</span>
                <input type="text" class="input input-bordered input-sm font-mono" value={clientId()} onInput={(e) => setClientId(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">Client Secret</span>
                <input type="password" class="input input-bordered input-sm font-mono" value={clientSecret()} onInput={(e) => setClientSecret(e.currentTarget.value)} />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('idp.redirectUri')}</span>
                <input type="url" class="input input-bordered input-sm font-mono" value={redirectUri()} onInput={(e) => setRedirectUri(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">Scope</span>
                <input type="text" class="input input-bordered input-sm font-mono" value={scope()} onInput={(e) => setScope(e.currentTarget.value)} />
              </label>
            </div>
            <button type="submit" class="btn btn-primary btn-sm self-end" disabled={creating()}>
              {creating() ? t('common.creating') : t('common.create')}
            </button>
          </div>
        </form>
      </Show>

      <div class="space-y-2">
        <For each={idps()}>
          {(idp) => (
            <div class="flex items-center gap-3 rounded-lg border border-base-300 p-3">
              <div class="flex-1">
                <div class="font-medium">{idp.name}</div>
                <div class="text-xs text-base-content/60">id={idp.id} · {t('idp.type')} {idp.provider_type}</div>
              </div>
              <span class={'badge badge-sm ' + (idp.enabled ? 'badge-success' : 'badge-ghost')}>
                {idp.enabled ? t('common.enabled') : t('common.disabled')}
              </span>
            </div>
          )}
        </For>
        <Show when={!loading() && idps().length === 0}>
          <p class="text-sm text-base-content/50">{t('idp.noProviders')}</p>
        </Show>
        <Show when={loading()}>
          <p class="text-sm text-base-content/50">{t('common.loading')}</p>
        </Show>
      </div>
    </div>
  );
}

export default IdpSettings;
import { For, Show, createSignal, onMount } from 'solid-js';
import { useToast } from '#ui/components';
import { useI18n } from '#ui/i18n';

import {
  beginPasskeyRegistration,
  deletePasskey,
  enrollTotp,
  finishPasskeyRegistration,
  generateRecoveryCodes,
  getMfaPolicy,
  listPasskeys,
  setMfaPolicy,
  toApiError,
  verifyTotp,
} from '#ui/api';
import type { MfaPolicy, PasskeyCredential } from '#ui/api';
import {
  decodeCreationOptions,
  formatDateTime,
  isWebAuthnSupported,
  passkeyErrorMessage,
  serializeRegistrationCredential,
} from '#ui/utils';

/** Shorten a base64url credential id for display (ids are long and opaque). */
function credentialIdPreview(id: string): string {
  return id.length > 24 ? `${id.slice(0, 12)}…${id.slice(-8)}` : id;
}

function MfaSettings() {
  const { t } = useI18n();
  const toast = useToast();
  const [secret, setSecret] = createSignal<string | null>(null);
  const [code, setCode] = createSignal('');
  const [recoveryCodes, setRecoveryCodes] = createSignal<string[]>([]);
  const [policy, setPolicy] = createSignal<MfaPolicy | null>(null);
  const [enabled, setEnabled] = createSignal(false);

  // Passkeys (WebAuthn)
  const [passkeys, setPasskeys] = createSignal<PasskeyCredential[]>([]);
  const [passkeysLoading, setPasskeysLoading] = createSignal(false);
  const [passkeyName, setPasskeyName] = createSignal('');
  const [passkeyBusy, setPasskeyBusy] = createSignal(false);
  const [deletingPasskeyId, setDeletingPasskeyId] = createSignal<number | null>(null);

  const loadPolicy = async () => {
    try {
      setPolicy(await getMfaPolicy());
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const loadPasskeys = async () => {
    setPasskeysLoading(true);
    try {
      setPasskeys(await listPasskeys());
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setPasskeysLoading(false);
    }
  };

  onMount(() => {
    void loadPasskeys();
  });

  const onEnroll = async () => {
    try {
      const res = await enrollTotp();
      setSecret(res.secret);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onVerify = async () => {
    try {
      await verifyTotp({ code: code().trim() });
      setEnabled(true);
      setSecret(null);
      toast.show(t('mfa.totpEnabledToast'), 'success');
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRecovery = async () => {
    try {
      const res = await generateRecoveryCodes();
      setRecoveryCodes(res.codes);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onPolicy = async (patch: Partial<MfaPolicy>) => {
    try {
      await setMfaPolicy(patch);
      await loadPolicy();
      toast.show(t('mfa.policyUpdated'), 'success');
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRegisterPasskey = async () => {
    if (!isWebAuthnSupported()) {
      toast.show(t('auth.signIn.passkey.unsupported'), 'error');
      return;
    }
    if (passkeyBusy()) return;
    setPasskeyBusy(true);
    try {
      // 1. Server-issued challenge + user entity (raw options, b64url ids).
      const options = await beginPasskeyRegistration();
      // 2. Browser ceremony: fingerprint / face / device PIN.
      const credential = (await navigator.credentials.create({
        publicKey: decodeCreationOptions(options),
      })) as PublicKeyCredential | null;
      if (!credential) throw new Error(t('auth.signIn.passkey.noCredential'));
      // 3. Persist the attestation; the server derives the credential id.
      await finishPasskeyRegistration(
        serializeRegistrationCredential(credential, passkeyName().trim()),
      );
      toast.show(t('mfa.registered'), 'success');
      setPasskeyName('');
      await loadPasskeys();
    } catch (err) {
      toast.show(passkeyErrorMessage(err), 'error');
    } finally {
      setPasskeyBusy(false);
    }
  };

  const onDeletePasskey = async (credential: PasskeyCredential) => {
    if (!window.confirm(t('mfa.confirmDelete', { name: credential.name || t('mfa.unnamed') }))) {
      return;
    }
    setDeletingPasskeyId(credential.id);
    try {
      await deletePasskey(credential.id);
      toast.show(t('mfa.deleted'), 'success');
      await loadPasskeys();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setDeletingPasskeyId(null);
    }
  };

  return (
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold">{t('mfa.title')}</h2>
        <p class="text-sm text-base-content/60">{t('mfa.subtitle')}</p>
      </div>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">{t('mfa.totp')}</h3>
        <p class="text-sm text-base-content/60">{enabled() ? t('mfa.totpEnabled') : t('mfa.totpDisabled')}</p>
        <div class="flex items-center gap-2">
          <button type="button" class="btn btn-primary btn-sm" onClick={onEnroll} disabled={enabled()}>
            {t('mfa.enrollTotp')}
          </button>
          <Show when={secret()}>
            {(s) => (
              <>
                <span class="font-mono text-xs break-all">{s()}</span>
                <span class="text-xs text-base-content/60">{t('mfa.scanHint')}</span>
              </>
            )}
          </Show>
        </div>
        <Show when={secret()}>
          <div class="flex items-center gap-2">
            <input type="text" class="input input-bordered input-sm" placeholder={t('mfa.codePlaceholder')} value={code()} onInput={(e) => setCode(e.currentTarget.value)} />
            <button type="button" class="btn btn-sm" onClick={onVerify}>{t('mfa.verifyEnable')}</button>
          </div>
        </Show>
      </section>

      <section class="space-y-3 rounded-lg border border-base-300 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 class="font-semibold">{t('mfa.passkey')}</h3>
            <p class="text-sm text-base-content/60">{t('mfa.passkeySubtitle')}</p>
          </div>
          <span class="badge badge-ghost">{t('mfa.passkeyCount', { count: passkeys().length })}</span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            class="input input-bordered input-sm"
            placeholder={t('mfa.passkeyNamePlaceholder')}
            value={passkeyName()}
            onInput={(e) => setPasskeyName(e.currentTarget.value)}
            disabled={passkeyBusy()}
          />
          <button
            type="button"
            class="btn btn-primary btn-sm"
            onClick={onRegisterPasskey}
            disabled={passkeyBusy() || !isWebAuthnSupported()}
          >
            {passkeyBusy() ? t('mfa.registering') : t('mfa.register')}
          </button>
        </div>
        <Show when={!isWebAuthnSupported()}>
          <p class="text-xs text-warning">
            {t('mfa.unsupported')}
          </p>
        </Show>

        <Show when={passkeysLoading()}>
          <p class="text-sm text-base-content/50">{t('mfa.loading')}</p>
        </Show>
        <Show when={!passkeysLoading() && passkeys().length === 0}>
          <p class="text-sm text-base-content/50">{t('mfa.noPasskeys')}</p>
        </Show>
        <For each={passkeys()}>
          {(credential) => (
            <div class="flex items-center gap-3 rounded-lg border border-base-200 p-2">
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium">
                  {credential.name || t('mfa.unnamed')}
                </div>
                <div class="truncate font-mono text-xs text-base-content/50">
                  {credentialIdPreview(credential.credential_id)}
                </div>
                <div class="text-xs text-base-content/40">
                  {t('mfa.lastUsed')}{credential.last_used_at ? formatDateTime(credential.last_used_at) : t('mfa.neverUsed')}
                </div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                disabled={deletingPasskeyId() === credential.id}
                onClick={() => onDeletePasskey(credential)}
              >
                {deletingPasskeyId() === credential.id ? t('common.deleting') : t('common.delete')}
              </button>
            </div>
          )}
        </For>
      </section>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">{t('mfa.recovery')}</h3>
        <button type="button" class="btn btn-ghost btn-sm" onClick={onRecovery}>{t('mfa.generateRecovery')}</button>
        <Show when={recoveryCodes().length > 0}>
          <div class="grid grid-cols-2 gap-1 md:grid-cols-3">
            {recoveryCodes().map((c) => (
              <span class="rounded bg-base-200 px-2 py-1 font-mono text-xs">{c}</span>
            ))}
          </div>
          <p class="text-xs text-base-content/60">{t('mfa.oneTimeHint')}</p>
        </Show>
      </section>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">{t('mfa.policy')}</h3>
        <Show when={policy()}>
          {(p) => (
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                class={'btn btn-sm ' + (p().require_mfa ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ require_mfa: !p().require_mfa })}
              >
                {t('mfa.requireMfa')}: {p().require_mfa ? t('common.on') : t('common.off')}
              </button>
              <button
                type="button"
                class={'btn btn-sm ' + (p().allow_totp ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ allow_totp: !p().allow_totp })}
              >
                {t('mfa.allowTotp')}: {p().allow_totp ? t('common.allowed') : t('common.forbidden')}
              </button>
              <button
                type="button"
                class={'btn btn-sm ' + (p().allow_recovery_codes ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ allow_recovery_codes: !p().allow_recovery_codes })}
              >
                {t('mfa.allowRecovery')}: {p().allow_recovery_codes ? t('common.allowed') : t('common.forbidden')}
              </button>
            </div>
          )}
        </Show>
      </section>
    </div>
  );
}

export default MfaSettings;
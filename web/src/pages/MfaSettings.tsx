import { For, Show, createSignal, onMount } from 'solid-js';
import { useToast } from '#ui/components';

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
      toast.show('TOTP 已启用', 'success');
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
      toast.show('策略已更新', 'success');
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRegisterPasskey = async () => {
    if (!isWebAuthnSupported()) {
      toast.show('当前浏览器或页面环境不支持通行密钥', 'error');
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
      if (!credential) throw new Error('未获取到通行密钥');
      // 3. Persist the attestation; the server derives the credential id.
      await finishPasskeyRegistration(
        serializeRegistrationCredential(credential, passkeyName().trim()),
      );
      toast.show('通行密钥已注册', 'success');
      setPasskeyName('');
      await loadPasskeys();
    } catch (err) {
      toast.show(passkeyErrorMessage(err), 'error');
    } finally {
      setPasskeyBusy(false);
    }
  };

  const onDeletePasskey = async (credential: PasskeyCredential) => {
    if (!window.confirm(`确定删除通行密钥「${credential.name || '未命名'}」吗？删除后将无法再使用它登录。`)) {
      return;
    }
    setDeletingPasskeyId(credential.id);
    try {
      await deletePasskey(credential.id);
      toast.show('通行密钥已删除', 'success');
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
        <h2 class="text-xl font-semibold">账号安全 / MFA</h2>
        <p class="text-sm text-base-content/60">TOTP 双因素、通行密钥、恢复码与租户 MFA 策略</p>
      </div>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">TOTP 双因素</h3>
        <p class="text-sm text-base-content/60">{enabled() ? '已启用' : '未启用'}</p>
        <div class="flex items-center gap-2">
          <button type="button" class="btn btn-primary btn-sm" onClick={onEnroll} disabled={enabled()}>
            注册 TOTP
          </button>
          <Show when={secret()}>
            {(s) => (
              <>
                <span class="font-mono text-xs break-all">{s()}</span>
                <span class="text-xs text-base-content/60">（请扫描到身份验证器）</span>
              </>
            )}
          </Show>
        </div>
        <Show when={secret()}>
          <div class="flex items-center gap-2">
            <input type="text" class="input input-bordered input-sm" placeholder="输入 6 位验证码" value={code()} onInput={(e) => setCode(e.currentTarget.value)} />
            <button type="button" class="btn btn-sm" onClick={onVerify}>验证并启用</button>
          </div>
        </Show>
      </section>

      <section class="space-y-3 rounded-lg border border-base-300 p-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h3 class="font-semibold">通行密钥 / Passkey</h3>
            <p class="text-sm text-base-content/60">使用指纹、面容或设备 PIN 免密码登录</p>
          </div>
          <span class="badge badge-ghost">{passkeys().length} 个已注册</span>
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <input
            type="text"
            class="input input-bordered input-sm"
            placeholder="通行密钥名称（可选，如 MacBook）"
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
            {passkeyBusy() ? '注册中…' : '注册通行密钥'}
          </button>
        </div>
        <Show when={!isWebAuthnSupported()}>
          <p class="text-xs text-warning">
            当前浏览器或页面环境不支持 WebAuthn，无法注册或使用通行密钥。
          </p>
        </Show>

        <Show when={passkeysLoading()}>
          <p class="text-sm text-base-content/50">加载中…</p>
        </Show>
        <Show when={!passkeysLoading() && passkeys().length === 0}>
          <p class="text-sm text-base-content/50">暂无通行密钥</p>
        </Show>
        <For each={passkeys()}>
          {(credential) => (
            <div class="flex items-center gap-3 rounded-lg border border-base-200 p-2">
              <div class="min-w-0 flex-1">
                <div class="truncate text-sm font-medium">
                  {credential.name || '未命名通行密钥'}
                </div>
                <div class="truncate font-mono text-xs text-base-content/50">
                  {credentialIdPreview(credential.credential_id)}
                </div>
                <div class="text-xs text-base-content/40">
                  最近使用：{credential.last_used_at ? formatDateTime(credential.last_used_at) : '从未使用'}
                </div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-xs text-error"
                disabled={deletingPasskeyId() === credential.id}
                onClick={() => onDeletePasskey(credential)}
              >
                {deletingPasskeyId() === credential.id ? '删除中…' : '删除'}
              </button>
            </div>
          )}
        </For>
      </section>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">恢复码</h3>
        <button type="button" class="btn btn-ghost btn-sm" onClick={onRecovery}>生成恢复码</button>
        <Show when={recoveryCodes().length > 0}>
          <div class="grid grid-cols-2 gap-1 md:grid-cols-3">
            {recoveryCodes().map((c) => (
              <span class="rounded bg-base-200 px-2 py-1 font-mono text-xs">{c}</span>
            ))}
          </div>
          <p class="text-xs text-base-content/60">一次性使用，请安全保存</p>
        </Show>
      </section>

      <section class="space-y-2 rounded-lg border border-base-300 p-4">
        <h3 class="font-semibold">MFA 策略（租户级）</h3>
        <Show when={policy()}>
          {(p) => (
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                class={'btn btn-sm ' + (p().require_mfa ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ require_mfa: !p().require_mfa })}
              >
                强制 MFA：{p().require_mfa ? '开' : '关'}
              </button>
              <button
                type="button"
                class={'btn btn-sm ' + (p().allow_totp ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ allow_totp: !p().allow_totp })}
              >
                TOTP：{p().allow_totp ? '允许' : '禁止'}
              </button>
              <button
                type="button"
                class={'btn btn-sm ' + (p().allow_recovery_codes ? 'btn-primary' : 'btn-outline')}
                onClick={() => onPolicy({ allow_recovery_codes: !p().allow_recovery_codes })}
              >
                恢复码：{p().allow_recovery_codes ? '允许' : '禁止'}
              </button>
            </div>
          )}
        </Show>
      </section>
    </div>
  );
}

export default MfaSettings;

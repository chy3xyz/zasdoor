import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import { enrollTotp, generateRecoveryCodes, getMfaPolicy, setMfaPolicy, toApiError, verifyTotp } from '#ui/api';
import type { MfaPolicy } from '#ui/api';

function MfaSettings() {
  const toast = useToast();
  const [secret, setSecret] = createSignal<string | null>(null);
  const [code, setCode] = createSignal('');
  const [recoveryCodes, setRecoveryCodes] = createSignal<string[]>([]);
  const [policy, setPolicy] = createSignal<MfaPolicy | null>(null);
  const [enabled, setEnabled] = createSignal(false);

  const loadPolicy = async () => {
    try {
      setPolicy(await getMfaPolicy());
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

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

  return (
    <div class="space-y-6">
      <div>
        <h2 class="text-xl font-semibold">账号安全 / MFA</h2>
        <p class="text-sm text-base-content/60">TOTP 双因素、恢复码与租户 MFA 策略</p>
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

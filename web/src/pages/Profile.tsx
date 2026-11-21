import { createSignal, Show } from 'solid-js';

import {
  bindWallet,
  changePassword,
  sendVerification,
  toApiError,
  updateProfile,
} from '#ui/api';
import { useAuth } from '#ui/hooks';
import { useI18n } from '#ui/i18n';
import { formatDateTime } from '#ui/utils';

function Profile() {
  const { t } = useI18n();
  const [auth, actions] = useAuth();
  const user = () => auth.user;

  // Profile edit
  const [name, setName] = createSignal(user()?.name ?? '');
  const [email, setEmail] = createSignal(user()?.email ?? '');
  const [profileError, setProfileError] = createSignal<string | null>(null);
  const [profileOk, setProfileOk] = createSignal<string | null>(null);
  const [profileSaving, setProfileSaving] = createSignal(false);

  // Password change
  const [oldPassword, setOldPassword] = createSignal('');
  const [newPassword, setNewPassword] = createSignal('');
  const [confirm, setConfirm] = createSignal('');
  const [pwError, setPwError] = createSignal<string | null>(null);
  const [pwOk, setPwOk] = createSignal<string | null>(null);
  const [pwSaving, setPwSaving] = createSignal(false);

  // Verification
  const [verifySending, setVerifySending] = createSignal(false);
  const [verifyMsg, setVerifyMsg] = createSignal<string | null>(null);

  // Web3 wallet binding
  const [walletAddress, setWalletAddress] = createSignal('');
  const [walletChain, setWalletChain] = createSignal('evm');
  const [walletMsg, setWalletMsg] = createSignal<string | null>(null);
  const [walletErr, setWalletErr] = createSignal<string | null>(null);
  const [walletSaving, setWalletSaving] = createSignal(false);

  const onSaveProfile = async (e: SubmitEvent) => {
    e.preventDefault();
    if (profileSaving()) return;
    setProfileSaving(true);
    setProfileError(null);
    setProfileOk(null);
    try {
      const fresh = await updateProfile({
        name: name().trim(),
        email: email().trim(),
      });
      actions.setCurrentUser(fresh);
      setProfileOk(t('profile.saved'));
    } catch (err) {
      setProfileError(toApiError(err).message);
    } finally {
      setProfileSaving(false);
    }
  };

  const onChangePassword = async (e: SubmitEvent) => {
    e.preventDefault();
    if (pwSaving()) return;
    if (newPassword() !== confirm()) {
      setPwError(t('common.passwordMismatch'));
      return;
    }
    setPwSaving(true);
    setPwError(null);
    setPwOk(null);
    try {
      await changePassword({ old_password: oldPassword(), new_password: newPassword() });
      setOldPassword('');
      setNewPassword('');
      setConfirm('');
      setPwOk(t('profile.passwordUpdated'));
    } catch (err) {
      setPwError(toApiError(err).message);
    } finally {
      setPwSaving(false);
    }
  };

  const onBindWallet = async (e: SubmitEvent) => {
    e.preventDefault();
    if (walletSaving()) return;
    const addr = walletAddress().trim();
    if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) {
      setWalletErr(t('profile.wallet.invalidAddress'));
      return;
    }
    setWalletSaving(true);
    setWalletMsg(null);
    setWalletErr(null);
    try {
      const res = await bindWallet({ chain: walletChain().trim() || 'evm', address: addr });
      setWalletMsg(t('profile.wallet.bound', { address: res.address }));
      setWalletAddress('');
    } catch (err) {
      setWalletErr(toApiError(err).message);
    } finally {
      setWalletSaving(false);
    }
  };

  const onSendVerification = async () => {
    if (verifySending()) return;
    setVerifySending(true);
    setVerifyMsg(null);
    try {
      await sendVerification();
      setVerifyMsg(t('profile.verifySent'));
    } catch (err) {
      setVerifyMsg(toApiError(err).message);
    } finally {
      setVerifySending(false);
    }
  };

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('profile.title')}</h2>
        <p class="text-sm text-base-content/60">{t('profile.subtitle')}</p>
      </div>

      <Show when={!user()?.verified}>
        <div role="alert" class="alert alert-warning py-2 text-sm">
          <span>
            {t('profile.unverified')}{verifyMsg() ?? t('profile.verifyHint')}
          </span>
          <button type="button" class="btn btn-sm btn-warning" disabled={verifySending()} onClick={onSendVerification}>
            {verifySending() ? t('auth.forgot.submitting') : t('profile.sendVerify')}
          </button>
        </div>
      </Show>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="card w-full bg-base-100 shadow-sm">
          <div class="card-body gap-3">
            <h3 class="card-title text-base">{t('profile.accountInfo')}</h3>
            <div class="flex items-center gap-4">
              <div class="avatar placeholder">
                <div class="w-14 rounded-full bg-primary text-neutral-content">
                  <span class="text-xl">{(user()?.name ?? '?').slice(0, 1)}</span>
                </div>
              </div>
              <div>
                <p class="text-lg font-semibold">{user()?.name}</p>
                <p class="text-sm text-base-content/60">{user()?.email}</p>
              </div>
            </div>
            <div class="divider my-1" />
            <dl class="space-y-2 text-sm">
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.userId')}</dt>
                <dd class="font-mono">{user()?.id}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.role')}</dt>
                <dd>
                  <span class={`badge badge-sm ${user()?.admin ? 'badge-primary' : 'badge-ghost'}`}>
                    {user()?.admin ? t('common.admin') : t('common.user')}
                  </span>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.tenantId')}</dt>
                <dd class="font-mono">{user()?.tenant_id}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.verifiedAt')}</dt>
                <dd>
                  <span class={`badge badge-sm ${user()?.verified ? 'badge-success' : 'badge-outline'}`}>
                    {user()?.verified ? t('common.verified') : t('common.unverified')}
                  </span>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.registeredAt')}</dt>
                <dd>{formatDateTime(user()?.created_at ?? 0)}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">{t('profile.updatedAt')}</dt>
                <dd>{formatDateTime(user()?.updated_at ?? 0)}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="space-y-4">
          <form onSubmit={onBindWallet} class="card w-full bg-base-100 shadow-sm">
            <div class="card-body gap-3">
              <h3 class="card-title text-base">{t('profile.wallet.title')}</h3>
              <p class="text-sm text-base-content/60">{t('profile.wallet.subtitle')}</p>
              <Show when={walletErr()}>
                <div role="alert" class="alert alert-error py-2 text-sm">
                  {walletErr()}
                </div>
              </Show>
              <Show when={walletMsg()}>
                <div role="alert" class="alert alert-success py-2 text-sm">
                  {walletMsg()}
                </div>
              </Show>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('profile.wallet.chain')}</span>
                <input type="text" class="input input-bordered input-sm" value={walletChain()} onInput={(e) => setWalletChain(e.currentTarget.value)} placeholder="evm" />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('profile.wallet.address')}</span>
                <input type="text" class="input input-bordered input-sm" value={walletAddress()} onInput={(e) => setWalletAddress(e.currentTarget.value)} placeholder="0x…" />
              </label>
              <button type="submit" class="btn btn-primary btn-sm self-end" disabled={walletSaving()}>
                {walletSaving() ? t('profile.wallet.binding') : t('profile.wallet.bind')}
              </button>
            </div>
          </form>

          <form onSubmit={onSaveProfile} class="card w-full bg-base-100 shadow-sm">
            <div class="card-body gap-3">
              <h3 class="card-title text-base">{t('profile.edit')}</h3>
              <Show when={profileError()}>
                <div role="alert" class="alert alert-error py-2 text-sm">
                  {profileError()}
                </div>
              </Show>
              <Show when={profileOk()}>
                <div role="alert" class="alert alert-success py-2 text-sm">
                  {profileOk()}
                </div>
              </Show>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('auth.signUp.name')}</span>
                <input type="text" class="input input-bordered input-sm" value={name()} onInput={(e) => setName(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('common.email')}</span>
                <input type="email" class="input input-bordered input-sm" value={email()} onInput={(e) => setEmail(e.currentTarget.value)} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm self-end" disabled={profileSaving()}>
                {profileSaving() ? t('common.saving') : t('profile.save')}
              </button>
            </div>
          </form>

          <form onSubmit={onChangePassword} class="card w-full bg-base-100 shadow-sm">
            <div class="card-body gap-3">
              <h3 class="card-title text-base">{t('profile.password')}</h3>
              <Show when={pwError()}>
                <div role="alert" class="alert alert-error py-2 text-sm">
                  {pwError()}
                </div>
              </Show>
              <Show when={pwOk()}>
                <div role="alert" class="alert alert-success py-2 text-sm">
                  {pwOk()}
                </div>
              </Show>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('profile.currentPassword')}</span>
                <input type="password" class="input input-bordered input-sm" value={oldPassword()} onInput={(e) => setOldPassword(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('profile.newPassword')}</span>
                <input type="password" class="input input-bordered input-sm" value={newPassword()} onInput={(e) => setNewPassword(e.currentTarget.value)} minlength={8} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('auth.reset.confirmNewPassword')}</span>
                <input type="password" class="input input-bordered input-sm" value={confirm()} onInput={(e) => setConfirm(e.currentTarget.value)} minlength={8} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm self-end" disabled={pwSaving()}>
                {pwSaving() ? t('auth.reset.submitting') : t('profile.updatePassword')}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}

export default Profile;
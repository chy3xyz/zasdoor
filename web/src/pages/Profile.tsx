import { createSignal, Show } from 'solid-js';

import {
  changePassword,
  sendVerification,
  toApiError,
  updateProfile,
} from '#ui/api';
import { useAuth } from '#ui/hooks';
import { formatDateTime } from '#ui/utils';

function Profile() {
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
      setProfileOk('资料已保存');
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
      setPwError('两次输入的新密码不一致');
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
      setPwOk('密码已更新');
    } catch (err) {
      setPwError(toApiError(err).message);
    } finally {
      setPwSaving(false);
    }
  };

  const onSendVerification = async () => {
    if (verifySending()) return;
    setVerifySending(true);
    setVerifyMsg(null);
    try {
      await sendVerification();
      setVerifyMsg('验证邮件已发送，请查收邮箱。');
    } catch (err) {
      setVerifyMsg(toApiError(err).message);
    } finally {
      setVerifySending(false);
    }
  };

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">个人资料</h2>
        <p class="text-sm text-base-content/60">账号信息、邮箱验证与安全设置</p>
      </div>

      <Show when={!user()?.verified}>
        <div role="alert" class="alert alert-warning py-2 text-sm">
          <span>
            邮箱尚未验证。{verifyMsg() ?? '部分功能可能受限。'}
          </span>
          <button type="button" class="btn btn-sm btn-warning" disabled={verifySending()} onClick={onSendVerification}>
            {verifySending() ? '发送中…' : '发送验证邮件'}
          </button>
        </div>
      </Show>

      <div class="grid gap-4 lg:grid-cols-2">
        <div class="card w-full bg-base-100 shadow-sm">
          <div class="card-body gap-3">
            <h3 class="card-title text-base">账号信息</h3>
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
                <dt class="text-base-content/60">用户 ID</dt>
                <dd class="font-mono">{user()?.id}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">角色</dt>
                <dd>
                  <span class={`badge badge-sm ${user()?.admin ? 'badge-primary' : 'badge-ghost'}`}>
                    {user()?.admin ? '管理员' : '用户'}
                  </span>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">租户 ID</dt>
                <dd class="font-mono">{user()?.tenant_id}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">验证状态</dt>
                <dd>
                  <span class={`badge badge-sm ${user()?.verified ? 'badge-success' : 'badge-outline'}`}>
                    {user()?.verified ? '已验证' : '未验证'}
                  </span>
                </dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">注册时间</dt>
                <dd>{formatDateTime(user()?.created_at ?? 0)}</dd>
              </div>
              <div class="flex justify-between">
                <dt class="text-base-content/60">更新时间</dt>
                <dd>{formatDateTime(user()?.updated_at ?? 0)}</dd>
              </div>
            </dl>
          </div>
        </div>

        <div class="space-y-4">
          <form onSubmit={onSaveProfile} class="card w-full bg-base-100 shadow-sm">
            <div class="card-body gap-3">
              <h3 class="card-title text-base">编辑资料</h3>
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
                <span class="label-text mb-1">姓名</span>
                <input type="text" class="input input-bordered input-sm" value={name()} onInput={(e) => setName(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">邮箱</span>
                <input type="email" class="input input-bordered input-sm" value={email()} onInput={(e) => setEmail(e.currentTarget.value)} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm self-end" disabled={profileSaving()}>
                {profileSaving() ? '保存中…' : '保存资料'}
              </button>
            </div>
          </form>

          <form onSubmit={onChangePassword} class="card w-full bg-base-100 shadow-sm">
            <div class="card-body gap-3">
              <h3 class="card-title text-base">修改密码</h3>
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
                <span class="label-text mb-1">当前密码</span>
                <input type="password" class="input input-bordered input-sm" value={oldPassword()} onInput={(e) => setOldPassword(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">新密码（至少 8 位）</span>
                <input type="password" class="input input-bordered input-sm" value={newPassword()} onInput={(e) => setNewPassword(e.currentTarget.value)} minlength={8} required />
              </label>
              <label class="form-control w-full">
                <span class="label-text mb-1">确认新密码</span>
                <input type="password" class="input input-bordered input-sm" value={confirm()} onInput={(e) => setConfirm(e.currentTarget.value)} minlength={8} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm self-end" disabled={pwSaving()}>
                {pwSaving() ? '提交中…' : '更新密码'}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}

export default Profile;

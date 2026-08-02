import { A, useSearchParams } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { resetPassword } from '#ui/api/auth';
import { ROUTE_PATH } from '#ui/constants';

function ResetPassword() {
  const [searchParams] = useSearchParams();
  const userId = Number(searchParams.user_id);
  const token = String(searchParams.token ?? '');

  const [password, setPassword] = createSignal('');
  const [confirm, setConfirm] = createSignal('');
  const [submitting, setSubmitting] = createSignal(false);
  const [done, setDone] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [localError, setLocalError] = createSignal<string | null>(null);

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    if (password() !== confirm()) {
      setLocalError('两次输入的密码不一致');
      return;
    }
    setLocalError(null);
    setError(null);
    setSubmitting(true);
    try {
      await resetPassword({
        user_id: userId,
        token,
        new_password: password(),
      });
      setDone(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : '重置失败，请稍后重试');
    } finally {
      setSubmitting(false);
    }
  };

  const invalidLink = () => !userId || !token;

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">设置新密码</h2>
        <p class="text-sm text-base-content/60">请输入新的登录密码</p>

        <Show when={invalidLink()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            重置链接无效，请重新申请。
          </div>
        </Show>
        <Show when={error()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {error()}
          </div>
        </Show>
        <Show when={done()}>
          <div role="alert" class="alert alert-success py-2 text-sm">
            密码已重置，请重新登录。
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">新密码</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder="至少 8 位"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              minlength={8}
              required
              disabled={invalidLink()}
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">确认新密码</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder="再次输入新密码"
              value={confirm()}
              onInput={(e) => setConfirm(e.currentTarget.value)}
              minlength={8}
              required
              disabled={invalidLink()}
            />
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={submitting() || done() || invalidLink()}
          >
            {submitting() ? '提交中…' : '确认重置'}
          </button>
        </form>

        <div class="mt-4 text-center text-sm text-base-content/60">
          <A href={ROUTE_PATH.signIn} class="link link-primary">
            返回登录
          </A>
        </div>
      </div>
    </div>
  );
}

export default ResetPassword;

import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { forgotPassword } from '#ui/api/auth';
import { ROUTE_PATH } from '#ui/constants';

function ForgotPassword() {
  const [email, setEmail] = createSignal('');
  const [submitting, setSubmitting] = createSignal(false);
  const [done, setDone] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    setSubmitting(true);
    setError(null);
    try {
      await forgotPassword({ email: email().trim() });
      setDone(true);
    } catch (err) {
      setError(err instanceof Error ? err.message : '请求失败，请稍后重试');
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">重置密码</h2>
        <p class="text-sm text-base-content/60">
          输入注册邮箱，我们将发送重置链接
        </p>

        <Show when={error()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {error()}
          </div>
        </Show>
        <Show when={done()}>
          <div role="alert" class="alert alert-success py-2 text-sm">
            若该邮箱已注册，重置链接已发送，请查收邮件。
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">邮箱</span>
            <input
              type="email"
              class="input input-bordered w-full"
              placeholder="you@example.com"
              value={email()}
              onInput={(e) => setEmail(e.currentTarget.value)}
              required
            />
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={submitting() || done()}
          >
            {submitting() ? '发送中…' : '发送重置链接'}
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

export default ForgotPassword;

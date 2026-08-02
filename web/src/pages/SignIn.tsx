import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';

function SignIn() {
  const [auth, actions] = useAuth();
  const [email, setEmail] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [submitting, setSubmitting] = createSignal(false);

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    setSubmitting(true);
    try {
      await actions.login(email().trim(), password());
    } catch {
      // error is stored in auth.error
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">登录</h2>
        <p class="text-sm text-base-content/60">使用你的邮箱和密码登录管理后台</p>

        <Show when={auth.error}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {auth.error}
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
          <label class="form-control w-full">
            <span class="label-text mb-1">密码</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder="••••••••"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              required
            />
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={submitting()}
          >
            {submitting() ? '登录中…' : '登录'}
          </button>
        </form>

        <div class="mt-4 flex items-center justify-between text-sm">
          <A href={ROUTE_PATH.forgotPassword} class="link link-primary">
            忘记密码？
          </A>
          <span class="text-base-content/60">
            还没有账号？{' '}
            <A href={ROUTE_PATH.signUp} class="link link-primary">
              注册
            </A>
          </span>
        </div>
      </div>
    </div>
  );
}

export default SignIn;

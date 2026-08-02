import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';

function SignUp() {
  const [auth, actions] = useAuth();
  const [name, setName] = createSignal('');
  const [email, setEmail] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [confirm, setConfirm] = createSignal('');
  const [localError, setLocalError] = createSignal<string | null>(null);
  const [submitting, setSubmitting] = createSignal(false);

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    if (password() !== confirm()) {
      setLocalError('两次输入的密码不一致');
      return;
    }
    setLocalError(null);
    setSubmitting(true);
    try {
      await actions.register(name().trim(), email().trim(), password());
    } catch {
      // error is stored in auth.error
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">注册</h2>
        <p class="text-sm text-base-content/60">创建一个新账号</p>

        <Show when={localError()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {localError()}
          </div>
        </Show>
        <Show when={auth.error && !localError()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {auth.error}
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">姓名</span>
            <input
              type="text"
              class="input input-bordered w-full"
              placeholder="你的名字"
              value={name()}
              onInput={(e) => setName(e.currentTarget.value)}
              required
            />
          </label>
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
              placeholder="至少 8 位"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              minlength={8}
              required
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">确认密码</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder="再次输入密码"
              value={confirm()}
              onInput={(e) => setConfirm(e.currentTarget.value)}
              minlength={8}
              required
            />
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={submitting()}
          >
            {submitting() ? '注册中…' : '注册'}
          </button>
        </form>

        <div class="mt-4 text-center text-sm text-base-content/60">
          已有账号？{' '}
          <A href={ROUTE_PATH.signIn} class="link link-primary">
            去登录
          </A>
        </div>
      </div>
    </div>
  );
}

export default SignUp;

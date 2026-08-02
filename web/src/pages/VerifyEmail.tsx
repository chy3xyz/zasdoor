import { A, useSearchParams } from '@solidjs/router';
import { createSignal, onMount, Show } from 'solid-js';

import { verifyEmail } from '#ui/api/auth';
import { ROUTE_PATH } from '#ui/constants';

function VerifyEmail() {
  const [searchParams] = useSearchParams();
  const userId = Number(searchParams.user_id);
  const token = String(searchParams.token ?? '');

  const [status, setStatus] = createSignal<'pending' | 'success' | 'error'>('pending');
  const [error, setError] = createSignal<string | null>(null);

  onMount(async () => {
    if (!userId || !token) {
      setStatus('error');
      setError('验证链接无效，请重新申请。');
      return;
    }
    try {
      await verifyEmail({ user_id: userId, token });
      setStatus('success');
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : '验证失败，请稍后重试');
    }
  });

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">邮箱验证</h2>
        <Show when={status() === 'pending'}>
          <p class="text-sm text-base-content/60">正在验证…</p>
        </Show>
        <Show when={status() === 'success'}>
          <div role="alert" class="alert alert-success py-2 text-sm">
            邮箱验证成功，可以正常使用全部功能了。
          </div>
          <A href={ROUTE_PATH.signIn} class="btn btn-primary">
            去登录
          </A>
        </Show>
        <Show when={status() === 'error'}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {error()}
          </div>
          <A href={ROUTE_PATH.signIn} class="btn btn-primary">
            返回登录
          </A>
        </Show>
      </div>
    </div>
  );
}

export default VerifyEmail;

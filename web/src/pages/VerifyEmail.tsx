import { A, useSearchParams } from '@solidjs/router';
import { createSignal, onMount, Show } from 'solid-js';

import { verifyEmail } from '#ui/api/auth';
import { ROUTE_PATH } from '#ui/constants';
import { useI18n } from '#ui/i18n';

function VerifyEmail() {
  const { t } = useI18n();
  const [searchParams] = useSearchParams();
  const userId = Number(searchParams.user_id);
  const token = String(searchParams.token ?? '');

  const [status, setStatus] = createSignal<'pending' | 'success' | 'error'>('pending');
  const [error, setError] = createSignal<string | null>(null);

  onMount(async () => {
    if (!userId || !token) {
      setStatus('error');
      setError(t('auth.verify.invalidLink'));
      return;
    }
    try {
      await verifyEmail({ user_id: userId, token });
      setStatus('success');
    } catch (err) {
      setStatus('error');
      setError(err instanceof Error ? err.message : t('auth.verify.failed'));
    }
  });

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">{t('auth.verify.title')}</h2>
        <Show when={status() === 'pending'}>
          <p class="text-sm text-base-content/60">{t('auth.verify.pending')}</p>
        </Show>
        <Show when={status() === 'success'}>
          <div role="alert" class="alert alert-success py-2 text-sm">
            {t('auth.verify.success')}
          </div>
          <A href={ROUTE_PATH.signIn} class="btn btn-primary">
            {t('auth.verify.goToSignIn')}
          </A>
        </Show>
        <Show when={status() === 'error'}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {error()}
          </div>
          <A href={ROUTE_PATH.signIn} class="btn btn-primary">
            {t('auth.verify.backToSignIn')}
          </A>
        </Show>
      </div>
    </div>
  );
}

export default VerifyEmail;
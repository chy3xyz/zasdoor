import { A, useSearchParams } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { resetPassword } from '#ui/api/auth';
import { ROUTE_PATH } from '#ui/constants';
import { useI18n } from '#ui/i18n';

function ResetPassword() {
  const { t } = useI18n();
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
      setLocalError(t('common.passwordMismatch'));
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
      setError(err instanceof Error ? err.message : t('auth.reset.failed'));
    } finally {
      setSubmitting(false);
    }
  };

  const invalidLink = () => !userId || !token;

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">{t('auth.reset.title')}</h2>
        <p class="text-sm text-base-content/60">{t('auth.reset.subtitle')}</p>

        <Show when={invalidLink()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {t('auth.reset.invalidLink')}
          </div>
        </Show>
        <Show when={error()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {error()}
          </div>
        </Show>
        <Show when={done()}>
          <div role="alert" class="alert alert-success py-2 text-sm">
            {t('auth.reset.done')}
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">{t('auth.reset.newPassword')}</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder={t('common.passwordMin')}
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              minlength={8}
              required
              disabled={invalidLink()}
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">{t('auth.reset.confirmNewPassword')}</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder={t('auth.reset.confirmPlaceholder')}
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
            {submitting() ? t('auth.reset.submitting') : t('auth.reset.submit')}
          </button>
        </form>

        <div class="mt-4 text-center text-sm text-base-content/60">
          <A href={ROUTE_PATH.signIn} class="link link-primary">
            {t('auth.reset.backToSignIn')}
          </A>
        </div>
      </div>
    </div>
  );
}

export default ResetPassword;
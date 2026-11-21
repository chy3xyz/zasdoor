import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';
import { useI18n } from '#ui/i18n';

function SignUp() {
  const { t } = useI18n();
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
      setLocalError(t('common.passwordMismatch'));
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
        <h2 class="card-title text-2xl">{t('auth.signUp.title')}</h2>
        <p class="text-sm text-base-content/60">{t('auth.signUp.subtitle')}</p>

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
            <span class="label-text mb-1">{t('auth.signUp.name')}</span>
            <input
              type="text"
              class="input input-bordered w-full"
              placeholder={t('auth.signUp.namePlaceholder')}
              value={name()}
              onInput={(e) => setName(e.currentTarget.value)}
              required
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">{t('auth.signIn.email')}</span>
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
            <span class="label-text mb-1">{t('auth.signIn.password')}</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder={t('common.passwordMin')}
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              minlength={8}
              required
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">{t('auth.signUp.confirmPassword')}</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder={t('auth.signUp.confirmPlaceholder')}
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
            {submitting() ? t('auth.signUp.submitting') : t('auth.signUp.submit')}
          </button>
        </form>

        <div class="mt-4 text-center text-sm text-base-content/60">
          {t('auth.signUp.hasAccount')}{' '}
          <A href={ROUTE_PATH.signIn} class="link link-primary">
            {t('auth.signUp.goToSignIn')}
          </A>
        </div>
      </div>
    </div>
  );
}

export default SignUp;
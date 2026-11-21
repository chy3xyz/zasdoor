import { createEffect, createSignal, Show } from 'solid-js';

import { type AuthUser, createUser, updateUser } from '#ui/api';
import { useI18n } from '#ui/i18n';

export type UserFormTarget = 'create' | 'edit';

interface Props {
  open: boolean;
  mode: UserFormTarget;
  user: AuthUser | null;
  onClose: () => void;
  onSaved: () => void;
}

function UserFormModal(props: Props) {
  const { t } = useI18n();
  const [name, setName] = createSignal('');
  const [email, setEmail] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [admin, setAdmin] = createSignal(false);
  const [verified, setVerified] = createSignal(false);
  const [tenantId, setTenantId] = createSignal(1);
  const [submitting, setSubmitting] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  createEffect(() => {
    if (props.open) {
      setError(null);
      setName(props.user?.name ?? '');
      setEmail(props.user?.email ?? '');
      setPassword('');
      setAdmin(props.user?.admin ?? false);
      setVerified(props.user?.verified ?? false);
      setTenantId(props.user?.tenant_id ?? 1);
    }
  });

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    setSubmitting(true);
    setError(null);
    try {
      if (props.mode === 'create') {
        await createUser({
          name: name().trim(),
          email: email().trim(),
          password: password(),
          admin: admin(),
          tenant_id: tenantId(),
        });
      } else if (props.user) {
        await updateUser(props.user.id, {
          name: name().trim(),
          email: email().trim(),
          admin: admin(),
          verified: verified(),
        });
      }
      props.onSaved();
      props.onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : t('common.saveFailed'));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Show when={props.open}>
      <div class="modal modal-open">
        <div class="modal-box">
          <h3 class="text-lg font-bold">
            {props.mode === 'create' ? t('users.form.create') : t('users.form.edit', { id: props.user?.id ?? '' })}
          </h3>

          <Show when={error()}>
            <div role="alert" class="alert alert-error mt-3 py-2 text-sm">
              {error()}
            </div>
          </Show>

          <form onSubmit={onSubmit} class="mt-4 space-y-4">
            <label class="form-control w-full">
              <span class="label-text mb-1">{t('auth.signUp.name')}</span>
              <input
                type="text"
                class="input input-bordered w-full"
                value={name()}
                onInput={(e) => setName(e.currentTarget.value)}
                required
              />
            </label>
            <label class="form-control w-full">
              <span class="label-text mb-1">{t('common.email')}</span>
              <input
                type="email"
                class="input input-bordered w-full"
                value={email()}
                onInput={(e) => setEmail(e.currentTarget.value)}
                required
              />
            </label>
            <Show when={props.mode === 'create'}>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('users.form.initialPassword')}</span>
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
            </Show>
            <Show when={props.mode === 'create'}>
              <label class="form-control w-full">
                <span class="label-text mb-1">{t('users.form.tenantId')}</span>
                <input
                  type="number"
                  class="input input-bordered input-sm"
                  value={tenantId()}
                  onInput={(e) => setTenantId(Number(e.currentTarget.value) || 1)}
                  min={1}
                  required
                />
              </label>
            </Show>
            <div class="flex gap-8">
              <label class="flex cursor-pointer items-center gap-2">
                <input
                  type="checkbox"
                  class="toggle toggle-sm"
                  checked={admin()}
                  onChange={(e) => setAdmin(e.currentTarget.checked)}
                />
                <span class="label-text">{t('common.admin')}</span>
              </label>
              <Show when={props.mode === 'edit'}>
                <label class="flex cursor-pointer items-center gap-2">
                  <input
                    type="checkbox"
                    class="toggle toggle-sm"
                    checked={verified()}
                    onChange={(e) => setVerified(e.currentTarget.checked)}
                  />
                  <span class="label-text">{t('common.verified')}</span>
                </label>
              </Show>
            </div>

            <div class="modal-action">
              <button type="button" class="btn" onClick={props.onClose}>
                {t('common.cancel')}
              </button>
              <button
                type="submit"
                class="btn btn-primary"
                disabled={submitting()}
              >
                {submitting() ? t('common.saving') : t('common.save')}
              </button>
            </div>
          </form>
        </div>
      </div>
    </Show>
  );
}

export default UserFormModal;
import { createSignal, For, Show } from 'solid-js';
import { useToast } from '#ui/components';

import { listMailTemplates, toApiError, upsertMailTemplate, type MailTemplateItem } from '#ui/api';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 50;

const CODE_KEYS: Record<string, 'mail.verifyEmail' | 'mail.resetPassword'> = {
  verify_email: 'mail.verifyEmail',
  reset_password: 'mail.resetPassword',
};

function MailTemplates() {
  const { t } = useI18n();
  const toast = useToast();
  const [editing, setEditing] = createSignal<MailTemplateItem | null>(null);
  const [subject, setSubject] = createSignal('');
  const [body, setBody] = createSignal('');
  const [saving, setSaving] = createSignal(false);
  const [saved, setSaved] = createSignal('');

  const paged = usePaged<MailTemplateItem>((page, pageSize) => listMailTemplates(page, pageSize), PAGE_SIZE);

  const openEdit = (item: MailTemplateItem) => {
    setEditing(item);
    setSubject(item.subject);
    setBody(item.body);
    setSaved('');
  };

  const onSave = async () => {
    const item = editing();
    if (!item) return;
    if (!subject().trim() || !body().trim()) {
      toast.show(t('mail.emptySubject'), 'error');
      return;
    }
    setSaving(true);
    try {
      await upsertMailTemplate(item.code, subject(), body());
      setSaved(t('mail.saved'));
      void paged.reload();
      window.setTimeout(() => setSaved(''), 2000);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('mail.title')}</h2>
        <p class="text-sm text-base-content/60">
          {t('mail.subtitle')}<code class="font-mono text-xs">{'{app_name}'}</code>{' '}
          <code class="font-mono text-xs">{'{link}'}</code> <code class="font-mono text-xs">{'{email}'}</code>
        </p>
      </div>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>{t('mail.template')}</th>
              <th>{t('mail.subject')}</th>
              <th>{t('mail.body')}</th>
              <th>{t('mail.updatedAt')}</th>
              <th class="text-right">{t('common.actions')}</th>
            </tr>
          </thead>
          <tbody>
            <For each={paged.items()}>
              {(item) => (
                <tr>
                  <td>
                    <span class="badge badge-ghost">{CODE_KEYS[item.code] ? t(CODE_KEYS[item.code]) : item.code}</span>
                    <span class="ml-1 font-mono text-xs text-base-content/50">{item.code}</span>
                  </td>
                  <td class="max-w-xs truncate text-sm">{item.subject}</td>
                  <td class="max-w-md truncate text-sm text-base-content/70">{item.body}</td>
                  <td class="text-sm text-base-content/70">{formatDateTime(item.updated_at)}</td>
                  <td class="text-right">
                    <button type="button" class="btn btn-sm btn-outline" onClick={() => openEdit(item)}>
                      {t('mail.editAction')}
                    </button>
                  </td>
                </tr>
              )}
            </For>
            <Show when={paged.items().length === 0 && !paged.loading()}>
              <tr>
                <td colspan={5} class="py-10 text-center text-base-content/50">
                  {t('mail.noTemplates')}
                </td>
              </tr>
            </Show>
          </tbody>
        </table>
      </div>

      <Show when={editing()}>
        {(item) => (
          <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
            <div class="w-full max-w-lg rounded-lg border border-base-300 bg-base-100 p-5 shadow-xl">
              <div class="mb-4 flex items-center justify-between">
                <div>
                  <h3 class="text-lg font-semibold">{t('mail.edit')}</h3>
                  <p class="font-mono text-xs text-base-content/50">{item().code}</p>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  onClick={() => setEditing(null)}
                  aria-label={t('mail.close')}
                >
                  ✕
                </button>
              </div>

              <label class="block text-sm font-medium text-base-content/70">{t('mail.subject')}</label>
              <input
                type="text"
                class="input input-bordered input-sm mt-1 w-full"
                value={subject()}
                onInput={(e) => setSubject(e.currentTarget.value)}
              />

              <label class="mt-4 block text-sm font-medium text-base-content/70">{t('mail.body')}</label>
              <textarea
                class="textarea textarea-bordered textarea-sm mt-1 w-full font-mono text-sm"
                rows={8}
                value={body()}
                onInput={(e) => setBody(e.currentTarget.value)}
              />

              <div class="mt-4 flex items-center justify-end gap-2">
                <Show when={saved()}>
                  <span class="text-sm text-success">{saved()}</span>
                </Show>
                <button type="button" class="btn btn-ghost btn-sm" onClick={() => setEditing(null)}>
                  {t('common.cancel')}
                </button>
                <button type="button" class="btn btn-primary btn-sm" disabled={saving()} onClick={() => void onSave()}>
                  {saving() ? t('common.saving') : t('common.save')}
                </button>
              </div>
            </div>
          </div>
        )}
      </Show>
    </div>
  );
}

export default MailTemplates;
import { createSignal, For, Show } from 'solid-js';

import { listMailTemplates, toApiError, upsertMailTemplate, type MailTemplateItem } from '#ui/api';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 50;

const CODE_LABELS: Record<string, string> = {
  verify_email: '邮箱验证',
  reset_password: '密码重置',
};

function MailTemplates() {
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
      window.alert('主题和正文不能为空');
      return;
    }
    setSaving(true);
    try {
      await upsertMailTemplate(item.code, subject(), body());
      setSaved('已保存');
      void paged.reload();
      window.setTimeout(() => setSaved(''), 2000);
    } catch (err) {
      window.alert(toApiError(err).message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">邮件模板</h2>
        <p class="text-sm text-base-content/60">
          未配置的模板使用内置默认值;支持变量 <code class="font-mono text-xs">{'{app_name}'}</code>{' '}
          <code class="font-mono text-xs">{'{link}'}</code> <code class="font-mono text-xs">{'{email}'}</code>
        </p>
      </div>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>模板</th>
              <th>主题</th>
              <th>正文</th>
              <th>更新时间</th>
              <th class="text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            <For each={paged.items()}>
              {(item) => (
                <tr>
                  <td>
                    <span class="badge badge-ghost">{CODE_LABELS[item.code] ?? item.code}</span>
                    <span class="ml-1 font-mono text-xs text-base-content/50">{item.code}</span>
                  </td>
                  <td class="max-w-xs truncate text-sm">{item.subject}</td>
                  <td class="max-w-md truncate text-sm text-base-content/70">{item.body}</td>
                  <td class="text-sm text-base-content/70">{formatDateTime(item.updated_at)}</td>
                  <td class="text-right">
                    <button type="button" class="btn btn-sm btn-outline" onClick={() => openEdit(item)}>
                      编辑
                    </button>
                  </td>
                </tr>
              )}
            </For>
            <Show when={paged.items().length === 0 && !paged.loading()}>
              <tr>
                <td colspan={5} class="py-10 text-center text-base-content/50">
                  暂无模板
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
                  <h3 class="text-lg font-semibold">编辑模板</h3>
                  <p class="font-mono text-xs text-base-content/50">{item().code}</p>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-sm"
                  onClick={() => setEditing(null)}
                  aria-label="关闭"
                >
                  ✕
                </button>
              </div>

              <label class="block text-sm font-medium text-base-content/70">主题</label>
              <input
                type="text"
                class="input input-bordered input-sm mt-1 w-full"
                value={subject()}
                onInput={(e) => setSubject(e.currentTarget.value)}
              />

              <label class="mt-4 block text-sm font-medium text-base-content/70">正文</label>
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
                  取消
                </button>
                <button type="button" class="btn btn-primary btn-sm" disabled={saving()} onClick={() => void onSave()}>
                  {saving() ? '保存中…' : '保存'}
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

import { For, Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  listSessions,
  revokeAllUserSessions,
  revokeSession,
  toApiError,
  type SessionItem,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { formatDateTime } from '#ui/utils';

function Sessions() {
  const { t } = useI18n();
  const toast = useToast();
  const [userIdInput, setUserIdInput] = createSignal('');
  const [loadedUserId, setLoadedUserId] = createSignal<number | null>(null);
  const [sessions, setSessions] = createSignal<SessionItem[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [busy, setBusy] = createSignal(false);

  const load = async () => {
    const id = Number(userIdInput().trim());
    if (!Number.isInteger(id) || id <= 0) {
      setError(t('sessions.invalidUserId'));
      return;
    }
    setLoading(true);
    setError(null);
    setSuccess(null);
    try {
      setSessions(await listSessions(id));
      setLoadedUserId(id);
    } catch (err) {
      setError(toApiError(err).message);
    } finally {
      setLoading(false);
    }
  };

  const onRevoke = async (session: SessionItem) => {
    if (!window.confirm(t('sessions.confirmRevoke', { id: session.id }))) return;
    setBusy(true);
    try {
      await revokeSession(session.id);
      setSuccess(t('sessions.revoked'));
      if (loadedUserId() !== null) setSessions(await listSessions(loadedUserId()!));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const onRevokeAll = async () => {
    const id = loadedUserId();
    if (id === null) return;
    if (!window.confirm(t('sessions.confirmRevokeAll', { id }))) return;
    setBusy(true);
    try {
      await revokeAllUserSessions(id);
      setSuccess(t('sessions.allRevoked'));
      setSessions(await listSessions(id));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const columns: Column<SessionItem>[] = [
    { key: 'id', title: t('common.id'), render: (s) => <span class="font-mono text-xs">{s.id}</span> },
    { key: 'device', title: t('sessions.col.device'), render: (s) => <span class="font-mono text-xs">{s.device_id || '-'}</span> },
    { key: 'ip', title: t('sessions.col.ip'), render: (s) => <span class="text-sm">{s.ip || '-'}</span> },
    { key: 'user_agent', title: t('sessions.col.userAgent'), render: (s) => <span class="text-xs text-base-content/60">{s.user_agent || '-'}</span> },
    { key: 'auth_method', title: t('sessions.col.authMethod'), render: (s) => <span class="text-xs">{s.auth_method || '-'}</span> },
    { key: 'last_seen_at', title: t('sessions.col.lastSeen'), render: (s) => <span class="text-sm text-base-content/70">{formatDateTime(s.last_seen_at)}</span> },
    { key: 'expires_at', title: t('sessions.col.expires'), render: (s) => <span class="text-sm text-base-content/70">{formatDateTime(s.expires_at)}</span> },
    {
      key: 'status',
      title: t('sessions.col.status'),
      render: (s) => (
        <span class={'badge badge-sm ' + (s.revoked_at ? 'badge-ghost' : 'badge-success')}>
          {s.revoked_at ? t('common.disabled') : t('sessions.active')}
        </span>
      ),
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('sessions.title')}</h2>
        <p class="text-sm text-base-content/60">{t('sessions.subtitle')}</p>
      </div>

      <form
        onSubmit={(e) => {
          e.preventDefault();
          void load();
        }}
        class="flex items-end gap-2"
      >
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('common.user')}</span>
          <input
            type="number"
            min="1"
            class="input input-bordered input-sm"
            placeholder={t('sessions.userIdPlaceholder')}
            value={userIdInput()}
            onInput={(e) => setUserIdInput(e.currentTarget.value)}
            required
          />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={loading()}>
          {loading() ? t('common.loading') : t('sessions.load')}
        </button>
        <Show when={loadedUserId() !== null}>
          <button type="button" class="btn btn-error btn-outline btn-sm" disabled={busy()} onClick={() => void onRevokeAll()}>
            {t('sessions.revokeAll')}
          </button>
        </Show>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <Show when={loadedUserId() !== null}>
        <p class="text-sm text-base-content/60">{t('sessions.count', { count: sessions().length })}</p>
        <DataTable
          columns={columns}
          rows={sessions()}
          rowKey={(s) => s.id}
          total={sessions().length}
          page={1}
          totalPages={1}
          loading={loading()}
          error={error()}
          emptyText={t('sessions.empty')}
          onPageChange={() => {}}
          actions={(s) => (
            <button type="button" class="btn btn-ghost btn-xs text-error" disabled={busy() || !!s.revoked_at} onClick={() => void onRevoke(s)}>
              {t('sessions.revoke')}
            </button>
          )}
        />
      </Show>

      <Show when={loadedUserId() === null && error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">{error()}</div>
      </Show>
    </div>
  );
}

export default Sessions;

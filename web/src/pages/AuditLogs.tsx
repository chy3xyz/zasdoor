import { createSignal, Show } from 'solid-js';

import { listAuditLogs, toApiError, type AuditLogItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

const ACTION_KEYS: Record<string, 'audit.action.login' | 'audit.action.loginFail' | 'audit.action.register' | 'audit.action.userCreate' | 'audit.action.userUpdate' | 'audit.action.userDelete' | 'audit.action.taskRetry' | 'audit.action.taskCancel' | 'audit.action.taskPurge' | 'audit.action.taskDelete' | 'audit.action.tenantCreate' | 'audit.action.tenantUpdate' | 'audit.action.fileDelete'> = {
  'auth.login': 'audit.action.login',
  'auth.login.fail': 'audit.action.loginFail',
  'auth.register': 'audit.action.register',
  'user.create': 'audit.action.userCreate',
  'user.update': 'audit.action.userUpdate',
  'user.delete': 'audit.action.userDelete',
  'task.retry': 'audit.action.taskRetry',
  'task.cancel': 'audit.action.taskCancel',
  'task.purge': 'audit.action.taskPurge',
  'task.delete': 'audit.action.taskDelete',
  'tenant.create': 'audit.action.tenantCreate',
  'tenant.update': 'audit.action.tenantUpdate',
  'file.delete': 'audit.action.fileDelete',
};

function AuditLogs() {
  const { t } = useI18n();
  const [actor, setActor] = createSignal('');
  const [action, setAction] = createSignal('');
  const [keyword, setKeyword] = createSignal('');
  const [filters, setFilters] = createSignal<{ actor: number; action: string; keyword: string }>({
    actor: 0,
    action: '',
    keyword: '',
  });

  const paged = usePaged<AuditLogItem>(
    (page, pageSize) =>
      listAuditLogs(page, pageSize, {
        actor: filters().actor || undefined,
        action: filters().action || undefined,
        keyword: filters().keyword || undefined,
      }),
    PAGE_SIZE,
  );

  const onSearch = (e: SubmitEvent) => {
    e.preventDefault();
    const actorId = Number.parseInt(actor().trim(), 10);
    setFilters({ actor: Number.isFinite(actorId) ? actorId : 0, action: action().trim(), keyword: keyword().trim() });
    void paged.reload(1);
  };

  const columns: Column<AuditLogItem>[] = [
    { key: 'id', title: 'ID', render: (r) => <span class="font-mono text-xs">{r.id}</span> },
    {
      key: 'action',
      title: t('common.operation'),
      render: (r) => (
        <span class={`badge badge-sm ${r.success ? 'badge-ghost' : 'badge-error'}`}>{ACTION_KEYS[r.action] ? t(ACTION_KEYS[r.action]) : r.action}</span>
      ),
    },
    {
      key: 'actor',
      title: t('common.operator'),
      render: (r) => (
        <span>
          {r.actor_name || `#${r.actor_user_id}`}
          <span class="ml-1 text-xs text-base-content/40">({r.actor_user_id})</span>
        </span>
      ),
    },
    {
      key: 'target',
      title: t('common.target'),
      render: (r) => (
        <span class="text-sm">
          {r.target_type || '-'}
          <Show when={r.target_id > 0}>
            <span class="font-mono text-xs text-base-content/50"> #{r.target_id}</span>
          </Show>
        </span>
      ),
    },
    { key: 'detail', title: t('common.detail'), render: (r) => <span class="text-sm text-base-content/80">{r.detail}</span> },
    { key: 'ip', title: 'IP', render: (r) => <span class="font-mono text-xs">{r.ip || '-'}</span> },
    {
      key: 'created_at',
      title: t('common.time'),
      render: (r) => <span class="text-sm text-base-content/70">{formatDateTime(r.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('audit.title')}</h2>
        <p class="text-sm text-base-content/60">{t('audit.count', { count: paged.total() })}</p>
      </div>

      <form onSubmit={onSearch} class="flex flex-wrap items-center gap-2">
        <input
          type="number"
          class="input input-bordered input-sm w-28"
          placeholder={t('audit.actorPlaceholder')}
          value={actor()}
          onInput={(e) => setActor(e.currentTarget.value)}
        />
        <input
          type="text"
          class="input input-bordered input-sm w-44"
          placeholder={t('audit.actionPlaceholder')}
          value={action()}
          onInput={(e) => setAction(e.currentTarget.value)}
        />
        <input
          type="search"
          class="input input-bordered input-sm w-full max-w-xs"
          placeholder={t('audit.keywordPlaceholder')}
          value={keyword()}
          onInput={(e) => setKeyword(e.currentTarget.value)}
        />
        <button type="submit" class="btn btn-sm" disabled={paged.loading()}>
          {t('common.search')}
        </button>
      </form>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(r) => String(r.id)}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        onPageChange={(p) => void paged.reload(p)}
        emptyText={t('audit.empty')}
      />
    </div>
  );
}

export default AuditLogs;
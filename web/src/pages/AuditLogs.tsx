import { createSignal, Show } from 'solid-js';

import { listAuditLogs, toApiError, type AuditLogItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

const ACTION_LABELS: Record<string, string> = {
  'auth.login': '登录',
  'auth.login.fail': '登录失败',
  'auth.register': '注册',
  'user.create': '创建用户',
  'user.update': '更新用户',
  'user.delete': '删除用户',
  'task.retry': '重试任务',
  'task.cancel': '取消任务',
  'task.purge': '清理任务',
  'task.delete': '删除任务',
  'tenant.create': '创建租户',
  'tenant.update': '更新租户',
  'file.delete': '删除文件',
};

function actionLabel(action: string): string {
  return ACTION_LABELS[action] ?? action;
}

function AuditLogs() {
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
      title: '操作',
      render: (r) => (
        <span class={`badge badge-sm ${r.success ? 'badge-ghost' : 'badge-error'}`}>{actionLabel(r.action)}</span>
      ),
    },
    {
      key: 'actor',
      title: '操作者',
      render: (r) => (
        <span>
          {r.actor_name || `#${r.actor_user_id}`}
          <span class="ml-1 text-xs text-base-content/40">({r.actor_user_id})</span>
        </span>
      ),
    },
    {
      key: 'target',
      title: '对象',
      render: (r) => (
        <span class="text-sm">
          {r.target_type || '-'}
          <Show when={r.target_id > 0}>
            <span class="font-mono text-xs text-base-content/50"> #{r.target_id}</span>
          </Show>
        </span>
      ),
    },
    { key: 'detail', title: '详情', render: (r) => <span class="text-sm text-base-content/80">{r.detail}</span> },
    { key: 'ip', title: 'IP', render: (r) => <span class="font-mono text-xs">{r.ip || '-'}</span> },
    {
      key: 'created_at',
      title: '时间',
      render: (r) => <span class="text-sm text-base-content/70">{formatDateTime(r.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">审计日志</h2>
        <p class="text-sm text-base-content/60">共 {paged.total()} 条操作记录</p>
      </div>

      <form onSubmit={onSearch} class="flex flex-wrap items-center gap-2">
        <input
          type="number"
          class="input input-bordered input-sm w-28"
          placeholder="操作者 ID"
          value={actor()}
          onInput={(e) => setActor(e.currentTarget.value)}
        />
        <input
          type="text"
          class="input input-bordered input-sm w-44"
          placeholder="操作类型,如 user."
          value={action()}
          onInput={(e) => setAction(e.currentTarget.value)}
        />
        <input
          type="search"
          class="input input-bordered input-sm w-full max-w-xs"
          placeholder="搜索详情"
          value={keyword()}
          onInput={(e) => setKeyword(e.currentTarget.value)}
        />
        <button type="submit" class="btn btn-sm" disabled={paged.loading()}>
          搜索
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
        emptyText="暂无审计记录"
      />
    </div>
  );
}

export default AuditLogs;

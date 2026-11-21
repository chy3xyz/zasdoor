import { For, Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  cancelTask,
  deleteTask,
  listTasks,
  purgeTasks,
  retryTask,
  taskStats,
  toApiError,
  type TaskItem,
  type TaskStats,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

const STATUS_KEYS: Record<string, 'tasks.status.pending' | 'tasks.status.claimed' | 'tasks.status.done' | 'tasks.status.failed' | 'tasks.status.canceled'> = {
  pending: 'tasks.status.pending',
  claimed: 'tasks.status.claimed',
  done: 'tasks.status.done',
  failed: 'tasks.status.failed',
  canceled: 'tasks.status.canceled',
};

const STATUS_CLASS: Record<string, string> = {
  pending: 'badge-ghost',
  claimed: 'badge-info',
  done: 'badge-success',
  failed: 'badge-error',
  canceled: 'badge-outline',
};

function Tasks() {
  const { t: tr } = useI18n();
  const toast = useToast();
  const [stats, setStats] = createSignal<TaskStats | null>(null);
  const [status, setStatus] = createSignal('');

  const paged = usePaged<TaskItem>((page, pageSize) => listTasks(page, pageSize, status() || undefined), PAGE_SIZE);

  const loadStats = async () => {
    try {
      setStats(await taskStats());
    } catch {
      // stats are decorative; keep the last known values
    }
  };

  const refresh = () => {
    void loadStats();
    void paged.reload();
  };

  const run = async (fn: () => Promise<unknown>) => {
    try {
      await fn();
      refresh();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<TaskItem>[] = [
    { key: 'id', title: 'ID', render: (t) => <span class="font-mono text-xs">{t.id}</span> },
    {
      key: 'name',
      title: tr('tasks.column.task'),
      render: (t) => (
        <>
          <p class="font-medium">{t.name}</p>
          <p class="max-w-md truncate font-mono text-xs text-base-content/50">{t.payload}</p>
        </>
      ),
    },
    {
      key: 'status',
      title: tr('common.status'),
      render: (t) => (
        <span class={`badge badge-sm ${STATUS_CLASS[t.status] ?? 'badge-ghost'}`}>
          {STATUS_KEYS[t.status] ? tr(STATUS_KEYS[t.status]) : t.status}
        </span>
      ),
    },
    {
      key: 'attempts',
      title: tr('tasks.column.attempts'),
      render: (t) => <span class="text-sm">{t.attempts}/{t.max_attempts}</span>,
    },
    {
      key: 'last_error',
      title: tr('tasks.column.lastError'),
      render: (t) => <span class="max-w-xs truncate text-sm text-error">{t.last_error || '-'}</span>,
    },
    {
      key: 'created_at',
      title: tr('common.createdAt'),
      render: (t) => <span class="text-sm text-base-content/70">{formatDateTime(t.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">{tr('tasks.title')}</h2>
          <p class="text-sm text-base-content/60">{tr('tasks.subtitle')}</p>
        </div>
        <div class="flex gap-2">
          <button type="button" class="btn btn-outline btn-sm" onClick={() => run(purgeTasks)}>
            {tr('tasks.purge')}
          </button>
          <button type="button" class="btn btn-primary btn-sm" onClick={refresh}>
            {tr('common.refresh')}
          </button>
        </div>
      </div>

      <Show when={stats()}>
        <div class="grid grid-cols-5 gap-3">
          <For
            each={[
              [tr('tasks.status.pending'), stats()!.pending, 'badge-ghost'],
              [tr('tasks.status.claimed'), stats()!.claimed, 'badge-info'],
              [tr('tasks.status.done'), stats()!.done, 'badge-success'],
              [tr('tasks.status.failed'), stats()!.failed, 'badge-error'],
              [tr('tasks.status.canceled'), stats()!.canceled, 'badge-outline'],
            ]}
          >
            {([label, count, cls]) => (
              <div class="card bg-base-100 shadow-sm">
                <div class="card-body items-center gap-1 p-4">
                  <span class={`badge badge-sm ${cls}`}>{label}</span>
                  <span class="text-2xl font-semibold">{count}</span>
                </div>
              </div>
            )}
          </For>
        </div>
      </Show>

      <div class="flex items-center gap-2">
        <select
          class="select select-bordered select-sm"
          value={status()}
          onChange={(e) => {
            setStatus(e.currentTarget.value);
            void paged.reload(1);
          }}
        >
          <option value="">{tr('tasks.allStatus')}</option>
          <option value="pending">{tr('tasks.status.pending')}</option>
          <option value="claimed">{tr('tasks.status.claimed')}</option>
          <option value="done">{tr('tasks.status.done')}</option>
          <option value="failed">{tr('tasks.status.failed')}</option>
          <option value="canceled">{tr('tasks.status.canceled')}</option>
        </select>
      </div>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(t) => t.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText={tr('tasks.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(task) => (
          <>
            <Show when={task.status === 'failed'}>
              <button type="button" class="btn btn-ghost btn-xs" onClick={() => run(() => retryTask(task.id))}>
                {tr('tasks.retry')}
              </button>
            </Show>
            <Show when={task.status === 'pending'}>
              <button type="button" class="btn btn-ghost btn-xs" onClick={() => run(() => cancelTask(task.id))}>
                {tr('tasks.cancel')}
              </button>
            </Show>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              onClick={() => {
                if (!window.confirm(tr('tasks.confirmDelete', { id: task.id }))) return;
                void run(() => deleteTask(task.id));
              }}
            >
              {tr('common.delete')}
            </button>
          </>
        )}
      />
    </div>
  );
}

export default Tasks;
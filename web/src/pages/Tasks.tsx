import { For, Show, createSignal } from 'solid-js';

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
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

const STATUS_LABEL: Record<string, string> = {
  pending: '等待中',
  claimed: '执行中',
  done: '已完成',
  failed: '失败',
  canceled: '已取消',
};

const STATUS_CLASS: Record<string, string> = {
  pending: 'badge-ghost',
  claimed: 'badge-info',
  done: 'badge-success',
  failed: 'badge-error',
  canceled: 'badge-outline',
};

function Tasks() {
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
      window.alert(toApiError(err).message);
    }
  };

  const columns: Column<TaskItem>[] = [
    { key: 'id', title: 'ID', render: (t) => <span class="font-mono text-xs">{t.id}</span> },
    {
      key: 'name',
      title: '任务',
      render: (t) => (
        <>
          <p class="font-medium">{t.name}</p>
          <p class="max-w-md truncate font-mono text-xs text-base-content/50">{t.payload}</p>
        </>
      ),
    },
    {
      key: 'status',
      title: '状态',
      render: (t) => (
        <span class={`badge badge-sm ${STATUS_CLASS[t.status] ?? 'badge-ghost'}`}>
          {STATUS_LABEL[t.status] ?? t.status}
        </span>
      ),
    },
    {
      key: 'attempts',
      title: '尝试',
      render: (t) => <span class="text-sm">{t.attempts}/{t.max_attempts}</span>,
    },
    {
      key: 'last_error',
      title: '错误信息',
      render: (t) => <span class="max-w-xs truncate text-sm text-error">{t.last_error || '-'}</span>,
    },
    {
      key: 'created_at',
      title: '创建时间',
      render: (t) => <span class="text-sm text-base-content/70">{formatDateTime(t.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">任务中心</h2>
          <p class="text-sm text-base-content/60">后台任务队列（邮件发送、定时清理等）</p>
        </div>
        <div class="flex gap-2">
          <button type="button" class="btn btn-outline btn-sm" onClick={() => run(purgeTasks)}>
            清理已完成
          </button>
          <button type="button" class="btn btn-primary btn-sm" onClick={refresh}>
            刷新
          </button>
        </div>
      </div>

      <Show when={stats()}>
        <div class="grid grid-cols-5 gap-3">
          <For
            each={[
              ['等待中', stats()!.pending, 'badge-ghost'],
              ['执行中', stats()!.claimed, 'badge-info'],
              ['已完成', stats()!.done, 'badge-success'],
              ['失败', stats()!.failed, 'badge-error'],
              ['已取消', stats()!.canceled, 'badge-outline'],
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
          <option value="">全部状态</option>
          <option value="pending">等待中</option>
          <option value="claimed">执行中</option>
          <option value="done">已完成</option>
          <option value="failed">失败</option>
          <option value="canceled">已取消</option>
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
        emptyText="暂无任务"
        onPageChange={(p) => void paged.reload(p)}
        actions={(task) => (
          <>
            <Show when={task.status === 'failed'}>
              <button type="button" class="btn btn-ghost btn-xs" onClick={() => run(() => retryTask(task.id))}>
                重试
              </button>
            </Show>
            <Show when={task.status === 'pending'}>
              <button type="button" class="btn btn-ghost btn-xs" onClick={() => run(() => cancelTask(task.id))}>
                取消
              </button>
            </Show>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              onClick={() => {
                if (!window.confirm(`确定删除任务 #${task.id} 吗？`)) return;
                void run(() => deleteTask(task.id));
              }}
            >
              删除
            </button>
          </>
        )}
      />
    </div>
  );
}

export default Tasks;

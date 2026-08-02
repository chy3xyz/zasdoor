import { For, Show, createMemo, createSignal, onMount } from 'solid-js';

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
  const [tasks, setTasks] = createSignal<TaskItem[]>([]);
  const [stats, setStats] = createSignal<TaskStats | null>(null);
  const [total, setTotal] = createSignal(0);
  const [page, setPage] = createSignal(1);
  const [status, setStatus] = createSignal('');
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  const totalPages = createMemo(() => Math.max(1, Math.ceil(total() / PAGE_SIZE)));
  let requestSeq = 0;

  const load = async (targetPage = page()) => {
    const seq = ++requestSeq;
    setLoading(true);
    setError(null);
    try {
      const [result, st] = await Promise.all([
        listTasks(targetPage, PAGE_SIZE, status() || undefined),
        taskStats(),
      ]);
      if (seq !== requestSeq) return;
      setTasks(result.list);
      setTotal(result.total);
      setPage(result.page);
      setStats(st);
    } catch (err) {
      if (seq !== requestSeq) return;
      setError(toApiError(err).message);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  };

  onMount(() => void load(1));

  const run = async (fn: () => Promise<unknown>) => {
    try {
      await fn();
      await load();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">任务中心</h2>
          <p class="text-sm text-base-content/60">后台任务队列（邮件发送、定时清理等）</p>
        </div>
        <div class="flex gap-2">
          <button
            type="button"
            class="btn btn-outline btn-sm"
            onClick={() => run(purgeTasks)}
          >
            清理已完成
          </button>
          <button type="button" class="btn btn-primary btn-sm" onClick={() => void load(1)}>
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

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>

      <div class="flex items-center gap-2">
        <select
          class="select select-bordered select-sm"
          value={status()}
          onChange={(e) => {
            setStatus(e.currentTarget.value);
            void load(1);
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

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>ID</th>
              <th>任务</th>
              <th>状态</th>
              <th>尝试</th>
              <th>错误信息</th>
              <th>创建时间</th>
              <th class="text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            <Show when={tasks().length === 0 && !loading()}>
              <tr>
                <td colspan={7} class="py-10 text-center text-base-content/50">
                  暂无任务
                </td>
              </tr>
            </Show>
            <For each={tasks()}>
              {(task) => (
                <tr>
                  <td class="font-mono text-xs">{task.id}</td>
                  <td>
                    <p class="font-medium">{task.name}</p>
                    <p class="max-w-md truncate font-mono text-xs text-base-content/50">
                      {task.payload}
                    </p>
                  </td>
                  <td>
                    <span class={`badge badge-sm ${STATUS_CLASS[task.status] ?? 'badge-ghost'}`}>
                      {STATUS_LABEL[task.status] ?? task.status}
                    </span>
                  </td>
                  <td class="text-sm">{task.attempts}/{task.max_attempts}</td>
                  <td class="max-w-xs truncate text-sm text-error">{task.last_error || '-'}</td>
                  <td class="text-sm text-base-content/70">{formatDateTime(task.created_at)}</td>
                  <td class="text-right">
                    <div class="flex justify-end gap-1">
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
                    </div>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between">
        <span class="text-sm text-base-content/60">
          第 {page()} / {totalPages()} 页
        </span>
        <div class="join">
          <button type="button" class="btn btn-sm join-item" disabled={page() <= 1 || loading()} onClick={() => void load(page() - 1)}>
            上一页
          </button>
          <button type="button" class="btn btn-sm join-item" disabled={page() >= totalPages() || loading()} onClick={() => void load(page() + 1)}>
            下一页
          </button>
        </div>
      </div>
    </div>
  );
}

export default Tasks;

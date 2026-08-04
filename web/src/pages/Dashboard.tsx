import { createSignal, For, onMount, Show } from 'solid-js';

import { getDashboard, toApiError, type DashboardData } from '#ui/api';
import { formatDateTime } from '#ui/utils';

function StatCard(props: { label: string; value: number; hint?: string }) {
  return (
    <div class="rounded-lg border border-base-300 bg-base-200/60 p-4">
      <p class="text-sm text-base-content/60">{props.label}</p>
      <p class="mt-1 text-2xl font-bold">{props.value}</p>
      <Show when={props.hint}>
        <p class="mt-0.5 text-xs text-base-content/40">{props.hint}</p>
      </Show>
    </div>
  );
}

function Dashboard() {
  const [data, setData] = createSignal<DashboardData | null>(null);
  const [error, setError] = createSignal<string | null>(null);
  const [loadedAt, setLoadedAt] = createSignal<number>(0);

  const load = async () => {
    try {
      const d = await getDashboard();
      setData(d);
      setError(null);
      setLoadedAt(Date.now());
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  onMount(() => {
    void load();
  });

  const maxTrend = () => {
    const d = data();
    if (!d) return 1;
    let max = 1;
    for (const v of d.users.registered_last_7d) if (v > max) max = v;
    return max;
  };

  return (
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">概览</h2>
          <p class="text-sm text-base-content/60">平台运行状态一览</p>
        </div>
        <div class="flex items-center gap-2">
          <Show when={loadedAt() > 0}>
            <span class="text-xs text-base-content/40">更新于 {formatDateTime(Math.floor(loadedAt() / 1000))}</span>
          </Show>
          <button type="button" class="btn btn-sm" onClick={() => void load()}>
            刷新
          </button>
        </div>
      </div>

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>

      <Show when={data()}>
        {(d) => (
          <>
            <div class="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-6">
              <StatCard label="用户" value={d().users.total} />
              <StatCard label="任务" value={d().tasks.pending + d().tasks.claimed + d().tasks.done + d().tasks.failed} />
              <StatCard label="文件" value={d().files} />
              <StatCard label="通知" value={d().notifications} />
              <StatCard label="租户" value={d().tenants} />
              <StatCard label="缓存条目" value={d().cache_entries} />
            </div>

            <div class="grid gap-4 lg:grid-cols-2">
              <div class="rounded-lg border border-base-300 p-4">
                <h3 class="mb-3 text-sm font-semibold text-base-content/70">近 7 天注册</h3>
                <div class="flex h-32 items-end gap-2">
                  <For each={d().users.registered_last_7d}>
                    {(v) => (
                      <div class="flex flex-1 flex-col items-center gap-1">
                        <span class="text-xs text-base-content/60">{v}</span>
                        <div
                          class="w-full rounded-t bg-primary/70"
                          style={{ height: `${Math.max(4, (v / maxTrend()) * 100)}%` }}
                        />
                      </div>
                    )}
                  </For>
                </div>
              </div>

              <div class="rounded-lg border border-base-300 p-4">
                <h3 class="mb-3 text-sm font-semibold text-base-content/70">任务队列</h3>
                <div class="grid grid-cols-2 gap-3 text-sm">
                  <div class="flex items-center justify-between rounded bg-base-200 px-3 py-2">
                    <span class="text-base-content/60">待执行</span>
                    <span class="font-semibold">{d().tasks.pending}</span>
                  </div>
                  <div class="flex items-center justify-between rounded bg-base-200 px-3 py-2">
                    <span class="text-base-content/60">执行中</span>
                    <span class="font-semibold">{d().tasks.claimed}</span>
                  </div>
                  <div class="flex items-center justify-between rounded bg-base-200 px-3 py-2">
                    <span class="text-base-content/60">已完成</span>
                    <span class="font-semibold">{d().tasks.done}</span>
                  </div>
                  <div class="flex items-center justify-between rounded bg-base-200 px-3 py-2">
                    <span class="text-base-content/60">失败</span>
                    <span class="font-semibold text-error">{d().tasks.failed}</span>
                  </div>
                </div>
              </div>
            </div>
          </>
        )}
      </Show>
    </div>
  );
}

export default Dashboard;

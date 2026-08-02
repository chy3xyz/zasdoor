import { For, Show, createMemo, createSignal, onMount } from 'solid-js';

import {
  createTenant,
  listTenants,
  toApiError,
  updateTenant,
  type TenantItem,
} from '#ui/api';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Tenants() {
  const [tenants, setTenants] = createSignal<TenantItem[]>([]);
  const [total, setTotal] = createSignal(0);
  const [page, setPage] = createSignal(1);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [creating, setCreating] = createSignal(false);
  const [nameInput, setNameInput] = createSignal('');

  const totalPages = createMemo(() => Math.max(1, Math.ceil(total() / PAGE_SIZE)));
  let requestSeq = 0;

  const load = async (targetPage = page()) => {
    const seq = ++requestSeq;
    setLoading(true);
    setError(null);
    try {
      const result = await listTenants(targetPage, PAGE_SIZE);
      if (seq !== requestSeq) return;
      setTenants(result.list);
      setTotal(result.total);
      setPage(result.page);
    } catch (err) {
      if (seq !== requestSeq) return;
      setError(toApiError(err).message);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  };

  onMount(() => void load(1));

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setError(null);
    setSuccess(null);
    try {
      await createTenant({ name: nameInput().trim() });
      setNameInput('');
      setSuccess('租户已创建');
      void load(1);
    } catch (err) {
      setError(toApiError(err).message);
    } finally {
      setCreating(false);
    }
  };

  const onToggle = async (tenant: TenantItem) => {
    if (!window.confirm(`确定${tenant.status === 'active' ? '停用' : '启用'}租户「${tenant.name}」吗？`)) return;
    try {
      await updateTenant(tenant.id, {
        status: tenant.status === 'active' ? 'disabled' : 'active',
      });
      setSuccess(`租户「${tenant.name}」已${tenant.status === 'active' ? '停用' : '启用'}`);
      void load();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">租户管理</h2>
          <p class="text-sm text-base-content/60">多租户隔离：每个租户拥有独立的用户与数据</p>
        </div>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-sm">
          <span class="label-text mb-1">新租户名称</span>
          <input
            type="text"
            class="input input-bordered input-sm"
            placeholder="例如：Acme Inc"
            value={nameInput()}
            onInput={(e) => setNameInput(e.currentTarget.value)}
            required
          />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? '创建中…' : '创建租户'}
        </button>
      </form>

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>
      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">
          {success()}
        </div>
      </Show>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>ID</th>
              <th>名称</th>
              <th>状态</th>
              <th>创建时间</th>
              <th class="text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            <Show when={tenants().length === 0 && !loading()}>
              <tr>
                <td colspan={5} class="py-10 text-center text-base-content/50">
                  暂无租户
                </td>
              </tr>
            </Show>
            <For each={tenants()}>
              {(tenant) => (
                <tr>
                  <td class="font-mono text-xs">{tenant.id}</td>
                  <td class="font-medium">{tenant.name}</td>
                  <td>
                    <span class={`badge badge-sm ${tenant.status === 'active' ? 'badge-success' : 'badge-outline'}`}>
                      {tenant.status === 'active' ? '启用' : '停用'}
                    </span>
                  </td>
                  <td class="text-sm text-base-content/70">{formatDateTime(tenant.created_at)}</td>
                  <td class="text-right">
                    <button
                      type="button"
                      class={`btn btn-ghost btn-xs ${tenant.status === 'active' ? 'text-error' : ''}`}
                      onClick={() => onToggle(tenant)}
                    >
                      {tenant.status === 'active' ? '停用' : '启用'}
                    </button>
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

export default Tenants;

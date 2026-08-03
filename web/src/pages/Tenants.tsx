import { Show, createSignal } from 'solid-js';

import { createTenant, listTenants, toApiError, updateTenant, type TenantItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Tenants() {
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');

  const paged = usePaged<TenantItem>((page, pageSize) => listTenants(page, pageSize), PAGE_SIZE);

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      await createTenant({ name: nameInput().trim() });
      setNameInput('');
      setSuccess('租户已创建');
      void paged.reload(1);
    } catch (err) {
      window.alert(toApiError(err).message);
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
      void paged.reload();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  const columns: Column<TenantItem>[] = [
    { key: 'id', title: 'ID', render: (t) => <span class="font-mono text-xs">{t.id}</span> },
    { key: 'name', title: '名称', render: (t) => <span class="font-medium">{t.name}</span> },
    {
      key: 'status',
      title: '状态',
      render: (t) => (
        <span class={`badge badge-sm ${t.status === 'active' ? 'badge-success' : 'badge-outline'}`}>
          {t.status === 'active' ? '启用' : '停用'}
        </span>
      ),
    },
    {
      key: 'created_at',
      title: '创建时间',
      render: (t) => <span class="text-sm text-base-content/70">{formatDateTime(t.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">租户管理</h2>
        <p class="text-sm text-base-content/60">多租户隔离：每个租户拥有独立的用户与数据</p>
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

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">
          {success()}
        </div>
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(t) => t.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText="暂无租户"
        onPageChange={(p) => void paged.reload(p)}
        actions={(tenant) => (
          <button
            type="button"
            class={`btn btn-ghost btn-xs ${tenant.status === 'active' ? 'text-error' : ''}`}
            onClick={() => onToggle(tenant)}
          >
            {tenant.status === 'active' ? '停用' : '启用'}
          </button>
        )}
      />
    </div>
  );
}

export default Tenants;

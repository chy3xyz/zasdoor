import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  createOrganization,
  deleteOrganization,
  listOrganizations,
  toApiError,
  type OrganizationItem,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Organizations() {
  const toast = useToast();
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');
  const [domainInput, setDomainInput] = createSignal('');

  const paged = usePaged<OrganizationItem>((page, pageSize) => listOrganizations(page, pageSize), PAGE_SIZE);

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      await createOrganization({ name: nameInput().trim(), domain: domainInput().trim() || undefined });
      setNameInput('');
      setDomainInput('');
      setSuccess('组织已创建');
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onDelete = async (org: OrganizationItem) => {
    if (!window.confirm('确定删除组织「' + org.name + '」吗？')) return;
    try {
      await deleteOrganization(org.id);
      setSuccess('组织「' + org.name + '」已删除');
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<OrganizationItem>[] = [
    { key: 'id', title: 'ID', render: (o) => <span class="font-mono text-xs">{o.id}</span> },
    { key: 'name', title: '名称', render: (o) => <span class="font-medium">{o.name}</span> },
    { key: 'domain', title: '域名', render: (o) => <span class="text-sm text-base-content/70">{o.domain || '-'}</span> },
    {
      key: 'status',
      title: '状态',
      render: (o) => (
        <span class={'badge badge-sm ' + (o.active ? 'badge-success' : 'badge-outline')}>
          {o.active ? '启用' : '停用'}
        </span>
      ),
    },
    {
      key: 'created_at',
      title: '创建时间',
      render: (o) => <span class="text-sm text-base-content/70">{formatDateTime(o.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">组织管理</h2>
        <p class="text-sm text-base-content/60">Instance → Organization → Project 多租户层级</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">组织名称</span>
          <input type="text" class="input input-bordered input-sm" placeholder="例如：Life++" value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">域名（可选）</span>
          <input type="text" class="input input-bordered input-sm" placeholder="life.plus" value={domainInput()} onInput={(e) => setDomainInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? '创建中…' : '创建组织'}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(o) => o.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText="暂无组织"
        onPageChange={(p) => void paged.reload(p)}
        actions={(org) => (
          <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(org)}>
            删除
          </button>
        )}
      />
    </div>
  );
}

export default Organizations;

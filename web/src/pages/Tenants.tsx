import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import { createTenant, listTenants, toApiError, updateTenant, type TenantItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Tenants() {
  const { t: tr } = useI18n();
  const toast = useToast();
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
      setSuccess(tr('tenants.created'));
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onToggle = async (tenant: TenantItem) => {
    const action = tenant.status === 'active' ? tr('common.disable') : tr('common.enable');
    if (!window.confirm(tr('tenants.confirmToggle', { action, name: tenant.name }))) return;
    try {
      await updateTenant(tenant.id, {
        status: tenant.status === 'active' ? 'disabled' : 'active',
      });
      setSuccess(tr('tenants.toggled', { name: tenant.name, action }));
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<TenantItem>[] = [
    { key: 'id', title: 'ID', render: (t) => <span class="font-mono text-xs">{t.id}</span> },
    { key: 'name', title: tr('common.name'), render: (t) => <span class="font-medium">{t.name}</span> },
    {
      key: 'status',
      title: tr('common.status'),
      render: (t) => (
        <span class={`badge badge-sm ${t.status === 'active' ? 'badge-success' : 'badge-outline'}`}>
          {t.status === 'active' ? tr('common.enabled') : tr('common.disabled')}
        </span>
      ),
    },
    {
      key: 'created_at',
      title: tr('common.createdAt'),
      render: (t) => <span class="text-sm text-base-content/70">{formatDateTime(t.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{tr('tenants.title')}</h2>
        <p class="text-sm text-base-content/60">{tr('tenants.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-sm">
          <span class="label-text mb-1">{tr('tenants.newName')}</span>
          <input
            type="text"
            class="input input-bordered input-sm"
            placeholder={tr('tenants.namePlaceholder')}
            value={nameInput()}
            onInput={(e) => setNameInput(e.currentTarget.value)}
            required
          />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? tr('common.creating') : tr('tenants.create')}
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
        emptyText={tr('tenants.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(tenant) => (
          <button
            type="button"
            class={`btn btn-ghost btn-xs ${tenant.status === 'active' ? 'text-error' : ''}`}
            onClick={() => onToggle(tenant)}
          >
            {tenant.status === 'active' ? tr('common.disable') : tr('common.enable')}
          </button>
        )}
      />
    </div>
  );
}

export default Tenants;
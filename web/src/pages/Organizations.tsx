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
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Organizations() {
  const { t } = useI18n();
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
      setSuccess(t('organizations.created'));
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onDelete = async (org: OrganizationItem) => {
    if (!window.confirm(t('organizations.confirmDelete', { name: org.name }))) return;
    try {
      await deleteOrganization(org.id);
      setSuccess(t('organizations.deleted', { name: org.name }));
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<OrganizationItem>[] = [
    { key: 'id', title: 'ID', render: (o) => <span class="font-mono text-xs">{o.id}</span> },
    { key: 'name', title: t('common.name'), render: (o) => <span class="font-medium">{o.name}</span> },
    { key: 'domain', title: t('common.domain'), render: (o) => <span class="text-sm text-base-content/70">{o.domain || '-'}</span> },
    {
      key: 'status',
      title: t('common.status'),
      render: (o) => (
        <span class={'badge badge-sm ' + (o.active ? 'badge-success' : 'badge-outline')}>
          {o.active ? t('common.enabled') : t('common.disabled')}
        </span>
      ),
    },
    {
      key: 'created_at',
      title: t('common.createdAt'),
      render: (o) => <span class="text-sm text-base-content/70">{formatDateTime(o.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('organizations.title')}</h2>
        <p class="text-sm text-base-content/60">{t('organizations.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('organizations.orgName')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('organizations.namePlaceholder')} value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('organizations.domainOptional')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder="life.plus" value={domainInput()} onInput={(e) => setDomainInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? t('common.creating') : t('organizations.create')}
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
        emptyText={t('organizations.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(org) => (
          <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(org)}>
            {t('common.delete')}
          </button>
        )}
      />
    </div>
  );
}

export default Organizations;
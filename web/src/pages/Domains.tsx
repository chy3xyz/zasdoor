import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  createDomain,
  deleteDomain,
  listDomains,
  toApiError,
  verifyDomain,
  type DomainItem,
  type CreateDomainResult,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Domains() {
  const { t } = useI18n();
  const toast = useToast();
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');
  const [orgInput, setOrgInput] = createSignal('');
  const [created, setCreated] = createSignal<CreateDomainResult | null>(null);
  const [verifying, setVerifying] = createSignal<DomainItem | null>(null);
  const [verifyToken, setVerifyToken] = createSignal('');
  const [busy, setBusy] = createSignal(false);

  const paged = usePaged<DomainItem>((page, pageSize) => listDomains(page, pageSize), PAGE_SIZE);

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    setCreated(null);
    try {
      const orgRaw = orgInput().trim();
      const orgId = orgRaw ? Number(orgRaw) : 0;
      const domainName = nameInput().trim();
      const result = await createDomain({
        name: domainName,
        org_id: Number.isInteger(orgId) && orgId > 0 ? orgId : undefined,
      });
      setCreated({ ...result, name: domainName });
      setNameInput('');
      setOrgInput('');
      setSuccess(t('domains.created'));
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const copyToken = async () => {
    const token = created()?.verification_token;
    if (!token) return;
    try {
      await navigator.clipboard.writeText(token);
    } catch {
      // Clipboard may be unavailable (e.g. insecure context); token stays visible.
    }
  };

  const onVerify = async (e: SubmitEvent) => {
    e.preventDefault();
    const domain = verifying();
    if (!domain || busy()) return;
    setBusy(true);
    try {
      await verifyDomain(domain.id, verifyToken().trim());
      setSuccess(t('domains.verified'));
      setVerifying(null);
      setVerifyToken('');
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setBusy(false);
    }
  };

  const onDelete = async (domain: DomainItem) => {
    if (!window.confirm(t('domains.confirmDelete', { name: domain.name }))) return;
    try {
      await deleteDomain(domain.id);
      if (verifying()?.id === domain.id) setVerifying(null);
      setSuccess(t('domains.deleted'));
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<DomainItem>[] = [
    { key: 'id', title: t('common.id'), render: (d) => <span class="font-mono text-xs">{d.id}</span> },
    { key: 'name', title: t('common.domain'), render: (d) => <span class="font-medium">{d.name}</span> },
    { key: 'org_id', title: t('domains.col.orgId'), render: (d) => <span class="text-sm">{d.org_id}</span> },
    {
      key: 'status',
      title: t('common.status'),
      render: (d) => (
        <span class={'badge badge-sm ' + (d.verified ? 'badge-success' : 'badge-warning')}>
          {d.verified ? t('domains.alreadyVerified') : t('common.unverified')}
        </span>
      ),
    },
    { key: 'verified_at', title: t('domains.col.verifiedAt'), render: (d) => <span class="text-sm text-base-content/70">{formatDateTime(d.verified_at)}</span> },
    { key: 'created_at', title: t('common.createdAt'), render: (d) => <span class="text-sm text-base-content/70">{formatDateTime(d.created_at)}</span> },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('domains.title')}</h2>
        <p class="text-sm text-base-content/60">{t('domains.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex flex-wrap items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('common.domain')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('domains.namePlaceholder')} value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-[10rem]">
          <span class="label-text mb-1">{t('domains.orgIdOptional')}</span>
          <input type="number" min="1" class="input input-bordered input-sm" placeholder="1" value={orgInput()} onInput={(e) => setOrgInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? t('common.creating') : t('domains.create')}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <Show when={created()}>
        {(result) => (
          <div role="alert" class="alert alert-info py-2 text-sm">
            <div class="flex w-full items-center justify-between gap-3">
              <div class="min-w-0">
                <p class="font-semibold">{t('domains.tokenOnce')}</p>
                <p class="break-all font-mono text-xs">{result().verification_token}</p>
              </div>
              <div class="flex shrink-0 gap-1">
                <button type="button" class="btn btn-ghost btn-xs" onClick={() => void copyToken()}>{t('domains.copy')}</button>
                <button type="button" class="btn btn-ghost btn-xs" onClick={() => {
                  setCreated(null);
                  setVerifying({
                    id: result().id,
                    org_id: 0,
                    name: result().name ?? '',
                    verified: false,
                    verified_at: 0,
                    created_at: 0,
                  });
                }}>{t('domains.verify')}</button>
              </div>
            </div>
          </div>
        )}
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(d) => d.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText={t('domains.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(domain) => (
          <div class="flex gap-1">
            <Show when={!domain.verified}>
              <button type="button" class="btn btn-ghost btn-xs" onClick={() => {
                setVerifying(domain);
                setVerifyToken('');
              }}>{t('domains.verify')}</button>
            </Show>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => void onDelete(domain)}>{t('common.delete')}</button>
          </div>
        )}
      />

      <Show when={verifying()}>
        {(domain) => (
          <div class="rounded-lg border border-base-300 p-4">
            <h3 class="mb-3 font-semibold">{t('domains.verifyTitle', { name: domain().name })}</h3>
            <form onSubmit={onVerify} class="flex items-end gap-2">
              <label class="form-control w-full max-w-sm">
                <span class="label-text mb-1">{t('domains.tokenOnce')}</span>
                <input type="text" class="input input-bordered input-sm font-mono" placeholder={t('domains.tokenPlaceholder')} value={verifyToken()} onInput={(e) => setVerifyToken(e.currentTarget.value)} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm" disabled={busy()}>{t('domains.verify')}</button>
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setVerifying(null)}>{t('common.cancel')}</button>
            </form>
          </div>
        )}
      </Show>
    </div>
  );
}

export default Domains;

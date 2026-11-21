import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  createApplication,
  createProject,
  createRole,
  deleteProject,
  listApplications,
  listProjects,
  listRoles,
  toApiError,
  type ApplicationItem,
  type ProjectItem,
  type RoleItem,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Projects() {
  const { t } = useI18n();
  const toast = useToast();
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');
  const [orgInput, setOrgInput] = createSignal('');

  const [selected, setSelected] = createSignal<ProjectItem | null>(null);
  const [apps, setApps] = createSignal<ApplicationItem[]>([]);
  const [roles, setRoles] = createSignal<RoleItem[]>([]);
  const [appName, setAppName] = createSignal('');
  const [roleKey, setRoleKey] = createSignal('');
  const [roleName, setRoleName] = createSignal('');
  const [credentials, setCredentials] = createSignal<{ client_id: string; client_secret: string } | null>(null);

  const paged = usePaged<ProjectItem>((page, pageSize) => listProjects(page, pageSize), PAGE_SIZE);

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      const orgId = Number(orgInput().trim());
      await createProject({ name: nameInput().trim(), org_id: Number.isFinite(orgId) && orgId > 0 ? orgId : undefined });
      setNameInput('');
      setOrgInput('');
      setSuccess(t('projects.created'));
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onSelect = async (proj: ProjectItem) => {
    setSelected(proj);
    setCredentials(null);
    try {
      setApps(await listApplications(proj.id));
      setRoles(await listRoles(proj.id));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onCreateApp = async (e: SubmitEvent) => {
    e.preventDefault();
    const proj = selected();
    if (!proj) return;
    try {
      const creds = await createApplication(proj.id, { name: appName().trim() });
      setCredentials(creds);
      setAppName('');
      setApps(await listApplications(proj.id));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onCreateRole = async (e: SubmitEvent) => {
    e.preventDefault();
    const proj = selected();
    if (!proj) return;
    try {
      await createRole(proj.id, { key: roleKey().trim(), name: roleName().trim() });
      setRoleKey('');
      setRoleName('');
      setRoles(await listRoles(proj.id));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onDelete = async (proj: ProjectItem) => {
    if (!window.confirm(t('projects.confirmDelete', { name: proj.name }))) return;
    try {
      await deleteProject(proj.id);
      if (selected()?.id === proj.id) setSelected(null);
      setSuccess(t('projects.deleted'));
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<ProjectItem>[] = [
    { key: 'id', title: 'ID', render: (p) => <span class="font-mono text-xs">{p.id}</span> },
    { key: 'name', title: t('common.name'), render: (p) => <span class="font-medium">{p.name}</span> },
    { key: 'org_id', title: t('common.tenant'), render: (p) => <span class="text-sm">{p.org_id || '-'}</span> },
    {
      key: 'created_at',
      title: t('common.createdAt'),
      render: (p) => <span class="text-sm text-base-content/70">{formatDateTime(p.created_at)}</span>,
    },
  ];

  const appColumns: Column<ApplicationItem>[] = [
    { key: 'name', title: t('projects.apps'), render: (a) => <span class="font-medium">{a.name}</span> },
    { key: 'type', title: t('common.type'), render: (a) => <span class="text-sm">{a.type}</span> },
    { key: 'client_id', title: 'Client ID', render: (a) => <span class="font-mono text-xs">{a.client_id}</span> },
    { key: 'active', title: t('common.status'), render: (a) => <span class={'badge badge-sm ' + (a.active ? 'badge-success' : 'badge-outline')}>{a.active ? t('common.enabled') : t('common.disabled')}</span> },
  ];

  const roleColumns: Column<RoleItem>[] = [
    { key: 'key', title: t('common.key'), render: (r) => <span class="font-mono text-xs">{r.key}</span> },
    { key: 'name', title: t('common.name'), render: (r) => <span class="font-medium">{r.name}</span> },
    { key: 'permissions', title: t('common.permissions'), render: (r) => <span class="text-xs text-base-content/60">{r.permissions}</span> },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('projects.title')}</h2>
        <p class="text-sm text-base-content/60">{t('projects.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('projects.projectName')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('projects.namePlaceholder')} value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('projects.orgIdOptional')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder="1" value={orgInput()} onInput={(e) => setOrgInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? t('common.creating') : t('projects.create')}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(p) => p.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText={t('projects.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(proj) => (
          <div class="flex gap-1">
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => onSelect(proj)}>{t('common.manage')}</button>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(proj)}>{t('common.delete')}</button>
          </div>
        )}
      />

      <Show when={selected()}>
        {(proj) => (
          <div class="space-y-4 rounded-lg border border-base-300 p-4">
            <h3 class="font-semibold">{t('projects.detail', { name: proj().name })}</h3>

            <Show when={credentials()}>
              {(creds) => (
                <div role="alert" class="alert alert-info py-2 text-xs">
                  <div class="space-y-1">
                    <p>client_id: <span class="font-mono">{creds().client_id}</span></p>
                    <p>{t('projects.clientSecretOnce')}: <span class="font-mono">{creds().client_secret}</span></p>
                  </div>
                </div>
              )}
            </Show>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="space-y-2">
                <h4 class="text-sm font-semibold">{t('projects.apps')}</h4>
                <form onSubmit={onCreateApp} class="flex gap-2">
                  <input type="text" class="input input-bordered input-sm flex-1" placeholder={t('projects.appName')} value={appName()} onInput={(e) => setAppName(e.currentTarget.value)} required />
                  <button type="submit" class="btn btn-primary btn-sm">{t('projects.addApp')}</button>
                </form>
                <DataTable
                  columns={appColumns}
                  rows={apps()}
                  rowKey={(a) => a.id}
                  total={apps().length}
                  page={1}
                  totalPages={1}
                  loading={false}
                  error={null}
                  emptyText={t('projects.noApps')}
                  onPageChange={() => {}}
                />
              </div>
              <div class="space-y-2">
                <h4 class="text-sm font-semibold">{t('projects.roles')}</h4>
                <form onSubmit={onCreateRole} class="flex gap-2">
                  <input type="text" class="input input-bordered input-sm w-24" placeholder="key" value={roleKey()} onInput={(e) => setRoleKey(e.currentTarget.value)} required />
                  <input type="text" class="input input-bordered input-sm flex-1" placeholder={t('projects.roleName')} value={roleName()} onInput={(e) => setRoleName(e.currentTarget.value)} required />
                  <button type="submit" class="btn btn-primary btn-sm">{t('projects.addRole')}</button>
                </form>
                <DataTable
                  columns={roleColumns}
                  rows={roles()}
                  rowKey={(r) => r.id}
                  total={roles().length}
                  page={1}
                  totalPages={1}
                  loading={false}
                  error={null}
                  emptyText={t('projects.noRoles')}
                  onPageChange={() => {}}
                />
              </div>
            </div>
          </div>
        )}
      </Show>
    </div>
  );
}

export default Projects;
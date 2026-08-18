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
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Projects() {
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
      setSuccess('项目已创建');
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
    if (!window.confirm('确定删除项目「' + proj.name + '」吗？')) return;
    try {
      await deleteProject(proj.id);
      if (selected()?.id === proj.id) setSelected(null);
      setSuccess('项目已删除');
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<ProjectItem>[] = [
    { key: 'id', title: 'ID', render: (p) => <span class="font-mono text-xs">{p.id}</span> },
    { key: 'name', title: '名称', render: (p) => <span class="font-medium">{p.name}</span> },
    { key: 'org_id', title: '组织', render: (p) => <span class="text-sm">{p.org_id || '-'}</span> },
    {
      key: 'created_at',
      title: '创建时间',
      render: (p) => <span class="text-sm text-base-content/70">{formatDateTime(p.created_at)}</span>,
    },
  ];

  const appColumns: Column<ApplicationItem>[] = [
    { key: 'name', title: '应用', render: (a) => <span class="font-medium">{a.name}</span> },
    { key: 'type', title: '类型', render: (a) => <span class="text-sm">{a.type}</span> },
    { key: 'client_id', title: 'Client ID', render: (a) => <span class="font-mono text-xs">{a.client_id}</span> },
    { key: 'active', title: '状态', render: (a) => <span class={'badge badge-sm ' + (a.active ? 'badge-success' : 'badge-outline')}>{a.active ? '启用' : '停用'}</span> },
  ];

  const roleColumns: Column<RoleItem>[] = [
    { key: 'key', title: 'Key', render: (r) => <span class="font-mono text-xs">{r.key}</span> },
    { key: 'name', title: '名称', render: (r) => <span class="font-medium">{r.name}</span> },
    { key: 'permissions', title: '权限', render: (r) => <span class="text-xs text-base-content/60">{r.permissions}</span> },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">项目 / 应用 / 角色</h2>
        <p class="text-sm text-base-content/60">OAuth 客户端与 RBAC 角色的容器</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">项目名称</span>
          <input type="text" class="input input-bordered input-sm" placeholder="例如：LifeApp" value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">组织 ID（可选）</span>
          <input type="text" class="input input-bordered input-sm" placeholder="1" value={orgInput()} onInput={(e) => setOrgInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? '创建中…' : '创建项目'}
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
        emptyText="暂无项目"
        onPageChange={(p) => void paged.reload(p)}
        actions={(proj) => (
          <div class="flex gap-1">
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => onSelect(proj)}>管理</button>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(proj)}>删除</button>
          </div>
        )}
      />

      <Show when={selected()}>
        {(proj) => (
          <div class="space-y-4 rounded-lg border border-base-300 p-4">
            <h3 class="font-semibold">项目「{proj().name}」详情</h3>

            <Show when={credentials()}>
              {(creds) => (
                <div role="alert" class="alert alert-info py-2 text-xs">
                  <div class="space-y-1">
                    <p>client_id: <span class="font-mono">{creds().client_id}</span></p>
                    <p>client_secret（仅显示一次）: <span class="font-mono">{creds().client_secret}</span></p>
                  </div>
                </div>
              )}
            </Show>

            <div class="grid gap-4 md:grid-cols-2">
              <div class="space-y-2">
                <h4 class="text-sm font-semibold">应用</h4>
                <form onSubmit={onCreateApp} class="flex gap-2">
                  <input type="text" class="input input-bordered input-sm flex-1" placeholder="应用名" value={appName()} onInput={(e) => setAppName(e.currentTarget.value)} required />
                  <button type="submit" class="btn btn-primary btn-sm">添加应用</button>
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
                  emptyText="暂无应用"
                  onPageChange={() => {}}
                />
              </div>
              <div class="space-y-2">
                <h4 class="text-sm font-semibold">角色</h4>
                <form onSubmit={onCreateRole} class="flex gap-2">
                  <input type="text" class="input input-bordered input-sm w-24" placeholder="key" value={roleKey()} onInput={(e) => setRoleKey(e.currentTarget.value)} required />
                  <input type="text" class="input input-bordered input-sm flex-1" placeholder="名称" value={roleName()} onInput={(e) => setRoleName(e.currentTarget.value)} required />
                  <button type="submit" class="btn btn-primary btn-sm">添加角色</button>
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
                  emptyText="暂无角色"
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

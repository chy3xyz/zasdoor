import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  assignRoleToUser,
  createRole,
  deleteRole,
  listRoles,
  toApiError,
  type RoleItem,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';

function Roles() {
  const { t } = useI18n();
  const toast = useToast();
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [keyInput, setKeyInput] = createSignal('');
  const [nameInput, setNameInput] = createSignal('');
  const [permissionsInput, setPermissionsInput] = createSignal('');
  const [roles, setRoles] = createSignal<RoleItem[]>([]);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [assignRoleItem, setAssignRoleItem] = createSignal<RoleItem | null>(null);
  const [assignUserId, setAssignUserId] = createSignal('');
  const [assignProjectId, setAssignProjectId] = createSignal('');
  const [assigning, setAssigning] = createSignal(false);

  const refresh = async () => {
    setLoading(true);
    setError(null);
    try {
      setRoles(await listRoles(0));
    } catch (err) {
      setError(toApiError(err).message);
    } finally {
      setLoading(false);
    }
  };

  // Roles are project-scoped on the backend; project 0 is the default space.
  refresh();

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      await createRole(0, {
        key: keyInput().trim(),
        name: nameInput().trim(),
        permissions: permissionsInput().trim() || undefined,
      });
      setKeyInput('');
      setNameInput('');
      setPermissionsInput('');
      setSuccess(t('roles.created'));
      await refresh();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onDelete = async (role: RoleItem) => {
    if (!window.confirm(t('roles.confirmDelete', { name: role.name }))) return;
    try {
      await deleteRole(role.id);
      setSuccess(t('roles.deleted'));
      await refresh();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onAssign = async (e: SubmitEvent) => {
    e.preventDefault();
    const role = assignRoleItem();
    if (!role || assigning()) return;
    const userId = Number(assignUserId().trim());
    if (!Number.isInteger(userId) || userId <= 0) {
      toast.show(t('groups.invalidUserId'), 'error');
      return;
    }
    const projectRaw = assignProjectId().trim();
    const projectId = projectRaw ? Number(projectRaw) : 0;
    if (!Number.isInteger(projectId) || projectId < 0) {
      toast.show(t('common.error'), 'error');
      return;
    }
    setAssigning(true);
    try {
      await assignRoleToUser(role.id, { user_id: userId, project_id: projectId });
      setSuccess(t('roles.assigned', { id: userId }));
      setAssignRoleItem(null);
      setAssignUserId('');
      setAssignProjectId('');
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setAssigning(false);
    }
  };

  const columns: Column<RoleItem>[] = [
    { key: 'id', title: t('common.id'), render: (r) => <span class="font-mono text-xs">{r.id}</span> },
    { key: 'key', title: t('common.key'), render: (r) => <span class="font-mono text-xs">{r.key}</span> },
    { key: 'name', title: t('common.name'), render: (r) => <span class="font-medium">{r.name}</span> },
    { key: 'permissions', title: t('common.permissions'), render: (r) => <span class="text-xs text-base-content/60">{r.permissions}</span> },
    { key: 'project_id', title: t('roles.col.project'), render: (r) => <span class="text-sm">{r.project_id}</span> },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('roles.title')}</h2>
        <p class="text-sm text-base-content/60">{t('roles.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex flex-wrap items-end gap-2">
        <label class="form-control w-full max-w-[12rem]">
          <span class="label-text mb-1">{t('common.key')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('roles.keyPlaceholder')} value={keyInput()} onInput={(e) => setKeyInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-[12rem]">
          <span class="label-text mb-1">{t('common.name')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('roles.namePlaceholder')} value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('common.permissions')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('roles.permissionsPlaceholder')} value={permissionsInput()} onInput={(e) => setPermissionsInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? t('common.creating') : t('roles.create')}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <DataTable
        columns={columns}
        rows={roles()}
        rowKey={(r) => r.id}
        total={roles().length}
        page={1}
        totalPages={1}
        loading={loading()}
        error={error()}
        emptyText={t('roles.empty')}
        onPageChange={() => {}}
        actions={(role) => (
          <div class="flex gap-1">
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => setAssignRoleItem(role)}>{t('roles.assign')}</button>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => void onDelete(role)}>{t('common.delete')}</button>
          </div>
        )}
      />

      <Show when={assignRoleItem()}>
        {(role) => (
          <div class="rounded-lg border border-base-300 p-4">
            <h3 class="mb-3 font-semibold">{t('roles.assignTitle', { name: role().name })}</h3>
            <form onSubmit={onAssign} class="flex flex-wrap items-end gap-2">
              <label class="form-control w-full max-w-[12rem]">
                <span class="label-text mb-1">{t('common.user')}</span>
                <input type="number" min="1" class="input input-bordered input-sm" placeholder={t('roles.userIdPlaceholder')} value={assignUserId()} onInput={(e) => setAssignUserId(e.currentTarget.value)} required />
              </label>
              <label class="form-control w-full max-w-[12rem]">
                <span class="label-text mb-1">{t('roles.col.project')}</span>
                <input type="number" min="0" class="input input-bordered input-sm" placeholder={t('roles.projectIdPlaceholder')} value={assignProjectId()} onInput={(e) => setAssignProjectId(e.currentTarget.value)} />
              </label>
              <button type="submit" class="btn btn-primary btn-sm" disabled={assigning()}>{t('roles.assign')}</button>
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setAssignRoleItem(null)}>{t('common.cancel')}</button>
            </form>
          </div>
        )}
      </Show>
    </div>
  );
}

export default Roles;

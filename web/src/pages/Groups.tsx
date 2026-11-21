import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import {
  addGroupMember,
  createGroup,
  deleteGroup,
  listGroupMembers,
  listGroups,
  removeGroupMember,
  toApiError,
  type GroupItem,
  type GroupMember,
} from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Groups() {
  const { t } = useI18n();
  const toast = useToast();
  const [creating, setCreating] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');
  const [orgInput, setOrgInput] = createSignal('');
  const [descriptionInput, setDescriptionInput] = createSignal('');
  const [selected, setSelected] = createSignal<GroupItem | null>(null);
  const [members, setMembers] = createSignal<GroupMember[]>([]);
  const [memberUserId, setMemberUserId] = createSignal('');
  const [membersLoading, setMembersLoading] = createSignal(false);

  const paged = usePaged<GroupItem>((page, pageSize) => listGroups(page, pageSize), PAGE_SIZE);

  const loadMembers = async (groupId: number) => {
    setMembersLoading(true);
    try {
      setMembers(await listGroupMembers(groupId));
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setMembersLoading(false);
    }
  };

  const onSelect = async (group: GroupItem) => {
    setSelected(group);
    setMemberUserId('');
    await loadMembers(group.id);
  };

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      const orgRaw = orgInput().trim();
      const orgId = orgRaw ? Number(orgRaw) : 0;
      await createGroup({
        name: nameInput().trim(),
        org_id: Number.isInteger(orgId) && orgId > 0 ? orgId : undefined,
        description: descriptionInput().trim() || undefined,
      });
      setNameInput('');
      setOrgInput('');
      setDescriptionInput('');
      setSuccess(t('groups.created'));
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onDelete = async (group: GroupItem) => {
    if (!window.confirm(t('groups.confirmDelete', { name: group.name }))) return;
    try {
      await deleteGroup(group.id);
      if (selected()?.id === group.id) {
        setSelected(null);
        setMembers([]);
      }
      setSuccess(t('groups.deleted'));
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onAddMember = async (e: SubmitEvent) => {
    e.preventDefault();
    const group = selected();
    if (!group) return;
    const userId = Number(memberUserId().trim());
    if (!Number.isInteger(userId) || userId <= 0) {
      toast.show(t('groups.invalidUserId'), 'error');
      return;
    }
    try {
      await addGroupMember(group.id, userId);
      setMemberUserId('');
      await loadMembers(group.id);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRemoveMember = async (member: GroupMember) => {
    const group = selected();
    if (!group) return;
    if (!window.confirm(t('groups.confirmRemoveMember', { id: member.user_id }))) return;
    try {
      await removeGroupMember(group.id, member.user_id);
      setSuccess(t('groups.memberRemoved'));
      await loadMembers(group.id);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<GroupItem>[] = [
    { key: 'id', title: t('common.id'), render: (g) => <span class="font-mono text-xs">{g.id}</span> },
    { key: 'name', title: t('common.name'), render: (g) => <span class="font-medium">{g.name}</span> },
    { key: 'org_id', title: t('groups.col.orgId'), render: (g) => <span class="text-sm">{g.org_id}</span> },
    { key: 'description', title: t('groups.col.description'), render: (g) => <span class="text-sm text-base-content/60">{g.description || '-'}</span> },
    {
      key: 'status',
      title: t('common.status'),
      render: (g) => (
        <span class={'badge badge-sm ' + (g.active ? 'badge-success' : 'badge-outline')}>
          {g.active ? t('common.enabled') : t('common.disabled')}
        </span>
      ),
    },
    { key: 'created_at', title: t('common.createdAt'), render: (g) => <span class="text-sm text-base-content/70">{formatDateTime(g.created_at)}</span> },
  ];

  const memberColumns: Column<GroupMember>[] = [
    { key: 'id', title: t('common.id'), render: (m) => <span class="font-mono text-xs">{m.id}</span> },
    { key: 'user_id', title: t('common.user'), render: (m) => <span class="font-mono text-sm">#{m.user_id}</span> },
    { key: 'created_at', title: t('common.createdAt'), render: (m) => <span class="text-sm text-base-content/70">{formatDateTime(m.created_at)}</span> },
  ];

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">{t('groups.title')}</h2>
        <p class="text-sm text-base-content/60">{t('groups.subtitle')}</p>
      </div>

      <form onSubmit={onCreate} class="flex flex-wrap items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('common.name')}</span>
          <input type="text" class="input input-bordered input-sm" placeholder={t('groups.namePlaceholder')} value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-[10rem]">
          <span class="label-text mb-1">{t('groups.orgIdOptional')}</span>
          <input type="number" min="1" class="input input-bordered input-sm" placeholder="1" value={orgInput()} onInput={(e) => setOrgInput(e.currentTarget.value)} />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">{t('groups.descriptionOptional')}</span>
          <input type="text" class="input input-bordered input-sm" value={descriptionInput()} onInput={(e) => setDescriptionInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? t('common.creating') : t('groups.create')}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(g) => g.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText={t('groups.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(group) => (
          <div class="flex gap-1">
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => void onSelect(group)}>{t('common.manage')}</button>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => void onDelete(group)}>{t('common.delete')}</button>
          </div>
        )}
      />

      <Show when={selected()}>
        {(group) => (
          <div class="space-y-3 rounded-lg border border-base-300 p-4">
            <h3 class="font-semibold">{t('groups.membersTitle', { name: group().name })}</h3>
            <form onSubmit={onAddMember} class="flex items-end gap-2">
              <label class="form-control w-full max-w-xs">
                <span class="label-text mb-1">{t('groups.members')}</span>
                <input type="number" min="1" class="input input-bordered input-sm" placeholder={t('groups.userIdPlaceholder')} value={memberUserId()} onInput={(e) => setMemberUserId(e.currentTarget.value)} required />
              </label>
              <button type="submit" class="btn btn-primary btn-sm">{t('groups.addMember')}</button>
            </form>
            <DataTable
              columns={memberColumns}
              rows={members()}
              rowKey={(m) => m.id}
              total={members().length}
              page={1}
              totalPages={1}
              loading={membersLoading()}
              error={null}
              emptyText={t('groups.noMembers')}
              onPageChange={() => {}}
              actions={(m) => (
                <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => void onRemoveMember(m)}>{t('common.delete')}</button>
              )}
            />
          </div>
        )}
      </Show>
    </div>
  );
}

export default Groups;

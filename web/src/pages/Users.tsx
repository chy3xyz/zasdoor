import { createSignal, Show } from 'solid-js';
import { useToast } from '#ui/components';

import { deleteUser, listUsers, revokeUserSessions, toApiError, type AuthUser } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import UserFormModal, { type UserFormTarget } from '#ui/components/UserFormModal';
import { useAuth } from '#ui/hooks';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Users() {
  const { t } = useI18n();
  const toast = useToast();
  const [auth] = useAuth();
  const [keyword, setKeyword] = createSignal('');
  const [searchInput, setSearchInput] = createSignal('');

  const [modalOpen, setModalOpen] = createSignal(false);
  const [modalMode, setModalMode] = createSignal<UserFormTarget>('create');
  const [modalUser, setModalUser] = createSignal<AuthUser | null>(null);

  const paged = usePaged<AuthUser>((page, pageSize) => listUsers(page, pageSize, keyword()), PAGE_SIZE);

  const onSearch = (e: SubmitEvent) => {
    e.preventDefault();
    setKeyword(searchInput());
    void paged.reload(1);
  };

  const openCreate = () => {
    setModalMode('create');
    setModalUser(null);
    setModalOpen(true);
  };

  const openEdit = (user: AuthUser) => {
    setModalMode('edit');
    setModalUser(user);
    setModalOpen(true);
  };

  const onRemove = async (user: AuthUser) => {
    if (!window.confirm(t('users.confirmDelete', { name: user.name }))) return;
    try {
      await deleteUser(user.id);
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRevoke = async (user: AuthUser) => {
    if (!window.confirm(t('users.confirmKick', { name: user.name }))) return;
    try {
      await revokeUserSessions(user.id);
      toast.show(t('common.kicked'), 'success');
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<AuthUser>[] = [
    { key: 'id', title: 'ID', render: (u) => <span class="font-mono text-xs">{u.id}</span> },
    { key: 'name', title: t('auth.signUp.name'), render: (u) => u.name },
    { key: 'email', title: t('common.email'), render: (u) => <span class="text-sm">{u.email}</span> },
    {
      key: 'admin',
      title: t('common.role'),
      render: (u) => (
        <span class={`badge badge-sm ${u.admin ? 'badge-primary' : 'badge-ghost'}`}>
          {u.admin ? t('common.admin') : t('common.user')}
        </span>
      ),
    },
    {
      key: 'verified',
      title: t('common.status'),
      render: (u) => (
        <span class={`badge badge-sm ${u.verified ? 'badge-success' : 'badge-outline'}`}>
          {u.verified ? t('common.verified') : t('common.unverified')}
        </span>
      ),
    },
    {
      key: 'tenant_id',
      title: t('common.tenant'),
      render: (u) => <span class="badge badge-sm badge-ghost font-mono">{u.tenant_id}</span>,
    },
    {
      key: 'created_at',
      title: t('common.createdAt'),
      render: (u) => <span class="text-sm text-base-content/70">{formatDateTime(u.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">{t('users.title')}</h2>
          <p class="text-sm text-base-content/60">{t('users.count', { count: paged.total() })}</p>
        </div>
        <button type="button" class="btn btn-primary btn-sm" onClick={openCreate}>
          {t('users.new')}
        </button>
      </div>

      <form onSubmit={onSearch} class="flex items-center gap-2">
        <input
          type="search"
          class="input input-bordered input-sm w-full max-w-xs"
          placeholder={t('users.searchPlaceholder')}
          value={searchInput()}
          onInput={(e) => setSearchInput(e.currentTarget.value)}
        />
        <button type="submit" class="btn btn-sm" disabled={paged.loading()}>
          {t('common.search')}
        </button>
        <Show when={keyword()}>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            onClick={() => {
              setKeyword('');
              setSearchInput('');
              void paged.reload(1);
            }}
          >
            {t('users.clear')}
          </button>
        </Show>
      </form>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(u) => u.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText={t('users.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(user) => (
          <>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              onClick={() => openEdit(user)}
              disabled={user.id === auth.user?.id}
            >
              {t('common.edit')}
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              onClick={() => onRemove(user)}
              disabled={user.id === auth.user?.id}
            >
              {t('common.delete')}
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-warning"
              onClick={() => void onRevoke(user)}
              disabled={user.id === auth.user?.id}
            >
              {t('common.kick')}
            </button>
          </>
        )}
      />

      <UserFormModal
        open={modalOpen()}
        mode={modalMode()}
        user={modalUser()}
        onClose={() => setModalOpen(false)}
        onSaved={() => void paged.reload()}
      />
    </div>
  );
}

export default Users;
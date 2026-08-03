import { createSignal, Show } from 'solid-js';

import { deleteUser, listUsers, toApiError, type AuthUser } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import UserFormModal, { type UserFormTarget } from '#ui/components/UserFormModal';
import { useAuth } from '#ui/hooks';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Users() {
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
    if (!window.confirm(`确定删除用户「${user.name}」吗？此操作不可恢复。`)) return;
    try {
      await deleteUser(user.id);
      void paged.reload();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  const columns: Column<AuthUser>[] = [
    { key: 'id', title: 'ID', render: (u) => <span class="font-mono text-xs">{u.id}</span> },
    { key: 'name', title: '姓名', render: (u) => u.name },
    { key: 'email', title: '邮箱', render: (u) => <span class="text-sm">{u.email}</span> },
    {
      key: 'admin',
      title: '角色',
      render: (u) => (
        <span class={`badge badge-sm ${u.admin ? 'badge-primary' : 'badge-ghost'}`}>
          {u.admin ? '管理员' : '用户'}
        </span>
      ),
    },
    {
      key: 'verified',
      title: '状态',
      render: (u) => (
        <span class={`badge badge-sm ${u.verified ? 'badge-success' : 'badge-outline'}`}>
          {u.verified ? '已验证' : '未验证'}
        </span>
      ),
    },
    {
      key: 'tenant_id',
      title: '租户',
      render: (u) => <span class="badge badge-sm badge-ghost font-mono">{u.tenant_id}</span>,
    },
    {
      key: 'created_at',
      title: '创建时间',
      render: (u) => <span class="text-sm text-base-content/70">{formatDateTime(u.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">用户管理</h2>
          <p class="text-sm text-base-content/60">共 {paged.total()} 个用户</p>
        </div>
        <button type="button" class="btn btn-primary btn-sm" onClick={openCreate}>
          新建用户
        </button>
      </div>

      <form onSubmit={onSearch} class="flex items-center gap-2">
        <input
          type="search"
          class="input input-bordered input-sm w-full max-w-xs"
          placeholder="搜索姓名或邮箱"
          value={searchInput()}
          onInput={(e) => setSearchInput(e.currentTarget.value)}
        />
        <button type="submit" class="btn btn-sm" disabled={paged.loading()}>
          搜索
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
            清除
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
        emptyText="暂无用户"
        onPageChange={(p) => void paged.reload(p)}
        actions={(user) => (
          <>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              onClick={() => openEdit(user)}
              disabled={user.id === auth.user?.id}
            >
              编辑
            </button>
            <button
              type="button"
              class="btn btn-ghost btn-xs text-error"
              onClick={() => onRemove(user)}
              disabled={user.id === auth.user?.id}
            >
              删除
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

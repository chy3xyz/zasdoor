import { For, Show, createEffect, createMemo, createSignal, onMount } from 'solid-js';

import { type AuthUser, deleteUser, listUsers, toApiError } from '#ui/api';
import UserFormModal, { type UserFormTarget } from '#ui/components/UserFormModal';
import { useAuth } from '#ui/hooks';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function Users() {
  const [auth] = useAuth();
  const [users, setUsers] = createSignal<AuthUser[]>([]);
  const [total, setTotal] = createSignal(0);
  const [page, setPage] = createSignal(1);
  const [keyword, setKeyword] = createSignal('');
  const [searchInput, setSearchInput] = createSignal('');
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  const [modalOpen, setModalOpen] = createSignal(false);
  const [modalMode, setModalMode] = createSignal<UserFormTarget>('create');
  const [modalUser, setModalUser] = createSignal<AuthUser | null>(null);

  const totalPages = createMemo(() => Math.max(1, Math.ceil(total() / PAGE_SIZE)));

  // Monotonic request id: only the most recent fetch may apply its result,
  // so rapid search/pagination cannot interleave out-of-order responses.
  let requestSeq = 0;

  const load = async (targetPage = page()) => {
    const seq = ++requestSeq;
    setLoading(true);
    setError(null);
    try {
      const result = await listUsers(targetPage, PAGE_SIZE, keyword());
      if (seq !== requestSeq) return;
      setUsers(result.list);
      setTotal(result.total);
      setPage(result.page);
    } catch (err) {
      if (seq !== requestSeq) return;
      setError(toApiError(err).message);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  };

  onMount(() => {
    void load(1);
  });

  const onSearch = (e: SubmitEvent) => {
    e.preventDefault();
    setKeyword(searchInput());
    void load(1);
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
      void load();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">用户管理</h2>
          <p class="text-sm text-base-content/60">共 {total()} 个用户</p>
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
        <button type="submit" class="btn btn-sm" disabled={loading()}>
          搜索
        </button>
        <Show when={keyword()}>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            onClick={() => {
              setKeyword('');
              setSearchInput('');
              void load(1);
            }}
          >
            清除
          </button>
        </Show>
      </form>

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>ID</th>
              <th>姓名</th>
              <th>邮箱</th>
              <th>角色</th>
              <th>状态</th>
              <th>租户</th>
              <th>创建时间</th>
              <th class="text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            <Show when={users().length === 0 && !loading()}>
              <tr>
                <td colspan={8} class="py-10 text-center text-base-content/50">
                  暂无用户
                </td>
              </tr>
            </Show>
            <For each={users()}>
              {(user) => (
                <tr>
                  <td class="font-mono text-xs">{user.id}</td>
                  <td>{user.name}</td>
                  <td class="text-sm">{user.email}</td>
                  <td>
                    <span class={`badge badge-sm ${user.admin ? 'badge-primary' : 'badge-ghost'}`}>
                      {user.admin ? '管理员' : '用户'}
                    </span>
                  </td>
                  <td>
                    <span class={`badge badge-sm ${user.verified ? 'badge-success' : 'badge-outline'}`}>
                      {user.verified ? '已验证' : '未验证'}
                    </span>
                  </td>
                  <td>
                    <span class="badge badge-sm badge-ghost font-mono">{user.tenant_id}</span>
                  </td>
                  <td class="text-sm text-base-content/70">{formatDateTime(user.created_at)}</td>
                  <td class="text-right">
                    <div class="flex justify-end gap-1">
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
                    </div>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between">
        <span class="text-sm text-base-content/60">
          第 {page()} / {totalPages()} 页
        </span>
        <div class="join">
          <button
            type="button"
            class="btn btn-sm join-item"
            disabled={page() <= 1 || loading()}
            onClick={() => void load(page() - 1)}
          >
            上一页
          </button>
          <button
            type="button"
            class="btn btn-sm join-item"
            disabled={page() >= totalPages() || loading()}
            onClick={() => void load(page() + 1)}
          >
            下一页
          </button>
        </div>
      </div>

      <UserFormModal
        open={modalOpen()}
        mode={modalMode()}
        user={modalUser()}
        onClose={() => setModalOpen(false)}
        onSaved={() => void load()}
      />
    </div>
  );
}

export default Users;

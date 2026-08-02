import { A } from '@solidjs/router';
import { Show, type JSX } from 'solid-js';

import { useAuth } from '#ui/hooks';
import { ROUTE_PATH } from '#ui/constants';

function MainLayout(props: { children?: JSX.Element }) {
  const [auth, actions] = useAuth();

  return (
    <div class="flex h-screen overflow-hidden bg-base-100">
      <aside class="flex w-56 shrink-0 flex-col border-r border-base-300 bg-base-200">
        <div class="flex h-16 items-center gap-2 border-b border-base-300 px-4">
          <span class="text-lg font-bold">Zenaipa</span>
        </div>
        <nav class="flex-1 space-y-1 p-3">
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.users}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              用户管理
            </A>
          </Show>
          <A
            href={ROUTE_PATH.profile}
            class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
            activeClass="active"
          >
            个人资料
          </A>
        </nav>
        <div class="border-t border-base-300 p-3">
          <button type="button" class="btn btn-outline btn-sm w-full" onClick={() => actions.logout()}>
            退出登录
          </button>
        </div>
      </aside>

      <div class="flex flex-1 flex-col overflow-hidden">
        <header class="flex h-16 items-center justify-between border-b border-base-300 px-6">
          <h1 class="text-base font-semibold">管理后台</h1>
          <div class="flex items-center gap-2 text-sm text-base-content/70">
            <span class="badge badge-ghost">{auth.user?.name ?? '-'}</span>
            <span class="badge badge-outline">{auth.user?.admin ? '管理员' : '用户'}</span>
          </div>
        </header>
        <main class="flex-1 overflow-y-auto p-6">{props.children}</main>
      </div>
    </div>
  );
}

export default MainLayout;

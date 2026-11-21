import { A } from '@solidjs/router';
import { For, Show, createEffect, createSignal, onCleanup, onMount, type JSX } from 'solid-js';

import {
  deleteNotification,
  listNotifications,
  markAllRead,
  markRead,
  toApiError,
  unreadCount,
  type NotificationItem,
} from '#ui/api';
import { useAuth } from '#ui/hooks';
import { ROUTE_PATH } from '#ui/constants';
import { useI18n } from '#ui/i18n';
import { formatDateTime } from '#ui/utils';

function NotificationBell() {
  const { t } = useI18n();
  const [open, setOpen] = createSignal(false);
  const [unread, setUnread] = createSignal(0);
  const [items, setItems] = createSignal<NotificationItem[]>([]);

  const refresh = async () => {
    try {
      const [count, result] = await Promise.all([unreadCount(), listNotifications(1, 8)]);
      setUnread(count);
      setItems(result.list);
    } catch {
      // keep previous state on transient errors
    }
  };

  onMount(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), 30_000);
    onCleanup(() => window.clearInterval(timer));
  });

  const onMarkRead = async (id: number) => {
    try {
      await markRead(id);
      await refresh();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  const onMarkAll = async () => {
    try {
      await markAllRead();
      await refresh();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  const onDelete = async (id: number) => {
    try {
      await deleteNotification(id);
      await refresh();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  return (
    <div class="relative">
      <button
        type="button"
        class="btn btn-ghost btn-circle btn-sm relative"
        onClick={() => {
          setOpen(!open());
          if (!open()) void refresh();
        }}
        aria-label={t('nav.notifications')}
      >
        <span class="text-base">🔔</span>
        <Show when={unread() > 0}>
          <span class="badge badge-error badge-xs absolute -top-0.5 -right-0.5">
            {unread() > 99 ? '99+' : unread()}
          </span>
        </Show>
      </button>

      <Show when={open()}>
        <div class="absolute right-0 z-50 mt-2 w-80 rounded-lg border border-base-300 bg-base-100 shadow-xl">
          <div class="flex items-center justify-between border-b border-base-300 px-3 py-2">
            <span class="text-sm font-semibold">{t('nav.notifications')}</span>
            <button type="button" class="btn btn-ghost btn-xs" onClick={onMarkAll}>
              {t('nav.markAllRead')}
            </button>
          </div>
          <div class="max-h-80 overflow-y-auto">
            <Show
              when={items().length > 0}
              fallback={<p class="px-3 py-6 text-center text-sm text-base-content/50">{t('nav.noNotifications')}</p>}
            >
              <For each={items()}>
                {(item) => (
                  <div class={`border-b border-base-200 px-3 py-2 ${item.read ? 'opacity-60' : ''}`}>
                    <div class="flex items-start justify-between gap-2">
                      <div class="min-w-0">
                        <p class="truncate text-sm font-medium">{item.title}</p>
                        <p class="truncate text-xs text-base-content/60">{item.body}</p>
                        <p class="mt-0.5 text-xs text-base-content/40">{formatDateTime(item.created_at)}</p>
                      </div>
                      <div class="flex shrink-0 gap-1">
                        <Show when={!item.read}>
                          <button type="button" class="btn btn-ghost btn-xs" onClick={() => onMarkRead(item.id)}>
                            {t('nav.markRead')}
                          </button>
                        </Show>
                        <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(item.id)}>
                          {t('common.delete')}
                        </button>
                      </div>
                    </div>
                  </div>
                )}
              </For>
            </Show>
          </div>
        </div>
      </Show>
    </div>
  );
}

function MainLayout(props: { children?: JSX.Element }) {
  const [auth, actions] = useAuth();
  const { locale, setLocale, t } = useI18n();
  const [dark, setDark] = createSignal(localStorage.getItem('zasdoor.theme') === 'dark');
  createEffect(() => {
    document.documentElement.setAttribute('data-theme', dark() ? 'dark' : 'light');
    localStorage.setItem('zasdoor.theme', dark() ? 'dark' : 'light');
  });
  const toggleTheme = () => setDark((d) => !d);

  return (
    <div class="flex h-screen overflow-hidden bg-base-100">
      <aside class="flex w-56 shrink-0 flex-col border-r border-base-300 bg-base-200">
        <div class="flex h-16 items-center gap-2 border-b border-base-300 px-4">
          <span class="text-lg font-bold">Zasdoor</span>
        </div>
        <nav class="flex-1 space-y-1 p-3">
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.dashboard}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.dashboard')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.users}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.users')}
            </A>
          </Show>
          <A
            href={ROUTE_PATH.aiChat}
            class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
            activeClass="active"
          >
            {t('nav.aiChat')}
          </A>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.aiAdmin}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.aiAdmin')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.auditLogs}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.auditLogs')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.mailTemplates}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.mailTemplates')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.tasks}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.tasks')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.tenants}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.tenants')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.organizations}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.organizations')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.projects}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.projects')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.agents}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.agents')}
            </A>
          </Show>
          <Show when={auth.user?.admin}>
            <A
              href={ROUTE_PATH.mfaSettings}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.mfaSettings')}
            </A>
            <A
              href={ROUTE_PATH.idpSettings}
              class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
              activeClass="active"
            >
              {t('nav.idpSettings')}
            </A>
          </Show>
          <A
            href={ROUTE_PATH.files}
            class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
            activeClass="active"
          >
            {t('nav.files')}
          </A>
          <A
            href={ROUTE_PATH.profile}
            class="block rounded-lg px-3 py-2 text-sm hover:bg-base-300 [&.active]:bg-primary [&.active]:text-primary-content"
            activeClass="active"
          >
            {t('nav.profile')}
          </A>
        </nav>
        <div class="border-t border-base-300 p-3">
          <button type="button" class="btn btn-outline btn-sm w-full" onClick={() => actions.logout()}>
            {t('nav.logout')}
          </button>
        </div>
      </aside>

      <div class="flex flex-1 flex-col overflow-hidden">
        <header class="flex h-16 items-center justify-between border-b border-base-300 px-6">
          <h1 class="text-base font-semibold">{t('app.adminConsole')}</h1>
          <div class="flex items-center gap-3 text-sm text-base-content/70">
            <NotificationBell />
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => setLocale(locale() === 'zh' ? 'en' : 'zh')} aria-label={t('nav.language')}>
              {locale() === 'zh' ? 'EN' : '中文'}
            </button>
            <button type="button" class="btn btn-ghost btn-xs" onClick={toggleTheme} aria-label={t('nav.toggleTheme')}>
              {dark() ? '🌙' : '☀️'}
            </button>
            <span class="badge badge-ghost">{auth.user?.name ?? '-'}</span>
            <span class="badge badge-outline">{auth.user?.admin ? t('nav.admin') : t('nav.user')}</span>
          </div>
        </header>
        <main class="flex-1 overflow-y-auto p-6">{props.children}</main>
      </div>
    </div>
  );
}

export default MainLayout;
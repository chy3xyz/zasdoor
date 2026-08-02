import { APP_CONFIG } from '#ui/config';

export const NOTIFY_PATH = {
  list: `${APP_CONFIG.apiPrefix}/notifications`,
  unreadCount: `${APP_CONFIG.apiPrefix}/notifications/unread-count`,
  readAll: `${APP_CONFIG.apiPrefix}/notifications/read-all`,
} as const;

export const notifyDetail = (id: number) => `${APP_CONFIG.apiPrefix}/notifications/${id}`;
export const notifyRead = (id: number) => `${APP_CONFIG.apiPrefix}/notifications/${id}/read`;
export const notifyListQuery = (page: number, pageSize: number, unread?: boolean) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  if (unread) params.set('unread', '1');
  return `${NOTIFY_PATH.list}?${params.toString()}`;
};

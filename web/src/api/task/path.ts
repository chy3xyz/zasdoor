import { APP_CONFIG } from '#ui/config';

export const TASK_PATH = {
  list: `${APP_CONFIG.apiPrefix}/tasks`,
  stats: `${APP_CONFIG.apiPrefix}/tasks/stats`,
  purge: `${APP_CONFIG.apiPrefix}/tasks/purge`,
} as const;

export const taskDetail = (id: number) => `${APP_CONFIG.apiPrefix}/tasks/${id}`;
export const taskRetry = (id: number) => `${APP_CONFIG.apiPrefix}/tasks/${id}/retry`;
export const taskCancel = (id: number) => `${APP_CONFIG.apiPrefix}/tasks/${id}/cancel`;
export const taskListQuery = (page: number, pageSize: number, status?: string) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  if (status) params.set('status', status);
  return `${TASK_PATH.list}?${params.toString()}`;
};

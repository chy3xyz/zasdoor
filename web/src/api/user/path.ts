import { APP_CONFIG } from '#ui/config';

export const USER_PATH = {
  list: `${APP_CONFIG.apiPrefix}/users`,
  create: `${APP_CONFIG.apiPrefix}/users`,
} as const;

export function userDetail(id: number | string): string {
  return `${APP_CONFIG.apiPrefix}/users/${id}`;
}

export function userListQuery(page: number, pageSize: number, keyword?: string): string {
  const params = new URLSearchParams();
  params.set('page', String(page));
  params.set('page_size', String(pageSize));
  if (keyword && keyword.trim().length > 0) params.set('keyword', keyword.trim());
  const qs = params.toString();
  return qs ? `${USER_PATH.list}?${qs}` : USER_PATH.list;
}

import { APP_CONFIG } from '#ui/config';

export const FILE_PATH = {
  list: `${APP_CONFIG.apiPrefix}/files`,
} as const;

export const fileDetail = (id: number) => `${APP_CONFIG.apiPrefix}/files/${id}`;
export const fileListQuery = (page: number, pageSize: number) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  return `${FILE_PATH.list}?${params.toString()}`;
};

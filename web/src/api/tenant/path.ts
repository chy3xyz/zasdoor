import { APP_CONFIG } from '#ui/config';

export const TENANT_PATH = {
  list: `${APP_CONFIG.apiPrefix}/tenants`,
  create: `${APP_CONFIG.apiPrefix}/tenants`,
} as const;

export const tenantDetail = (id: number) => `${APP_CONFIG.apiPrefix}/tenants/${id}`;
export const tenantListQuery = (page: number, pageSize: number) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  return `${TENANT_PATH.list}?${params.toString()}`;
};

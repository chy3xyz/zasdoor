import { APP_CONFIG } from '#ui/config';

export const AUDIT_PATH = {
  list: `${APP_CONFIG.apiPrefix}/audit-logs`,
} as const;

export interface AuditQuery {
  actor?: number;
  action?: string;
  keyword?: string;
}

export const auditListQuery = (page: number, pageSize: number, q: AuditQuery = {}) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  if (q.actor) params.set('actor', String(q.actor));
  if (q.action) params.set('action', q.action);
  if (q.keyword) params.set('keyword', q.keyword);
  return `${AUDIT_PATH.list}?${params.toString()}`;
};

import { APP_CONFIG } from '#ui/config';

export const AI_PATH = {
  sessions: `${APP_CONFIG.apiPrefix}/ai/sessions`,
  providers: `${APP_CONFIG.apiPrefix}/ai/providers`,
  approvals: `${APP_CONFIG.apiPrefix}/ai/approvals`,
  runs: `${APP_CONFIG.apiPrefix}/ai/runs`,
  metrics: `${APP_CONFIG.apiPrefix}/ai/metrics`,
  skills: `${APP_CONFIG.apiPrefix}/ai/skills`,
  workflowRun: `${APP_CONFIG.apiPrefix}/ai/workflow/run`,
} as const;

export const aiSessionDetail = (id: number) => `${AI_PATH.sessions}/${id}`;
export const aiSessionMessages = (id: number) => `${AI_PATH.sessions}/${id}/messages`;
export const aiSessionChat = (id: number) => `${AI_PATH.sessions}/${id}/chat`;
export const aiProviderDetail = (id: number) => `${AI_PATH.providers}/${id}`;
export const aiApprovalResolve = (id: number, action: 'approve' | 'reject') =>
  `${AI_PATH.approvals}/${id}/${action}`;

export const aiSessionsQuery = (page: number, pageSize: number) =>
  `${AI_PATH.sessions}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;
export const aiProvidersQuery = (page: number, pageSize: number) =>
  `${AI_PATH.providers}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;
export const aiApprovalsQuery = (page: number, pageSize: number, status?: string) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  if (status) params.set('status', status);
  return `${AI_PATH.approvals}?${params.toString()}`;
};
export const aiRunsQuery = (page: number, pageSize: number) =>
  `${AI_PATH.runs}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;

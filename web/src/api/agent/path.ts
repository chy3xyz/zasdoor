import { APP_CONFIG } from '#ui/config';

export const AGENT_PATH = {
  list: `${APP_CONFIG.apiPrefix}/agents`,
  verify: `${APP_CONFIG.apiPrefix}/agents/token/verify`,
} as const;

export const agentDetail = (id: number | string) => `${AGENT_PATH.list}/${id}`;
export const agentDeactivate = (id: number | string) => `${AGENT_PATH.list}/${id}/deactivate`;
export const agentToken = (id: number | string) => `${AGENT_PATH.list}/${id}/token`;

export const agentsQuery = (page: number, pageSize: number) =>
  `${AGENT_PATH.list}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;

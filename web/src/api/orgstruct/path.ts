import { APP_CONFIG } from '#ui/config';

export const ORGSTRUCT_PATH = {
  groups: `${APP_CONFIG.apiPrefix}/iam/groups`,
  domains: `${APP_CONFIG.apiPrefix}/iam/domains`,
} as const;

export const groupDetail = (id: number | string) => `${ORGSTRUCT_PATH.groups}/${id}`;
export const groupMembers = (id: number | string) => `${groupDetail(id)}/members`;
export const groupMemberDetail = (groupId: number | string, userId: number | string) => `${groupMembers(groupId)}/${userId}`;

export const domainDetail = (id: number | string) => `${ORGSTRUCT_PATH.domains}/${id}`;
export const domainVerify = (id: number | string) => `${domainDetail(id)}/verify`;

export const groupsQuery = (page: number, pageSize: number) =>
  `${ORGSTRUCT_PATH.groups}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;
export const domainsQuery = (page: number, pageSize: number) =>
  `${ORGSTRUCT_PATH.domains}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;

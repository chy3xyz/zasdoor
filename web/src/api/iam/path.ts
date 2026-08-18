import { APP_CONFIG } from '#ui/config';

export const IAM_PATH = {
  organizations: `${APP_CONFIG.apiPrefix}/iam/organizations`,
  projects: `${APP_CONFIG.apiPrefix}/iam/projects`,
} as const;

export const organizationDetail = (id: number | string) => `${IAM_PATH.organizations}/${id}`;
export const projectDetail = (id: number | string) => `${IAM_PATH.projects}/${id}`;
export const projectApplications = (id: number | string) => `${IAM_PATH.projects}/${id}/applications`;
export const projectRoles = (id: number | string) => `${IAM_PATH.projects}/${id}/roles`;

export const organizationsQuery = (page: number, pageSize: number) =>
  `${IAM_PATH.organizations}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;
export const projectsQuery = (page: number, pageSize: number) =>
  `${IAM_PATH.projects}?${new URLSearchParams({ page: String(page), page_size: String(pageSize) }).toString()}`;

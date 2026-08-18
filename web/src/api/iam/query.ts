import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import {
  IAM_PATH,
  organizationDetail,
  organizationsQuery,
  projectApplications,
  projectDetail,
  projectRoles,
  projectsQuery,
} from './path';
import type {
  ApplicationItem,
  ClientCredentials,
  CreateApplicationRequest,
  CreateOrganizationRequest,
  CreateProjectRequest,
  CreateRoleRequest,
  OrganizationItem,
  PagedResult,
  ProjectItem,
  RoleItem,
} from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function deleteEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.delete<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listOrganizations(page: number, pageSize: number): Promise<PagedResult<OrganizationItem>> {
  return getEnvelope<PagedResult<OrganizationItem>>(organizationsQuery(page, pageSize));
}

export async function createOrganization(body: CreateOrganizationRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(IAM_PATH.organizations, body);
}

export async function deleteOrganization(id: number): Promise<void> {
  await deleteEnvelope<null>(organizationDetail(id));
}

export async function listProjects(page: number, pageSize: number): Promise<PagedResult<ProjectItem>> {
  return getEnvelope<PagedResult<ProjectItem>>(projectsQuery(page, pageSize));
}

export async function createProject(body: CreateProjectRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(IAM_PATH.projects, body);
}

export async function deleteProject(id: number): Promise<void> {
  await deleteEnvelope<null>(projectDetail(id));
}

export async function listApplications(projectId: number): Promise<ApplicationItem[]> {
  return getEnvelope<ApplicationItem[]>(projectApplications(projectId));
}

export async function createApplication(projectId: number, body: CreateApplicationRequest): Promise<ClientCredentials> {
  return postEnvelope<ClientCredentials>(projectApplications(projectId), body);
}

export async function deleteApplication(id: number): Promise<void> {
  await deleteEnvelope<null>(`${IAM_PATH.projects}/../applications/${id}`);
}

export async function listRoles(projectId: number): Promise<RoleItem[]> {
  return getEnvelope<RoleItem[]>(projectRoles(projectId));
}

export async function createRole(projectId: number, body: CreateRoleRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(projectRoles(projectId), body);
}

export async function deleteRole(id: number): Promise<void> {
  await deleteEnvelope<null>(`${IAM_PATH.projects}/../roles/${id}`);
}

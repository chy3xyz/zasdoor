export interface OrganizationItem {
  id: number;
  name: string;
  description: string;
  domain: string;
  active: boolean;
  created_at: number;
}

export interface ProjectItem {
  id: number;
  tenant_id: number;
  org_id: number;
  name: string;
  description: string;
  active: boolean;
  created_at: number;
}

/** A login session returned by GET /iam/users/{id}/sessions. */
export interface SessionItem {
  id: number;
  user_id: number;
  client_id: number;
  device_id: string;
  ip: string;
  user_agent: string;
  auth_method: string;
  last_seen_at: number;
  expires_at: number;
  revoked_at: number;
}

export interface PagedResult<T> {
  list: T[];
  total: number;
  page: number;
  pageSize: number;
}

export interface CreateOrganizationRequest {
  name: string;
  description?: string;
  domain?: string;
}

export interface CreateProjectRequest {
  name: string;
  description?: string;
  org_id?: number;
}

export interface ApplicationItem {
  id: number;
  project_id: number;
  name: string;
  type: string;
  client_id: string;
  redirect_uris: string;
  grant_types: string;
  response_types: string;
  scopes: string;
  access_token_ttl: number;
  refresh_token_ttl: number;
  pkce_required: boolean;
  active: boolean;
}

export interface CreateApplicationRequest {
  name: string;
  type?: string;
  redirect_uris?: string;
  grant_types?: string;
  response_types?: string;
  scopes?: string;
  access_token_ttl?: number;
  refresh_token_ttl?: number;
  pkce_required?: boolean;
}

export interface ClientCredentials {
  client_id: string;
  client_secret: string;
}

export interface RoleItem {
  id: number;
  project_id: number;
  key: string;
  name: string;
  permissions: string;
}

export interface CreateRoleRequest {
  key: string;
  name: string;
  permissions?: string;
}

export interface AssignRoleRequest {
  user_id: number;
  project_id?: number;
}

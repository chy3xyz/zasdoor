import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { TENANT_PATH, tenantDetail, tenantListQuery } from './path';
import type { CreateTenantRequest, TenantItem, TenantListResult, UpdateTenantRequest } from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listTenants(page: number, pageSize: number): Promise<TenantListResult> {
  return getEnvelope<TenantListResult>(tenantListQuery(page, pageSize));
}

export async function createTenant(body: CreateTenantRequest): Promise<{ id: number }> {
  const { data } = await http.post<{ code: number; msg: string; data: { id: number } }>(TENANT_PATH.create, body);
  return unwrapEnvelope(data);
}

export async function updateTenant(id: number, body: UpdateTenantRequest): Promise<void> {
  const { data } = await http.put<{ code: number; msg: string; data: null }>(tenantDetail(id), body);
  unwrapEnvelope(data);
}

export type { TenantItem, TenantListResult };

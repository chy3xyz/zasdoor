import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import {
  ORGSTRUCT_PATH,
  domainDetail,
  domainVerify,
  domainsQuery,
  groupDetail,
  groupMemberDetail,
  groupMembers,
  groupsQuery,
} from './path';
import type {
  CreateDomainRequest,
  CreateDomainResult,
  CreateGroupRequest,
  DomainItem,
  GroupItem,
  GroupMember,
  VerifyDomainRequest,
} from './types';
import type { PagedResult } from '../iam/types';

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

export async function listGroups(page: number, pageSize: number): Promise<PagedResult<GroupItem>> {
  return getEnvelope<PagedResult<GroupItem>>(groupsQuery(page, pageSize));
}

export async function getGroup(id: number): Promise<GroupItem> {
  return getEnvelope<GroupItem>(groupDetail(id));
}

export async function createGroup(body: CreateGroupRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(ORGSTRUCT_PATH.groups, body);
}

export async function deleteGroup(id: number): Promise<void> {
  await deleteEnvelope<null>(groupDetail(id));
}

export async function listGroupMembers(groupId: number): Promise<GroupMember[]> {
  return getEnvelope<GroupMember[]>(groupMembers(groupId));
}

export async function addGroupMember(groupId: number, userId: number): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(groupMembers(groupId), { user_id: userId });
}

export async function removeGroupMember(groupId: number, userId: number): Promise<void> {
  await deleteEnvelope<null>(groupMemberDetail(groupId, userId));
}

export async function listDomains(page: number, pageSize: number): Promise<PagedResult<DomainItem>> {
  return getEnvelope<PagedResult<DomainItem>>(domainsQuery(page, pageSize));
}

export async function getDomain(id: number): Promise<DomainItem> {
  return getEnvelope<DomainItem>(domainDetail(id));
}

export async function createDomain(body: CreateDomainRequest): Promise<CreateDomainResult> {
  return postEnvelope<CreateDomainResult>(ORGSTRUCT_PATH.domains, body);
}

export async function verifyDomain(id: number, token: string): Promise<DomainItem> {
  return postEnvelope<DomainItem>(domainVerify(id), { token } satisfies VerifyDomainRequest);
}

export async function deleteDomain(id: number): Promise<void> {
  await deleteEnvelope<null>(domainDetail(id));
}

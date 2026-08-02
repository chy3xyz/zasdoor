import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { USER_PATH, userDetail, userListQuery } from './path';
import type {
  CreateUserRequest,
  UpdateUserRequest,
  UserListResult,
} from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function putEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.put<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function deleteEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.delete<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listUsers(
  page: number,
  pageSize: number,
  keyword?: string,
): Promise<UserListResult> {
  return getEnvelope<UserListResult>(userListQuery(page, pageSize, keyword));
}

export async function createUser(body: CreateUserRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(USER_PATH.create, body);
}

export async function updateUser(id: number, body: UpdateUserRequest): Promise<void> {
  await putEnvelope<null>(userDetail(id), body);
}

export async function deleteUser(id: number): Promise<void> {
  await deleteEnvelope<null>(userDetail(id));
}

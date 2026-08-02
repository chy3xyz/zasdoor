import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { TASK_PATH, taskCancel, taskDetail, taskListQuery, taskRetry } from './path';
import type { TaskItem, TaskListResult, TaskStats } from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listTasks(page: number, pageSize: number, status?: string): Promise<TaskListResult> {
  return getEnvelope<TaskListResult>(taskListQuery(page, pageSize, status));
}

export async function getTask(id: number): Promise<TaskItem> {
  return getEnvelope<TaskItem>(taskDetail(id));
}

export async function taskStats(): Promise<TaskStats> {
  return getEnvelope<TaskStats>(TASK_PATH.stats);
}

export async function retryTask(id: number): Promise<void> {
  await postEnvelope<null>(taskRetry(id));
}

export async function cancelTask(id: number): Promise<void> {
  await postEnvelope<null>(taskCancel(id));
}

export async function purgeTasks(): Promise<void> {
  await postEnvelope<null>(TASK_PATH.purge);
}

export async function deleteTask(id: number): Promise<void> {
  await http.delete(taskDetail(id));
}

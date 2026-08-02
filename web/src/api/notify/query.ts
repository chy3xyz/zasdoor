import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { NOTIFY_PATH, notifyDetail, notifyListQuery, notifyRead } from './path';
import type { NotificationListResult } from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listNotifications(page: number, pageSize: number, unread?: boolean): Promise<NotificationListResult> {
  return getEnvelope<NotificationListResult>(notifyListQuery(page, pageSize, unread));
}

export async function unreadCount(): Promise<number> {
  const data = await getEnvelope<{ unread: number }>(NOTIFY_PATH.unreadCount);
  return data.unread;
}

export async function markRead(id: number): Promise<void> {
  await postEnvelope<null>(notifyRead(id));
}

export async function markAllRead(): Promise<void> {
  await postEnvelope<null>(NOTIFY_PATH.readAll);
}

export async function deleteNotification(id: number): Promise<void> {
  await http.delete(notifyDetail(id));
}

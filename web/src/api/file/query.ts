import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { FILE_PATH, fileDetail, fileListQuery } from './path';
import type { FileItem, FileListResult } from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function listFiles(page: number, pageSize: number): Promise<FileListResult> {
  return getEnvelope<FileListResult>(fileListQuery(page, pageSize));
}

/** Raw-body upload: bytes + X-File-Name + Content-Type. */
export async function uploadFile(file: File): Promise<FileItem> {
  const { data } = await http.post<{ code: number; msg: string; data: FileItem }>(FILE_PATH.list, file, {
    headers: {
      'Content-Type': file.type || 'application/octet-stream',
      'X-File-Name': file.name,
    },
  });
  return unwrapEnvelope(data);
}

export async function deleteFile(id: number): Promise<void> {
  await http.delete(fileDetail(id));
}

/** Authenticated download via fetch (Authorization header + blob). */
export async function downloadFile(id: number, name: string): Promise<void> {
  const { getAuthToken } = await import('#ui/api/client');
  const token = getAuthToken();
  const resp = await fetch(fileDetail(id), {
    headers: token ? { Authorization: `Bearer ${token}` } : undefined,
  });
  if (!resp.ok) throw new Error(`下载失败 (${resp.status})`);
  const blob = await resp.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  a.click();
  URL.revokeObjectURL(url);
}

import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { auditListQuery, type AuditQuery } from './path';
import type { AuditListResult } from './types';

export async function listAuditLogs(page: number, pageSize: number, q: AuditQuery = {}): Promise<AuditListResult> {
  const { data } = await http.get<{ code: number; msg: string; data: AuditListResult }>(auditListQuery(page, pageSize, q));
  return unwrapEnvelope(data);
}

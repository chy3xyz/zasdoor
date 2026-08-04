import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { mailTemplateDetail, mailTemplateListQuery } from './path';
import type { MailTemplateListResult } from './types';

export async function listMailTemplates(page: number, pageSize: number): Promise<MailTemplateListResult> {
  const { data } = await http.get<{ code: number; msg: string; data: MailTemplateListResult }>(
    mailTemplateListQuery(page, pageSize),
  );
  return unwrapEnvelope(data);
}

export async function upsertMailTemplate(code: string, subject: string, body: string): Promise<void> {
  const { data } = await http.put<{ code: number; msg: string; data: null }>(mailTemplateDetail(code), { subject, body });
  unwrapEnvelope(data);
}

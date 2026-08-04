export interface MailTemplateItem {
  code: string;
  subject: string;
  body: string;
  updated_at: number;
}

export interface MailTemplateListResult {
  list: MailTemplateItem[];
  total: number;
  page: number;
  pageSize: number;
}

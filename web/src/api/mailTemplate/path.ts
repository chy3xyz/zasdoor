import { APP_CONFIG } from '#ui/config';

export const MAIL_TEMPLATE_PATH = {
  list: `${APP_CONFIG.apiPrefix}/email-templates`,
} as const;

export const mailTemplateListQuery = (page: number, pageSize: number) => {
  const params = new URLSearchParams({ page: String(page), page_size: String(pageSize) });
  return `${MAIL_TEMPLATE_PATH.list}?${params.toString()}`;
};

export const mailTemplateDetail = (code: string) =>
  `${APP_CONFIG.apiPrefix}/email-templates/${encodeURIComponent(code)}`;

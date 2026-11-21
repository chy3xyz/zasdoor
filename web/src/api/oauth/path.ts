import { APP_CONFIG } from '#ui/config';

/**
 * OAuth2 / OIDC endpoints are registered at the server root (no /api prefix)
 * by src/modules/oauth/api.zig.
 */
export const OAUTH_PATH = {
  authorize: '/oauth/authorize',
} as const;

/** IAM applications are only listed per project; no global discovery exists. */
export const projectApplications = (projectId: number | string) =>
  `${APP_CONFIG.apiPrefix}/iam/projects/${projectId}/applications`;

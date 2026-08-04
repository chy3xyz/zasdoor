export interface AuditLogItem {
  id: number;
  actor_user_id: number;
  actor_name: string;
  action: string;
  target_type: string;
  target_id: number;
  detail: string;
  ip: string;
  success: boolean;
  created_at: number;
}

export interface AuditListResult {
  list: AuditLogItem[];
  total: number;
  page: number;
  pageSize: number;
}

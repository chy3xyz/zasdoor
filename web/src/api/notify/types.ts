export interface NotificationItem {
  id: number;
  title: string;
  body: string;
  read: boolean;
  kind: 'info' | 'success' | 'warning' | 'error';
  created_at: number;
}

export interface NotificationListResult {
  list: NotificationItem[];
  total: number;
  page: number;
  pageSize: number;
}

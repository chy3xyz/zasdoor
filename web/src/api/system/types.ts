export interface TaskCounts {
  pending: number;
  claimed: number;
  done: number;
  failed: number;
}

export interface DashboardData {
  users: {
    total: number;
    registered_last_7d: number[];
  };
  tasks: TaskCounts;
  files: number;
  notifications: number;
  tenants: number;
  cache_entries: number;
}

export type TaskStatus = 'pending' | 'claimed' | 'done' | 'failed' | 'canceled';

export interface TaskItem {
  id: number;
  name: string;
  payload: string;
  status: TaskStatus;
  attempts: number;
  max_attempts: number;
  last_error: string;
  available_at: number;
  started_at: number;
  finished_at: number;
  created_at: number;
  updated_at: number;
}

export interface TaskListResult {
  list: TaskItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface TaskStats {
  pending: number;
  claimed: number;
  done: number;
  failed: number;
  canceled: number;
}

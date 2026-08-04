export interface AiProviderItem {
  id: number;
  name: string;
  endpoint: string;
  models: string;
  fallback_providers: string;
  enabled: boolean;
  has_keys: boolean;
  created_at: number;
  updated_at: number;
}

export interface AiProviderListResult {
  list: AiProviderItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface AiSessionItem {
  id: number;
  title: string;
  created_at: number;
  updated_at: number;
}

export interface AiSessionListResult {
  list: AiSessionItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface AiMessageItem {
  id: number;
  role: 'user' | 'assistant' | 'tool';
  content: string;
  created_at: number;
}

export interface AiMessageListResult {
  list: AiMessageItem[];
  total: number;
}

export interface AiChatResult {
  answer: string;
  budget_exhausted: boolean;
}

export interface AiApprovalItem {
  id: number;
  session_id: number;
  requested_by: number;
  skill_name: string;
  args: string;
  status: 'pending' | 'approved' | 'rejected';
  created_at: number;
}

export interface AiApprovalListResult {
  list: AiApprovalItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface AiRunItem {
  id: number;
  session_id: number;
  user_id: number;
  kind: string;
  prompt: string;
  status: string;
  err: string;
  created_at: number;
}

export interface AiRunListResult {
  list: AiRunItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface AiWorkflowStep {
  name: string;
  status: string;
  output: string;
}

export interface AiWorkflowResult {
  status: string;
  steps: AiWorkflowStep[];
}

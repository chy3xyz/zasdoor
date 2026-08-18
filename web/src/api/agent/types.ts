export interface AgentItem {
  id: number;
  name: string;
  owner_user_id: number;
  budget: number;
  budget_period_seconds: number;
  expires_at: number;
  active: boolean;
}

export interface CreateAgentRequest {
  name: string;
  description?: string;
  capabilities?: string;
  scopes?: string;
  budget?: number;
  period_seconds?: number;
  expires_at?: number;
}

export interface AgentTokenResult {
  access_token: string;
  token_type: string;
}

export interface VerifyTokenRequest {
  token: string;
}

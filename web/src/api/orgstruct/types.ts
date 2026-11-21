export interface GroupItem {
  id: number;
  org_id: number;
  name: string;
  description: string;
  active: boolean;
  created_at: number;
}

export interface GroupMember {
  id: number;
  tenant_id: number;
  org_id: number;
  group_id: number;
  user_id: number;
  created_at: number;
  updated_at: number;
}

export interface CreateGroupRequest {
  name: string;
  org_id?: number;
  description?: string;
}

export interface DomainItem {
  id: number;
  org_id: number;
  name: string;
  verified: boolean;
  verified_at: number;
  created_at: number;
}

export interface CreateDomainRequest {
  name: string;
  org_id?: number;
}

export interface CreateDomainResult {
  id: number;
  /** The plaintext verification token is returned exactly once by the backend. */
  verification_token: string;
  /** Client-side only: the name submitted when creating the domain. */
  name?: string;
}

export interface VerifyDomainRequest {
  token: string;
}

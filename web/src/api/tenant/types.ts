export interface TenantItem {
  id: number;
  name: string;
  status: 'active' | 'disabled';
  created_at: number;
  updated_at: number;
}

export interface TenantListResult {
  list: TenantItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface CreateTenantRequest {
  name: string;
}

export interface UpdateTenantRequest {
  name?: string;
  status?: 'active' | 'disabled';
}

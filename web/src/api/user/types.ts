import type { AuthUser } from '#ui/api/auth';

export interface UserListItem extends AuthUser {}

export interface UserListResult {
  list: UserListItem[];
  total: number;
  page: number;
  pageSize: number;
}

export interface CreateUserRequest {
  name: string;
  email: string;
  password: string;
  admin?: boolean;
  tenant_id?: number;
}

export interface UpdateUserRequest {
  name?: string;
  email?: string;
  verified?: boolean;
  admin?: boolean;
}

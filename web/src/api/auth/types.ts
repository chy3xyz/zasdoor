export interface AuthUser {
  id: number;
  name: string;
  email: string;
  verified: boolean;
  admin: boolean;
  created_at: number;
  updated_at: number;
}

export interface LoginRequest {
  email: string;
  password: string;
}

export interface RegisterRequest {
  name: string;
  email: string;
  password: string;
}

export interface LoginResult {
  token: string;
  user: AuthUser;
}

export interface ForgotPasswordRequest {
  email: string;
}

export interface ResetPasswordRequest {
  user_id: number;
  token: string;
  new_password: string;
}

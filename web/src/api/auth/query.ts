import { http } from '#ui/api/client';
import { ApiError, unwrapEnvelope } from '#ui/api/envelope';

import { AUTH_PATH } from './path';
import type {
  AuthUser,
  ForgotPasswordRequest,
  LoginRequest,
  LoginResult,
  RegisterRequest,
  ResetPasswordRequest,
} from './types';

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function login(body: LoginRequest): Promise<LoginResult> {
  return postEnvelope<LoginResult>(AUTH_PATH.login, body);
}

export async function register(body: RegisterRequest): Promise<LoginResult> {
  return postEnvelope<LoginResult>(AUTH_PATH.register, body);
}

export async function logout(): Promise<void> {
  await postEnvelope<null>(AUTH_PATH.logout, {});
}

export async function forgotPassword(body: ForgotPasswordRequest): Promise<void> {
  await postEnvelope<null>(AUTH_PATH.forgotPassword, body);
}

export async function resetPassword(body: ResetPasswordRequest): Promise<void> {
  await postEnvelope<null>(AUTH_PATH.resetPassword, body);
}

/** Current authenticated user. */
export async function me(): Promise<AuthUser> {
  return getEnvelope<AuthUser>(AUTH_PATH.me);
}

/** Normalize any thrown error into an ApiError. */
export function toApiError(err: unknown): ApiError {
  if (err instanceof ApiError) return err;
  if (err instanceof Error) {
    const code = (err as Error & { code?: number }).code;
    return new ApiError(typeof code === 'number' ? code : -1, err.message);
  }
  return new ApiError(-1, '请求失败，请稍后重试');
}

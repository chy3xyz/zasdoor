import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { MFA_PATH } from './path';
import type { MfaPolicy, RecoveryCodesResult, SetPolicyRequest, TotpEnrollResult, VerifyCodeRequest } from './types';

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

export async function enrollTotp(): Promise<TotpEnrollResult> {
  return postEnvelope<TotpEnrollResult>(MFA_PATH.totpEnroll, {});
}

export async function verifyTotp(body: VerifyCodeRequest): Promise<void> {
  await postEnvelope<null>(MFA_PATH.totpVerify, body);
}

export async function generateRecoveryCodes(): Promise<RecoveryCodesResult> {
  return postEnvelope<RecoveryCodesResult>(MFA_PATH.recovery, {});
}

export async function getMfaPolicy(): Promise<MfaPolicy> {
  return getEnvelope<MfaPolicy>(MFA_PATH.policy);
}

export async function setMfaPolicy(body: SetPolicyRequest): Promise<void> {
  const { data } = await http.put<{ code: number; msg: string; data: null }>(MFA_PATH.policy, body);
  unwrapEnvelope(data);
}

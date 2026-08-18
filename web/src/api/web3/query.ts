import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { WEB3_PATH } from './path';
import type {
  BindWalletRequest,
  BindWalletResult,
  SiweNonceRequest,
  SiweNonceResult,
  SiweVerifyRequest,
  SiweVerifyResult,
} from './types';

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

export async function getSiweNonce(body: SiweNonceRequest): Promise<SiweNonceResult> {
  return postEnvelope<SiweNonceResult>(WEB3_PATH.nonce, body);
}

export async function verifySiwe(body: SiweVerifyRequest): Promise<SiweVerifyResult> {
  return postEnvelope<SiweVerifyResult>(WEB3_PATH.verify, body);
}

export async function bindWallet(body: BindWalletRequest): Promise<BindWalletResult> {
  return postEnvelope<BindWalletResult>(WEB3_PATH.bind, body);
}
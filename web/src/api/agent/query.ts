import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { AGENT_PATH, agentDeactivate, agentDetail, agentToken } from './path';
import type { AgentItem, AgentTokenResult, CreateAgentRequest, VerifyTokenRequest } from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string, body: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body);
  return unwrapEnvelope(data);
}

export async function getAgent(id: number): Promise<AgentItem> {
  return getEnvelope<AgentItem>(agentDetail(id));
}

export async function createAgent(body: CreateAgentRequest): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(AGENT_PATH.list, body);
}

export async function deactivateAgent(id: number): Promise<void> {
  await postEnvelope<null>(agentDeactivate(id), {});
}

export async function issueAgentToken(id: number, ttl?: number): Promise<AgentTokenResult> {
  return postEnvelope<AgentTokenResult>(agentToken(id), { ttl: ttl ?? 3600 });
}

export async function verifyAgentToken(body: VerifyTokenRequest): Promise<{ valid: boolean; payload?: unknown }> {
  return postEnvelope<{ valid: boolean; payload?: unknown }>(AGENT_PATH.verify, body);
}

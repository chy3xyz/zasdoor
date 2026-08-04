import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import {
  AI_PATH,
  aiApprovalResolve,
  aiApprovalsQuery,
  aiProviderDetail,
  aiProvidersQuery,
  aiRunsQuery,
  aiSessionChat,
  aiSessionDetail,
  aiSessionMessages,
  aiSessionsQuery,
} from './path';
import type {
  AiApprovalListResult,
  AiChatResult,
  AiMessageListResult,
  AiProviderListResult,
  AiRunListResult,
  AiSessionListResult,
  AiWorkflowResult,
} from './types';

async function getEnvelope<T>(path: string): Promise<T> {
  const { data } = await http.get<{ code: number; msg: string; data: T }>(path);
  return unwrapEnvelope(data);
}

async function postEnvelope<T>(path: string, body?: unknown): Promise<T> {
  const { data } = await http.post<{ code: number; msg: string; data: T }>(path, body ?? {});
  return unwrapEnvelope(data);
}

export async function listAiSessions(page: number, pageSize: number): Promise<AiSessionListResult> {
  return getEnvelope<AiSessionListResult>(aiSessionsQuery(page, pageSize));
}

export async function createAiSession(title: string): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(AI_PATH.sessions, { title });
}

export async function listAiMessages(sessionId: number): Promise<AiMessageListResult> {
  return getEnvelope<AiMessageListResult>(aiSessionMessages(sessionId));
}

export async function chatAi(sessionId: number, content: string): Promise<AiChatResult> {
  return postEnvelope<AiChatResult>(aiSessionChat(sessionId), { content });
}

export async function deleteAiSession(sessionId: number): Promise<void> {
  await http.delete(aiSessionDetail(sessionId));
}

export async function listAiProviders(page: number, pageSize: number): Promise<AiProviderListResult> {
  return getEnvelope<AiProviderListResult>(aiProvidersQuery(page, pageSize));
}

export async function createAiProvider(body: {
  name: string;
  endpoint: string;
  api_keys: string;
  models: string;
  fallback_providers?: string;
  enabled?: boolean;
}): Promise<{ id: number }> {
  return postEnvelope<{ id: number }>(AI_PATH.providers, body);
}

export async function updateAiProvider(
  id: number,
  body: Partial<{
    name: string;
    endpoint: string;
    api_keys: string;
    models: string;
    fallback_providers: string;
    enabled: boolean;
  }>,
): Promise<void> {
  const { data } = await http.put<{ code: number; msg: string; data: null }>(aiProviderDetail(id), body);
  unwrapEnvelope(data);
}

export async function deleteAiProvider(id: number): Promise<void> {
  await http.delete(aiProviderDetail(id));
}

export async function listAiApprovals(page: number, pageSize: number, status?: string): Promise<AiApprovalListResult> {
  return getEnvelope<AiApprovalListResult>(aiApprovalsQuery(page, pageSize, status));
}

export async function resolveAiApproval(id: number, action: 'approve' | 'reject'): Promise<void> {
  await postEnvelope<null>(aiApprovalResolve(id, action));
}

export async function listAiRuns(page: number, pageSize: number): Promise<AiRunListResult> {
  return getEnvelope<AiRunListResult>(aiRunsQuery(page, pageSize));
}

export async function runAiWorkflow(): Promise<AiWorkflowResult> {
  return postEnvelope<AiWorkflowResult>(AI_PATH.workflowRun);
}

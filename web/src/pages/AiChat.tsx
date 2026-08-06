import { createSignal, For, onMount, Show, type JSX } from 'solid-js';

import {
  chatAi,
  createAiSession,
  deleteAiSession,
  getAuthToken,
  listAiMessages,
  listAiSessions,
  toApiError,
  type AiMessageItem,
  type AiSessionItem,
} from '#ui/api';
import { aiSessionChat } from '#ui/api/ai/path';
import { APP_CONFIG } from '#ui/config';

function AiChat() {
  const [sessions, setSessions] = createSignal<AiSessionItem[]>([]);
  const [activeId, setActiveId] = createSignal<number | null>(null);
  const [messages, setMessages] = createSignal<AiMessageItem[]>([]);
  const [input, setInput] = createSignal('');
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [streamingReasoning, setStreamingReasoning] = createSignal('');
  const [streamingAnswer, setStreamingAnswer] = createSignal('');

  const refreshSessions = async () => {
    try {
      const result = await listAiSessions(1, 50);
      setSessions(result.list);
      if (activeId() === null && result.list.length > 0) {
        void selectSession(result.list[0].id);
      }
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const selectSession = async (id: number) => {
    setActiveId(id);
    setError(null);
    try {
      const result = await listAiMessages(id);
      setMessages(result.list);
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  onMount(() => {
    void refreshSessions();
  });

  const onNewSession = async () => {
    try {
      const { id } = await createAiSession('新会话');
      await refreshSessions();
      await selectSession(id);
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const onRemoveSession = async (id: number, e: MouseEvent) => {
    e.stopPropagation();
    if (!window.confirm('确定删除该会话？')) return;
    try {
      await deleteAiSession(id);
      setActiveId(null);
      setMessages([]);
      await refreshSessions();
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const onSend = async (e: SubmitEvent) => {
    e.preventDefault();
    const content = input().trim();
    const sid = activeId();
    if (!content || !sid || busy()) return;
    setInput('');
    setBusy(true);
    setError(null);
    setStreamingReasoning('');
    setStreamingAnswer('');
    setMessages((prev) => [
      ...prev,
      { id: -Date.now(), role: 'user', content, reasoning_content: '', created_at: Math.floor(Date.now() / 1000) },
    ]);
    try {
      const done = await streamChat(sid, content);
      if (done) {
        // 流式已完成并落库:刷新消息历史(取完整记录)。
        const fresh = await listAiMessages(sid);
        setMessages(fresh.list);
      }
      setStreamingReasoning('');
      setStreamingAnswer('');
    } catch (err) {
      const msg = toApiError(err).message;
      setError(msg);
    } finally {
      setBusy(false);
    }
  };

  /** fetch + SSE 消费;服务端不支持流式时自动降级为 JSON。返回 true=流式完成。 */
  const streamChat = async (sid: number, content: string): Promise<boolean> => {
    const token = getAuthToken();
    const base = APP_CONFIG.apiBaseUrl || '';
    const resp = await fetch(`${base}${aiSessionChat(sid)}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'text/event-stream',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify({ content }),
    });
    if (!resp.ok) {
      const env = (await resp.json().catch(() => null)) as { msg?: string } | null;
      throw new Error(env?.msg ?? `请求失败(${resp.status})`);
    }
    const isSse = (resp.headers.get('content-type') ?? '').includes('text/event-stream');
    if (!isSse || !resp.body) {
      // 非流式(旧版/降级):直接解析 JSON。
      const env = (await resp.json()) as { code: number; msg: string; data: { answer: string; reasoning_content?: string } };
      if (env.code !== 0) throw new Error(env.msg || '请求失败');
      setMessages((prev) => [
        ...prev,
        {
          id: -Date.now() - 1,
          role: 'assistant',
          content: env.data.answer,
          reasoning_content: env.data.reasoning_content ?? '',
          created_at: Math.floor(Date.now() / 1000),
        },
      ]);
      return false;
    }

    const reader = resp.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    let reasoning = '';
    let answer = '';
    for (;;) {
      const { value, done: doneReading } = await reader.read();
      if (doneReading) break;
      buf += decoder.decode(value, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf('\n\n')) >= 0) {
        const block = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        const ev = block.match(/^event: (.+)$/m)?.[1];
        const data = block.match(/^data: (.+)$/m)?.[1];
        if (!data) continue;
        if (ev === 'reasoning') {
          reasoning += data;
          setStreamingReasoning(reasoning);
        } else if (ev === 'delta') {
          answer += data;
          setStreamingAnswer(answer);
        } else if (ev === 'done') {
          const j = JSON.parse(data) as { answer: string; reasoning_content: string; budget_exhausted: boolean };
          if (j.budget_exhausted) setError('本次回答触发了 token 预算上限,结果可能不完整。');
          return true;
        } else if (ev === 'error') {
          throw new Error(data);
        }
      }
    }
    throw new Error('流式连接中断');
  };

  const renderBubble = (m: AiMessageItem): JSX.Element => {
    if (m.role === 'user') {
      return (
        <div class="flex justify-end">
          <div class="max-w-[80%] rounded-lg bg-primary px-3 py-2 text-sm text-primary-content whitespace-pre-wrap">
            {m.content}
          </div>
        </div>
      );
    }
    return (
      <div class="flex justify-start">
        <div class="max-w-[85%] space-y-2">
          <Show when={m.reasoning_content}>
            <details class="rounded-lg border border-base-300 bg-base-200/60 px-3 py-2">
              <summary class="cursor-pointer text-xs text-base-content/50">推理过程</summary>
              <p class="mt-1 text-xs text-base-content/50 whitespace-pre-wrap">{m.reasoning_content}</p>
            </details>
          </Show>
          <div class="rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm whitespace-pre-wrap">
            {m.content}
          </div>
        </div>
      </div>
    );
  };

  return (
    <div class="flex h-full gap-4">
      <aside class="flex w-56 shrink-0 flex-col rounded-lg border border-base-300 bg-base-200/50">
        <div class="border-b border-base-300 p-2">
          <button type="button" class="btn btn-primary btn-sm w-full" onClick={() => void onNewSession()}>
            ＋ 新会话
          </button>
        </div>
        <div class="flex-1 space-y-1 overflow-y-auto p-2">
          <For each={sessions()}>
            {(s) => (
              <div
                class={`group flex cursor-pointer items-center justify-between rounded px-2 py-1.5 text-sm ${
                  activeId() === s.id ? 'bg-primary text-primary-content' : 'hover:bg-base-300'
                }`}
                onClick={() => void selectSession(s.id)}
              >
                <span class="truncate">{s.title || `会话 #${s.id}`}</span>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs opacity-0 group-hover:opacity-100"
                  onClick={(e) => onRemoveSession(s.id, e)}
                  aria-label="删除会话"
                >
                  ✕
                </button>
              </div>
            )}
          </For>
          <Show when={sessions().length === 0}>
            <p class="px-2 py-4 text-center text-xs text-base-content/50">暂无会话</p>
          </Show>
        </div>
      </aside>

      <div class="flex min-w-0 flex-1 flex-col rounded-lg border border-base-300">
        <div class="flex items-center justify-between border-b border-base-300 px-4 py-2">
          <h2 class="text-sm font-semibold">AI 助手</h2>
          <span class="text-xs text-base-content/50">可查询用户/任务/审计/租户;写操作需审批</span>
        </div>

        <div class="flex-1 space-y-3 overflow-y-auto p-4">
          <Show when={messages().length === 0 && !busy()}>
            <div class="flex h-full flex-col items-center justify-center gap-2 text-base-content/50">
              <p class="text-lg">🤖</p>
              <p class="text-sm">试试问我:「任务队列现在什么情况?」</p>
              <p class="text-xs">「最近有哪些用户注册?」「帮我发条通知给用户 1」</p>
            </div>
          </Show>
          <For each={messages()}>{(m) => renderBubble(m)}</For>
          <Show when={busy() && streamingReasoning()}>
            <div class="flex justify-start">
              <div class="max-w-[85%] space-y-1 rounded-lg border border-base-300 bg-base-200/60 px-3 py-2">
                <p class="text-xs text-base-content/50">推理中…</p>
                <p class="text-xs text-base-content/50 whitespace-pre-wrap">{streamingReasoning()}</p>
              </div>
            </div>
          </Show>
          <Show when={busy() && streamingAnswer()}>
            <div class="flex justify-start">
              <div class="max-w-[85%] rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm whitespace-pre-wrap">
                {streamingAnswer()}
              </div>
            </div>
          </Show>
          <Show when={busy() && !streamingAnswer() && !streamingReasoning()}>
            <div class="flex justify-start">
              <div class="rounded-lg border border-base-300 bg-base-200 px-3 py-2 text-sm text-base-content/60">
                思考中…
              </div>
            </div>
          </Show>
        </div>

        <Show when={error()}>
          <div role="alert" class="alert alert-error mx-4 mb-2 py-1 text-xs">
            {error()}
          </div>
        </Show>

        <form onSubmit={onSend} class="flex items-center gap-2 border-t border-base-300 p-3">
          <input
            type="text"
            class="input input-bordered input-sm flex-1"
            placeholder={activeId() ? '输入你的问题…' : '先选择或新建一个会话'}
            value={input()}
            disabled={!activeId() || busy()}
            onInput={(e) => setInput(e.currentTarget.value)}
          />
          <button type="submit" class="btn btn-primary btn-sm" disabled={!activeId() || busy() || !input().trim()}>
            发送
          </button>
        </form>
      </div>
    </div>
  );
}

export default AiChat;

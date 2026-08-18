import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import { createAgent, deactivateAgent, getAgent, issueAgentToken, listAgents, toApiError } from '#ui/api';
import type { AgentItem } from '#ui/api';

function Agents() {
  const toast = useToast();
  const [success, setSuccess] = createSignal<string | null>(null);
  const [nameInput, setNameInput] = createSignal('');
  const [capabilitiesInput, setCapabilitiesInput] = createSignal('');
  const [budgetInput, setBudgetInput] = createSignal('');
  const [creating, setCreating] = createSignal(false);
  const [agents, setAgents] = createSignal<AgentItem[]>([]);
  const [agentIdInput, setAgentIdInput] = createSignal('');
  const [tokenResult, setTokenResult] = createSignal<string | null>(null);

  const loadAll = async () => {
    try {
      const res = await listAgents(1, 50);
      setAgents(res.list);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onCreate = async (e: SubmitEvent) => {
    e.preventDefault();
    if (creating()) return;
    setCreating(true);
    setSuccess(null);
    try {
      await createAgent({
        name: nameInput().trim(),
        capabilities: capabilitiesInput().trim() || undefined,
        budget: budgetInput().trim() ? Number(budgetInput().trim()) : undefined,
      });
      setNameInput('');
      setCapabilitiesInput('');
      setBudgetInput('');
      setSuccess('Agent 已创建');
      await loadAll();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setCreating(false);
    }
  };

  const onDeactivate = async (a: AgentItem) => {
    if (!window.confirm('确定停用 Agent「' + a.name + '」吗？')) return;
    try {
      await deactivateAgent(a.id);
      setSuccess('Agent 已停用');
      await loadAll();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onIssue = async (a: AgentItem) => {
    try {
      const res = await issueAgentToken(a.id, 3600);
      setTokenResult(res.access_token);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onLoadById = async () => {
    const id = Number(agentIdInput().trim());
    if (!Number.isFinite(id) || id <= 0) return;
    try {
      const a = await getAgent(id);
      setAgents([a]);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  return (
    <div class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">AI Agent 管理</h2>
        <p class="text-sm text-base-content/60">Agent 身份：能力、预算、Token 签发</p>
      </div>

      <form onSubmit={onCreate} class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">Agent 名称</span>
          <input type="text" class="input input-bordered input-sm" value={nameInput()} onInput={(e) => setNameInput(e.currentTarget.value)} required />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">能力（JSON 数组）</span>
          <input type="text" class="input input-bordered input-sm" placeholder='["wallet.balance"]' value={capabilitiesInput()} onInput={(e) => setCapabilitiesInput(e.currentTarget.value)} />
        </label>
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">预算（每期）</span>
          <input type="number" class="input input-bordered input-sm" value={budgetInput()} onInput={(e) => setBudgetInput(e.currentTarget.value)} />
        </label>
        <button type="submit" class="btn btn-primary btn-sm" disabled={creating()}>
          {creating() ? '创建中…' : '创建 Agent'}
        </button>
      </form>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">{success()}</div>
      </Show>

      <div class="flex items-end gap-2">
        <label class="form-control w-full max-w-xs">
          <span class="label-text mb-1">按 ID 加载</span>
          <input type="number" class="input input-bordered input-sm" value={agentIdInput()} onInput={(e) => setAgentIdInput(e.currentTarget.value)} />
        </label>
        <button type="button" class="btn btn-ghost btn-sm" onClick={onLoadById}>加载</button>
      </div>

      <div class="space-y-2">
        {agents().map((a) => (
          <div class="flex items-center gap-3 rounded-lg border border-base-300 p-3">
            <div class="flex-1">
              <div class="font-medium">{a.name}</div>
              <div class="text-xs text-base-content/60">
                id={a.id} · owner={a.owner_user_id} · budget={a.budget} · 周期 {a.budget_period_seconds}s
              </div>
            </div>
            <span class={'badge badge-sm ' + (a.active ? 'badge-success' : 'badge-error')}>{a.active ? '启用' : '停用'}</span>
            <button type="button" class="btn btn-ghost btn-xs" onClick={() => onIssue(a)}>签发 Token</button>
            <Show when={a.active}>
              <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDeactivate(a)}>停用</button>
            </Show>
          </div>
        ))}
        {agents().length === 0 && <p class="text-sm text-base-content/50">暂无 Agent</p>}
      </div>

      <Show when={tokenResult()}>
        {(tok) => (
          <div role="alert" class="alert alert-info py-2">
            <div class="min-w-0 space-y-1">
              <p class="text-xs font-semibold">Agent Token（复制后不再显示）</p>
              <p class="break-all font-mono text-xs">{tok()}</p>
            </div>
          </div>
        )}
      </Show>
    </div>
  );
}

export default Agents;

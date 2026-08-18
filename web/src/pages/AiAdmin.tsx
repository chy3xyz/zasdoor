import { createSignal, For, Show } from 'solid-js';
import { useToast } from '#ui/components';

import {
  checkAiProvider,
  createAiProvider,
  deleteAiProvider,
  listAiApprovals,
  listAiProviders,
  listAiRuns,
  resolveAiApproval,
  runAiWorkflow,
  toApiError,
  updateAiProvider,
  type AiApprovalItem,
  type AiProviderItem,
  type AiRunItem,
  type AiWorkflowResult,
} from '#ui/api';
import { formatDateTime } from '#ui/utils';

type Tab = 'providers' | 'approvals' | 'runs' | 'workflow';

function AiAdmin() {
  const toast = useToast();
  const [tab, setTab] = createSignal<Tab>('providers');
  const [providers, setProviders] = createSignal<AiProviderItem[]>([]);
  const [approvals, setApprovals] = createSignal<AiApprovalItem[]>([]);
  const [runs, setRuns] = createSignal<AiRunItem[]>([]);
  const [error, setError] = createSignal<string | null>(null);

  // Provider form
  const [formOpen, setFormOpen] = createSignal(false);
  const [editing, setEditing] = createSignal<AiProviderItem | null>(null);
  const [name, setName] = createSignal('');
  const [endpoint, setEndpoint] = createSignal('');
  const [apiKeys, setApiKeys] = createSignal('');
  const [models, setModels] = createSignal('');
  const [enabled, setEnabled] = createSignal(true);

  const [workflow, setWorkflow] = createSignal<AiWorkflowResult | null>(null);
  const [wfBusy, setWfBusy] = createSignal(false);
  const [checkingId, setCheckingId] = createSignal<number | null>(null);
  const [checkResult, setCheckResult] = createSignal<{ id: number; ok: boolean; msg: string } | null>(null);

  const loadProviders = async () => {
    try {
      const r = await listAiProviders(1, 100);
      setProviders(r.list);
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const loadApprovals = async () => {
    try {
      const r = await listAiApprovals(1, 50, 'pending');
      setApprovals(r.list);
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const loadRuns = async () => {
    try {
      const r = await listAiRuns(1, 50);
      setRuns(r.list);
    } catch (err) {
      setError(toApiError(err).message);
    }
  };

  const switchTab = (t: Tab) => {
    setTab(t);
    setError(null);
    if (t === 'providers') void loadProviders();
    if (t === 'approvals') void loadApprovals();
    if (t === 'runs') void loadRuns();
    if (t === 'workflow') setWorkflow(null);
  };

  const openCreate = () => {
    setEditing(null);
    setName('');
    setEndpoint('');
    setApiKeys('');
    setModels('');
    setEnabled(true);
    setFormOpen(true);
  };

  const openEdit = (p: AiProviderItem) => {
    setEditing(p);
    setName(p.name);
    setEndpoint(p.endpoint);
    setApiKeys('');
    setModels(p.models);
    setEnabled(p.enabled);
    setFormOpen(true);
  };

  const onSaveProvider = async () => {
    if (!name().trim() || !endpoint().trim()) {
      toast.show('名称与端点不能为空', 'error');
      return;
    }
    try {
      if (editing()) {
        await updateAiProvider(editing()!.id, {
          name: name(),
          endpoint: endpoint(),
          ...(apiKeys().trim() ? { api_keys: apiKeys() } : {}),
          models: models(),
          enabled: enabled(),
        });
      } else {
        await createAiProvider({
          name: name(),
          endpoint: endpoint(),
          api_keys: apiKeys(),
          models: models(),
          enabled: enabled(),
        });
      }
      setFormOpen(false);
      await loadProviders();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRemoveProvider = async (p: AiProviderItem) => {
    if (!window.confirm(`确定删除 Provider「${p.name}」？`)) return;
    try {
      await deleteAiProvider(p.id);
      await loadProviders();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onCheckProvider = async (p: AiProviderItem) => {
    setCheckingId(p.id);
    setCheckResult(null);
    try {
      await checkAiProvider(p.id);
      setCheckResult({ id: p.id, ok: true, msg: '连接正常' });
    } catch (err) {
      setCheckResult({ id: p.id, ok: false, msg: toApiError(err).message });
    } finally {
      setCheckingId(null);
    }
  };

  const onResolve = async (a: AiApprovalItem, action: 'approve' | 'reject') => {
    try {
      await resolveAiApproval(a.id, action);
      await loadApprovals();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const onRunWorkflow = async () => {
    setWfBusy(true);
    setError(null);
    try {
      setWorkflow(await runAiWorkflow());
    } catch (err) {
      setError(toApiError(err).message);
    } finally {
      setWfBusy(false);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">AI 管理</h2>
          <p class="text-sm text-base-content/60">Provider、审批、运行记录与工作流</p>
        </div>
        <div class="tabs tabs-boxed">
          <button type="button" class={`tab tab-sm ${tab() === 'providers' ? 'tab-active' : ''}`} onClick={() => switchTab('providers')}>
            Provider
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'approvals' ? 'tab-active' : ''}`} onClick={() => switchTab('approvals')}>
            审批
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'runs' ? 'tab-active' : ''}`} onClick={() => switchTab('runs')}>
            运行记录
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'workflow' ? 'tab-active' : ''}`} onClick={() => switchTab('workflow')}>
            工作流
          </button>
        </div>
      </div>

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>

      <Show when={tab() === 'providers'}>
        <div class="space-y-3">
          <div class="flex justify-end">
            <button type="button" class="btn btn-primary btn-sm" onClick={openCreate}>
              新建 Provider
            </button>
          </div>
          <div class="overflow-x-auto rounded-lg border border-base-300">
            <table class="table">
              <thead>
                <tr>
                  <th>名称</th>
                  <th>端点</th>
                  <th>模型</th>
                  <th>密钥</th>
                  <th>状态</th>
                  <th class="text-right">操作</th>
                </tr>
              </thead>
              <tbody>
                <For each={providers()}>
                  {(p) => (
                    <tr>
                      <td class="font-mono text-sm">{p.name}</td>
                      <td class="max-w-xs truncate text-sm text-base-content/70">{p.endpoint}</td>
                      <td class="text-sm">{p.models || '-'}</td>
                      <td>
                        <span class={`badge badge-sm ${p.has_keys ? 'badge-success' : 'badge-error'}`}>
                          {p.has_keys ? '已配置' : '缺失'}
                        </span>
                      </td>
                      <td>
                        <span class={`badge badge-sm ${p.enabled ? 'badge-primary' : 'badge-ghost'}`}>
                          {p.enabled ? '启用' : '停用'}
                        </span>
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-1">
                          <button type="button" class="btn btn-outline btn-xs" disabled={checkingId() === p.id} onClick={() => onCheckProvider(p)}>
                            {checkingId() === p.id ? '测试中…' : '测试'}
                          </button>
                          <button type="button" class="btn btn-outline btn-xs" onClick={() => openEdit(p)}>
                            编辑
                          </button>
                          <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onRemoveProvider(p)}>
                            删除
                          </button>
                        </div>
                      </td>
                    </tr>
                  )}
                </For>
                <Show when={providers().length === 0}>
                  <tr>
                    <td colspan={6} class="py-8 text-center text-base-content/50">
                      暂无 Provider。配置一个 OpenAI 兼容端点(需设置 ZASDOOR_AI_KEY_SECRET)
                    </td>
                  </tr>
                </Show>
              </tbody>
            </table>
          </div>
        </div>
        <Show when={checkResult()}>
          {(r) => (
            <div role="alert" class={`alert py-2 text-sm ${r().ok ? 'alert-success' : 'alert-error'}`}>
              Provider #{r().id}: {r().msg}
            </div>
          )}
        </Show>
      </Show>

      <Show when={tab() === 'approvals'}>
        <div class="overflow-x-auto rounded-lg border border-base-300">
          <table class="table">
            <thead>
              <tr>
                <th>ID</th>
                <th>技能</th>
                <th>参数</th>
                <th>请求者</th>
                <th>状态</th>
                <th>时间</th>
                <th class="text-right">操作</th>
              </tr>
            </thead>
            <tbody>
              <For each={approvals()}>
                {(a) => (
                  <tr>
                    <td class="font-mono text-xs">{a.id}</td>
                    <td class="font-mono text-xs">{a.skill_name}</td>
                    <td class="max-w-xs truncate font-mono text-xs text-base-content/70">{a.args}</td>
                    <td class="text-sm">{a.requested_by}</td>
                    <td>
                      <span class={`badge badge-sm ${a.status === 'pending' ? 'badge-warning' : a.status === 'approved' ? 'badge-success' : 'badge-ghost'}`}>
                        {a.status === 'pending' ? '待审批' : a.status === 'approved' ? '已批准' : '已拒绝'}
                      </span>
                    </td>
                    <td class="text-sm text-base-content/70">{formatDateTime(a.created_at)}</td>
                    <td class="text-right">
                      <div class="flex justify-end gap-1">
                        <button type="button" class="btn btn-success btn-xs" disabled={a.status !== 'pending'} onClick={() => onResolve(a, 'approve')}>
                          批准
                        </button>
                        <button type="button" class="btn btn-error btn-xs" disabled={a.status !== 'pending'} onClick={() => onResolve(a, 'reject')}>
                          拒绝
                        </button>
                      </div>
                    </td>
                  </tr>
                )}
              </For>
              <Show when={approvals().length === 0}>
                <tr>
                  <td colspan={7} class="py-8 text-center text-base-content/50">
                    暂无待审批事项
                  </td>
                </tr>
              </Show>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={tab() === 'runs'}>
        <div class="overflow-x-auto rounded-lg border border-base-300">
          <table class="table">
            <thead>
              <tr>
                <th>ID</th>
                <th>用户</th>
                <th>类型</th>
                <th>模型</th>
                <th>提示词</th>
                <th>用量</th>
                <th>状态</th>
                <th>时间</th>
              </tr>
            </thead>
            <tbody>
              <For each={runs()}>
                {(r) => (
                  <tr>
                    <td class="font-mono text-xs">{r.id}</td>
                    <td class="font-mono text-xs">{r.user_id}</td>
                    <td class="text-sm">{r.kind}</td>
                    <td class="font-mono text-xs text-base-content/70">{r.model || '-'}</td>
                    <td class="max-w-xs truncate text-sm text-base-content/70">{r.prompt}</td>
                    <td class="text-xs text-base-content/70">
                      {r.tokens_in > 0 || r.tokens_out > 0 ? `${r.tokens_in}→${r.tokens_out} tok` : '—'}
                      {r.steps > 0 || r.tool_calls > 0 ? ` · ${r.steps}步/${r.tool_calls}工具${r.tool_errors > 0 ? `/${r.tool_errors}错` : ''}` : ''}
                    </td>
                    <td>
                      <span class={`badge badge-sm ${r.status === 'ok' ? 'badge-success' : 'badge-warning'}`}>{r.status}</span>
                    </td>
                    <td class="text-sm text-base-content/70">{formatDateTime(r.created_at)}</td>
                  </tr>
                )}
              </For>
              <Show when={runs().length === 0}>
                <tr>
                  <td colspan={8} class="py-8 text-center text-base-content/50">
                    暂无运行记录
                  </td>
                </tr>
              </Show>
            </tbody>
          </table>
        </div>
      </Show>

      <Show when={tab() === 'workflow'}>
        <div class="space-y-3">
          <div class="flex items-center justify-between">
            <p class="text-sm text-base-content/60">
              演示工作流:依次执行「任务统计」→「租户列表」两个只读技能并汇总结果。
            </p>
            <button type="button" class="btn btn-primary btn-sm" disabled={wfBusy()} onClick={() => void onRunWorkflow()}>
              {wfBusy() ? '运行中…' : '运行工作流'}
            </button>
          </div>
          <Show when={workflow()}>
            {(wf) => (
              <div class="space-y-2">
                <div>
                  状态:
                  <span class="badge badge-sm badge-ghost ml-2">{wf().status}</span>
                </div>
                <For each={wf().steps}>
                  {(s) => (
                    <div class="rounded-lg border border-base-300 p-3">
                      <div class="flex items-center justify-between">
                        <span class="font-mono text-sm">{s.name}</span>
                        <span class="badge badge-sm badge-ghost">{s.status}</span>
                      </div>
                      <pre class="mt-2 overflow-x-auto rounded bg-base-200 p-2 text-xs whitespace-pre-wrap">
                        {s.output}
                      </pre>
                    </div>
                  )}
                </For>
              </div>
            )}
          </Show>
        </div>
      </Show>

      <Show when={formOpen()}>
        <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div class="w-full max-w-lg rounded-lg border border-base-300 bg-base-100 p-5 shadow-xl">
            <div class="mb-4 flex items-center justify-between">
              <h3 class="text-lg font-semibold">{editing() ? '编辑 Provider' : '新建 Provider'}</h3>
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setFormOpen(false)} aria-label="关闭">
                ✕
              </button>
            </div>

            <label class="block text-sm font-medium text-base-content/70">名称(唯一)</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full" value={name()} onInput={(e) => setName(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">端点(OpenAI 兼容)</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full font-mono" placeholder="https://api.openai.com/v1/chat/completions" value={endpoint()} onInput={(e) => setEndpoint(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">
              API 密钥(JSON 数组,如 [{'"'}sk-abc{'"'}]);编辑留空则保持原密钥
            </label>
            <input type="password" class="input input-bordered input-sm mt-1 w-full font-mono" value={apiKeys()} onInput={(e) => setApiKeys(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">模型(逗号分隔)</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full" placeholder="gpt-4o-mini,deepseek-v4-flash" value={models()} onInput={(e) => setModels(e.currentTarget.value)} />

            <label class="mt-3 flex items-center gap-2 text-sm">
              <input type="checkbox" class="checkbox checkbox-sm" checked={enabled()} onChange={(e) => setEnabled(e.currentTarget.checked)} />
              启用
            </label>

            <div class="mt-5 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setFormOpen(false)}>
                取消
              </button>
              <button type="button" class="btn btn-primary btn-sm" onClick={() => void onSaveProvider()}>
                保存
              </button>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
}

export default AiAdmin;

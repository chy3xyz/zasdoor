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
import { useI18n } from '#ui/i18n';
import { formatDateTime } from '#ui/utils';

type Tab = 'providers' | 'approvals' | 'runs' | 'workflow';

function AiAdmin() {
  const { t: tr } = useI18n();
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
      toast.show(tr('ai.nameEndpointRequired'), 'error');
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
    if (!window.confirm(tr('ai.confirmDelete', { name: p.name }))) return;
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
      setCheckResult({ id: p.id, ok: true, msg: tr('ai.connectionOk') });
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
          <h2 class="text-xl font-semibold">{tr('ai.title')}</h2>
          <p class="text-sm text-base-content/60">{tr('ai.subtitle')}</p>
        </div>
        <div class="tabs tabs-boxed">
          <button type="button" class={`tab tab-sm ${tab() === 'providers' ? 'tab-active' : ''}`} onClick={() => switchTab('providers')}>
            Provider
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'approvals' ? 'tab-active' : ''}`} onClick={() => switchTab('approvals')}>
            {tr('ai.approvals')}
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'runs' ? 'tab-active' : ''}`} onClick={() => switchTab('runs')}>
            {tr('ai.runs')}
          </button>
          <button type="button" class={`tab tab-sm ${tab() === 'workflow' ? 'tab-active' : ''}`} onClick={() => switchTab('workflow')}>
            {tr('ai.workflows')}
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
              {tr('ai.newProvider')}
            </button>
          </div>
          <div class="overflow-x-auto rounded-lg border border-base-300">
            <table class="table">
              <thead>
                <tr>
                  <th>{tr('common.name')}</th>
                  <th>{tr('ai.endpoint')}</th>
                  <th>{tr('ai.model')}</th>
                  <th>{tr('ai.secret')}</th>
                  <th>{tr('common.status')}</th>
                  <th class="text-right">{tr('common.actions')}</th>
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
                          {p.has_keys ? tr('ai.configured') : tr('ai.missing')}
                        </span>
                      </td>
                      <td>
                        <span class={`badge badge-sm ${p.enabled ? 'badge-primary' : 'badge-ghost'}`}>
                          {p.enabled ? tr('common.enabled') : tr('common.disabled')}
                        </span>
                      </td>
                      <td class="text-right">
                        <div class="flex justify-end gap-1">
                          <button type="button" class="btn btn-outline btn-xs" disabled={checkingId() === p.id} onClick={() => onCheckProvider(p)}>
                            {checkingId() === p.id ? tr('ai.testing') : tr('ai.test')}
                          </button>
                          <button type="button" class="btn btn-outline btn-xs" onClick={() => openEdit(p)}>
                            {tr('common.edit')}
                          </button>
                          <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onRemoveProvider(p)}>
                            {tr('common.delete')}
                          </button>
                        </div>
                      </td>
                    </tr>
                  )}
                </For>
                <Show when={providers().length === 0}>
                  <tr>
                    <td colspan={6} class="py-8 text-center text-base-content/50">
                      {tr('ai.noProviders')}
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
                <th>{tr('ai.skill')}</th>
                <th>{tr('ai.params')}</th>
                <th>{tr('ai.requester')}</th>
                <th>{tr('common.status')}</th>
                <th>{tr('common.time')}</th>
                <th class="text-right">{tr('common.actions')}</th>
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
                        {a.status === 'pending' ? tr('ai.approval.pending') : a.status === 'approved' ? tr('ai.approval.approved') : tr('ai.approval.rejected')}
                      </span>
                    </td>
                    <td class="text-sm text-base-content/70">{formatDateTime(a.created_at)}</td>
                    <td class="text-right">
                      <div class="flex justify-end gap-1">
                        <button type="button" class="btn btn-success btn-xs" disabled={a.status !== 'pending'} onClick={() => onResolve(a, 'approve')}>
                          {tr('ai.approve')}
                        </button>
                        <button type="button" class="btn btn-error btn-xs" disabled={a.status !== 'pending'} onClick={() => onResolve(a, 'reject')}>
                          {tr('ai.reject')}
                        </button>
                      </div>
                    </td>
                  </tr>
                )}
              </For>
              <Show when={approvals().length === 0}>
                <tr>
                  <td colspan={7} class="py-8 text-center text-base-content/50">
                    {tr('ai.noApprovals')}
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
                <th>{tr('ai.user')}</th>
                <th>{tr('common.type')}</th>
                <th>{tr('ai.model')}</th>
                <th>{tr('ai.prompt')}</th>
                <th>{tr('ai.usage')}</th>
                <th>{tr('common.status')}</th>
                <th>{tr('common.time')}</th>
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
                      {r.steps > 0 || r.tool_calls > 0 ? ` · ${r.steps}${tr('ai.steps')}/${r.tool_calls}${tr('ai.tools')}${r.tool_errors > 0 ? `/${r.tool_errors}${tr('ai.errors')}` : ''}` : ''}
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
                    {tr('ai.noRuns')}
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
              {tr('ai.workflowDemo')}
            </p>
            <button type="button" class="btn btn-primary btn-sm" disabled={wfBusy()} onClick={() => void onRunWorkflow()}>
              {wfBusy() ? tr('ai.running') : tr('ai.runWorkflow')}
            </button>
          </div>
          <Show when={workflow()}>
            {(wf) => (
              <div class="space-y-2">
                <div>
                  {tr('ai.status')}
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
              <h3 class="text-lg font-semibold">{editing() ? tr('ai.editProvider') : tr('ai.newProvider')}</h3>
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setFormOpen(false)} aria-label={tr('mail.close')}>
                ✕
              </button>
            </div>

            <label class="block text-sm font-medium text-base-content/70">{tr('ai.nameUnique')}</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full" value={name()} onInput={(e) => setName(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">{tr('ai.endpointOpenai')}</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full font-mono" placeholder="https://api.openai.com/v1/chat/completions" value={endpoint()} onInput={(e) => setEndpoint(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">
              {tr('ai.apiKeys')}
            </label>
            <input type="password" class="input input-bordered input-sm mt-1 w-full font-mono" value={apiKeys()} onInput={(e) => setApiKeys(e.currentTarget.value)} />

            <label class="mt-3 block text-sm font-medium text-base-content/70">{tr('ai.models')}</label>
            <input type="text" class="input input-bordered input-sm mt-1 w-full" placeholder="gpt-4o-mini,deepseek-v4-flash" value={models()} onInput={(e) => setModels(e.currentTarget.value)} />

            <label class="mt-3 flex items-center gap-2 text-sm">
              <input type="checkbox" class="checkbox checkbox-sm" checked={enabled()} onChange={(e) => setEnabled(e.currentTarget.checked)} />
              {tr('common.enabled')}
            </label>

            <div class="mt-5 flex justify-end gap-2">
              <button type="button" class="btn btn-ghost btn-sm" onClick={() => setFormOpen(false)}>
                {tr('common.cancel')}
              </button>
              <button type="button" class="btn btn-primary btn-sm" onClick={() => void onSaveProvider()}>
                {tr('common.save')}
              </button>
            </div>
          </div>
        </div>
      </Show>
    </div>
  );
}

export default AiAdmin;
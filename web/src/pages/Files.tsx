import { For, Show, createMemo, createSignal, onMount } from 'solid-js';

import {
  deleteFile,
  downloadFile,
  listFiles,
  toApiError,
  uploadFile,
  type FileItem,
} from '#ui/api';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function Files() {
  const [files, setFiles] = createSignal<FileItem[]>([]);
  const [total, setTotal] = createSignal(0);
  const [page, setPage] = createSignal(1);
  const [loading, setLoading] = createSignal(false);
  const [uploading, setUploading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);
  const [success, setSuccess] = createSignal<string | null>(null);

  const totalPages = createMemo(() => Math.max(1, Math.ceil(total() / PAGE_SIZE)));
  let requestSeq = 0;

  const load = async (targetPage = page()) => {
    const seq = ++requestSeq;
    setLoading(true);
    setError(null);
    try {
      const result = await listFiles(targetPage, PAGE_SIZE);
      if (seq !== requestSeq) return;
      setFiles(result.list);
      setTotal(result.total);
      setPage(result.page);
    } catch (err) {
      if (seq !== requestSeq) return;
      setError(toApiError(err).message);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  };

  onMount(() => void load(1));

  const onUpload = async (e: Event) => {
    const input = e.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    setUploading(true);
    setError(null);
    setSuccess(null);
    try {
      await uploadFile(file);
      setSuccess(`「${file.name}」上传成功`);
      input.value = '';
      void load(1);
    } catch (err) {
      setError(toApiError(err).message);
    } finally {
      setUploading(false);
    }
  };

  const onDelete = async (file: FileItem) => {
    if (!window.confirm(`确定删除「${file.name}」吗？此操作不可恢复。`)) return;
    try {
      await deleteFile(file.id);
      void load();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">文件管理</h2>
          <p class="text-sm text-base-content/60">共 {total()} 个文件</p>
        </div>
        <label class="btn btn-primary btn-sm">
          {uploading() ? '上传中…' : '上传文件'}
          <input type="file" class="hidden" disabled={uploading()} onChange={onUpload} />
        </label>
      </div>

      <Show when={error()}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {error()}
        </div>
      </Show>
      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">
          {success()}
        </div>
      </Show>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>ID</th>
              <th>文件名</th>
              <th>类型</th>
              <th>大小</th>
              <th>上传时间</th>
              <th class="text-right">操作</th>
            </tr>
          </thead>
          <tbody>
            <Show when={files().length === 0 && !loading()}>
              <tr>
                <td colspan={6} class="py-10 text-center text-base-content/50">
                  暂无文件
                </td>
              </tr>
            </Show>
            <For each={files()}>
              {(file) => (
                <tr>
                  <td class="font-mono text-xs">{file.id}</td>
                  <td class="max-w-xs truncate">{file.name}</td>
                  <td class="font-mono text-xs">{file.mime}</td>
                  <td class="text-sm">{formatSize(file.size_bytes)}</td>
                  <td class="text-sm text-base-content/70">{formatDateTime(file.created_at)}</td>
                  <td class="text-right">
                    <div class="flex justify-end gap-1">
                      <button
                        type="button"
                        class="btn btn-ghost btn-xs"
                        onClick={() => {
                          downloadFile(file.id, file.name).catch((err) => window.alert(toApiError(err).message));
                        }}
                      >
                        下载
                      </button>
                      <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(file)}>
                        删除
                      </button>
                    </div>
                  </td>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between">
        <span class="text-sm text-base-content/60">
          第 {page()} / {totalPages()} 页
        </span>
        <div class="join">
          <button type="button" class="btn btn-sm join-item" disabled={page() <= 1 || loading()} onClick={() => void load(page() - 1)}>
            上一页
          </button>
          <button type="button" class="btn btn-sm join-item" disabled={page() >= totalPages() || loading()} onClick={() => void load(page() + 1)}>
            下一页
          </button>
        </div>
      </div>
    </div>
  );
}

export default Files;

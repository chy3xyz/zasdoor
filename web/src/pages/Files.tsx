import { Show, createSignal } from 'solid-js';

import { deleteFile, downloadFile, listFiles, toApiError, uploadFile, type FileItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function Files() {
  const [uploading, setUploading] = createSignal(false);
  const [success, setSuccess] = createSignal<string | null>(null);

  const paged = usePaged<FileItem>((page, pageSize) => listFiles(page, pageSize), PAGE_SIZE);

  const onUpload = async (e: Event) => {
    const input = e.currentTarget as HTMLInputElement;
    const file = input.files?.[0];
    if (!file) return;
    setUploading(true);
    setSuccess(null);
    try {
      await uploadFile(file);
      setSuccess(`「${file.name}」上传成功`);
      input.value = '';
      void paged.reload(1);
    } catch (err) {
      window.alert(toApiError(err).message);
    } finally {
      setUploading(false);
    }
  };

  const onDelete = async (file: FileItem) => {
    if (!window.confirm(`确定删除「${file.name}」吗？此操作不可恢复。`)) return;
    try {
      await deleteFile(file.id);
      void paged.reload();
    } catch (err) {
      window.alert(toApiError(err).message);
    }
  };

  const columns: Column<FileItem>[] = [
    { key: 'id', title: 'ID', render: (f) => <span class="font-mono text-xs">{f.id}</span> },
    { key: 'name', title: '文件名', render: (f) => <span class="max-w-xs truncate">{f.name}</span> },
    { key: 'mime', title: '类型', render: (f) => <span class="font-mono text-xs">{f.mime}</span> },
    { key: 'size_bytes', title: '大小', render: (f) => <span class="text-sm">{formatSize(f.size_bytes)}</span> },
    {
      key: 'created_at',
      title: '上传时间',
      render: (f) => <span class="text-sm text-base-content/70">{formatDateTime(f.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">文件管理</h2>
          <p class="text-sm text-base-content/60">共 {paged.total()} 个文件</p>
        </div>
        <label class="btn btn-primary btn-sm">
          {uploading() ? '上传中…' : '上传文件'}
          <input type="file" class="hidden" disabled={uploading()} onChange={onUpload} />
        </label>
      </div>

      <Show when={success()}>
        <div role="alert" class="alert alert-success py-2 text-sm">
          {success()}
        </div>
      </Show>

      <DataTable
        columns={columns}
        rows={paged.items()}
        rowKey={(f) => f.id}
        total={paged.total()}
        page={paged.page()}
        totalPages={paged.totalPages()}
        loading={paged.loading()}
        error={paged.error()}
        emptyText="暂无文件"
        onPageChange={(p) => void paged.reload(p)}
        actions={(file) => (
          <>
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
          </>
        )}
      />
    </div>
  );
}

export default Files;

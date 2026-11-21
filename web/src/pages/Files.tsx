import { Show, createSignal } from 'solid-js';
import { useToast } from '#ui/components';

import { deleteFile, downloadFile, listFiles, toApiError, uploadFile, type FileItem } from '#ui/api';
import DataTable, { type Column } from '#ui/components/DataTable';
import { useI18n } from '#ui/i18n';
import { usePaged } from '#ui/hooks/usePaged';
import { formatDateTime } from '#ui/utils';

const PAGE_SIZE = 20;

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function Files() {
  const { t } = useI18n();
  const toast = useToast();
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
      setSuccess(t('files.uploaded', { name: file.name }));
      input.value = '';
      void paged.reload(1);
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    } finally {
      setUploading(false);
    }
  };

  const onDelete = async (file: FileItem) => {
    if (!window.confirm(t('files.confirmDelete', { name: file.name }))) return;
    try {
      await deleteFile(file.id);
      void paged.reload();
    } catch (err) {
      toast.show(toApiError(err).message, 'error');
    }
  };

  const columns: Column<FileItem>[] = [
    { key: 'id', title: 'ID', render: (f) => <span class="font-mono text-xs">{f.id}</span> },
    { key: 'name', title: t('files.column.fileName'), render: (f) => <span class="max-w-xs truncate">{f.name}</span> },
    { key: 'mime', title: t('common.type'), render: (f) => <span class="font-mono text-xs">{f.mime}</span> },
    { key: 'size_bytes', title: t('files.column.size'), render: (f) => <span class="text-sm">{formatSize(f.size_bytes)}</span> },
    {
      key: 'created_at',
      title: t('files.column.uploadedAt'),
      render: (f) => <span class="text-sm text-base-content/70">{formatDateTime(f.created_at)}</span>,
    },
  ];

  return (
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <h2 class="text-xl font-semibold">{t('files.title')}</h2>
          <p class="text-sm text-base-content/60">{t('files.count', { count: paged.total() })}</p>
        </div>
        <label class="btn btn-primary btn-sm">
          {uploading() ? t('files.uploading') : t('files.upload')}
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
        emptyText={t('files.empty')}
        onPageChange={(p) => void paged.reload(p)}
        actions={(file) => (
          <>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              onClick={() => {
                downloadFile(file.id, file.name).catch((err) => toast.show(toApiError(err).message));
              }}
            >
              {t('files.download')}
            </button>
            <button type="button" class="btn btn-ghost btn-xs text-error" onClick={() => onDelete(file)}>
              {t('common.delete')}
            </button>
          </>
        )}
      />
    </div>
  );
}

export default Files;
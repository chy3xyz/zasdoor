import { For, Show, type JSX } from 'solid-js';

export interface Column<T> {
  key: string;
  title: string;
  render: (row: T) => JSX.Element;
  class?: string;
  headerClass?: string;
}

interface DataTableProps<T> {
  columns: Column<T>[];
  rows: T[];
  rowKey: (row: T) => string | number;
  total: number;
  page: number;
  totalPages: number;
  loading: boolean;
  error: string | null;
  emptyText?: string;
  onPageChange: (page: number) => void;
  actions?: (row: T) => JSX.Element;
  actionsTitle?: string;
}

/**
 * Data-driven table (zmsaas-style): columns config + rows + pagination state
 * from `usePaged`, with shared loading/empty/error rendering.
 */
export default function DataTable<T>(props: DataTableProps<T>) {
  const columnCount = () => props.columns.length + (props.actions ? 1 : 0);

  return (
    <div class="space-y-4">
      <Show when={props.error}>
        <div role="alert" class="alert alert-error py-2 text-sm">
          {props.error}
        </div>
      </Show>

      <div class="overflow-x-auto rounded-lg border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <For each={props.columns}>
                {(col) => (
                  <th class={col.headerClass}>{col.title}</th>
                )}
              </For>
              <Show when={props.actions}>
                <th class="text-right">{props.actionsTitle ?? '操作'}</th>
              </Show>
            </tr>
          </thead>
          <tbody>
            <Show when={props.rows.length === 0 && !props.loading}>
              <tr>
                <td colspan={columnCount()} class="py-10 text-center text-base-content/50">
                  {props.emptyText ?? '暂无数据'}
                </td>
              </tr>
            </Show>
            <For each={props.rows}>
              {(row) => (
                <tr>
                  <For each={props.columns}>
                    {(col) => <td class={col.class}>{col.render(row)}</td>}
                  </For>
                  <Show when={props.actions}>
                    <td class="text-right">
                      <div class="flex justify-end gap-1">{props.actions!(row)}</div>
                    </td>
                  </Show>
                </tr>
              )}
            </For>
          </tbody>
        </table>
      </div>

      <div class="flex items-center justify-between">
        <span class="text-sm text-base-content/60">
          第 {props.page} / {props.totalPages} 页 · 共 {props.total} 条
        </span>
        <div class="join">
          <button
            type="button"
            class="btn btn-sm join-item"
            disabled={props.page <= 1 || props.loading}
            onClick={() => props.onPageChange(props.page - 1)}
          >
            上一页
          </button>
          <button
            type="button"
            class="btn btn-sm join-item"
            disabled={props.page >= props.totalPages || props.loading}
            onClick={() => props.onPageChange(props.page + 1)}
          >
            下一页
          </button>
        </div>
      </div>
    </div>
  );
}

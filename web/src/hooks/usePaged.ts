import { createMemo, createSignal } from 'solid-js';

import { toApiError } from '#ui/api';

export interface PagedPayload<T> {
  list: T[];
  total: number;
  page: number;
}

/**
 * Data-driven pagination state (zmsaas-style convergence): one hook owns
 * items/total/page/loading/error plus a monotonic request guard so rapid
 * search or pagination cannot interleave out-of-order responses.
 */
export function usePaged<T>(
  loader: (page: number, pageSize: number) => Promise<PagedPayload<T>>,
  pageSize = 20,
) {
  const [items, setItems] = createSignal<T[]>([]);
  const [total, setTotal] = createSignal(0);
  const [page, setPage] = createSignal(1);
  const [loading, setLoading] = createSignal(false);
  const [error, setError] = createSignal<string | null>(null);

  const totalPages = createMemo(() => Math.max(1, Math.ceil(total() / pageSize)));
  let requestSeq = 0;

  const reload = async (targetPage = page()) => {
    const seq = ++requestSeq;
    setLoading(true);
    setError(null);
    try {
      const result = await loader(targetPage, pageSize);
      if (seq !== requestSeq) return;
      setItems(result.list);
      setTotal(result.total);
      setPage(result.page);
    } catch (err) {
      if (seq !== requestSeq) return;
      setError(toApiError(err).message);
    } finally {
      if (seq === requestSeq) setLoading(false);
    }
  };

  return {
    items,
    total,
    page,
    totalPages,
    loading,
    error,
    reload,
    setPage,
  };
}

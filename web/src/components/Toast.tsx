import { createContext, createSignal, For, useContext, type JSX } from 'solid-js';

type ToastType = 'info' | 'success' | 'error';

interface ToastItem {
  id: number;
  msg: string;
  type: ToastType;
}

export interface ToastApi {
  show: (msg: string, type?: ToastType) => void;
}

const ToastCtx = createContext<ToastApi | undefined>(undefined);

/** 全局 toast 容器 + Provider。挂在应用根部;页面用 useToast() 取实例。 */
export function ToastProvider(props: { children?: JSX.Element }) {
  const [toasts, setToasts] = createSignal<ToastItem[]>([]);

  const show = (msg: string, type: ToastType = 'info') => {
    const id = Date.now() + Math.floor(Math.random() * 1000);
    setToasts((t) => [...t, { id, msg, type }]);
    window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== id)), 3500);
  };

  const icon = (t: ToastType) => (t === 'error' ? '✕' : t === 'success' ? '✓' : 'ℹ');

  return (
    <ToastCtx.Provider value={{ show }}>
      {props.children}
      <div class="toast toast-end toast-top z-[100] space-y-2">
        <For each={toasts()}>
          {(t) => (
            <div
              role="alert"
              class={`alert py-2 text-sm shadow-lg ${
                t.type === 'error' ? 'alert-error' : t.type === 'success' ? 'alert-success' : 'alert-info'
              }`}
            >
              <span>
                {icon(t.type)} {t.msg}
              </span>
            </div>
          )}
        </For>
      </div>
    </ToastCtx.Provider>
  );
}

export function useToast(): ToastApi {
  const ctx = useContext(ToastCtx);
  if (!ctx) throw new Error('useToast must be used within <ToastProvider>');
  return ctx;
}

import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { getSiweNonce } from '#ui/api';
import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';

interface EthereumProvider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
}

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}

function SignIn() {
  const [auth, actions] = useAuth();
  const [email, setEmail] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [submitting, setSubmitting] = createSignal(false);
  const [walletBusy, setWalletBusy] = createSignal(false);
  const [walletError, setWalletError] = createSignal<string | null>(null);

  const onSubmit = async (e: SubmitEvent) => {
    e.preventDefault();
    if (submitting()) return;
    setSubmitting(true);
    try {
      await actions.login(email().trim(), password());
    } catch {
      // error is stored in auth.error
    } finally {
      setSubmitting(false);
    }
  };

  const onWalletSignIn = async () => {
    setWalletError(null);
    const provider = window.ethereum;
    if (!provider) {
      setWalletError('未检测到钱包扩展（如 MetaMask），请先安装后重试。');
      return;
    }
    setWalletBusy(true);
    try {
      // 1. Address from the injected provider.
      const accounts = (await provider.request({ method: 'eth_requestAccounts' })) as string[];
      const address = accounts[0] ?? '';
      if (!address) throw new Error('钱包未返回地址');
      // 2. Server-issued single-use nonce.
      const domain = window.location.hostname || 'localhost';
      const { nonce } = await getSiweNonce({ address, domain });
      // 3. EIP-4361 message.
      const issuedAt = new Date().toISOString();
      const message =
        `${domain} wants you to sign in with your Ethereum account:\n${address}\n\n` +
        `Sign in to Zasdoor with your wallet.\n\n` +
        `URI: ${window.location.origin}\nVersion: 1\nChain ID: 1\nNonce: ${nonce}\nIssued At: ${issuedAt}`;
      // 4. personal_sign (EIP-191); strip the 0x prefix (backend wants r‖s‖v hex).
      const raw = (await provider.request({
        method: 'personal_sign',
        params: [message, address],
      })) as string;
      const signature = raw.startsWith('0x') ? raw.slice(2) : raw;
      // 5. Verify server-side; binds session or reports unbound wallet.
      await actions.siweLogin(message, signature, domain);
    } catch (err) {
      setWalletError(err instanceof Error ? err.message : '钱包登录失败，请重试');
    } finally {
      setWalletBusy(false);
    }
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">登录</h2>
        <p class="text-sm text-base-content/60">使用你的邮箱和密码登录管理后台</p>

        <Show when={auth.error}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {auth.error}
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">邮箱</span>
            <input
              type="email"
              class="input input-bordered w-full"
              placeholder="you@example.com"
              value={email()}
              onInput={(e) => setEmail(e.currentTarget.value)}
              required
            />
          </label>
          <label class="form-control w-full">
            <span class="label-text mb-1">密码</span>
            <input
              type="password"
              class="input input-bordered w-full"
              placeholder="••••••••"
              value={password()}
              onInput={(e) => setPassword(e.currentTarget.value)}
              required
            />
          </label>
          <button
            type="submit"
            class="btn btn-primary w-full"
            disabled={submitting()}
          >
            {submitting() ? '登录中…' : '登录'}
          </button>
        </form>

        <div class="divider my-2 text-xs text-base-content/50">或</div>

        <Show when={walletError()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {walletError()}
          </div>
        </Show>
        <button
          type="button"
          class="btn btn-outline w-full"
          disabled={walletBusy()}
          onClick={onWalletSignIn}
        >
          {walletBusy() ? '钱包签名中…' : '使用钱包登录 (SIWE)'}
        </button>

        <div class="mt-4 flex items-center justify-between text-sm">
          <A href={ROUTE_PATH.forgotPassword} class="link link-primary">
            忘记密码？
          </A>
          <span class="text-base-content/60">
            还没有账号？{' '}
            <A href={ROUTE_PATH.signUp} class="link link-primary">
              注册
            </A>
          </span>
        </div>
      </div>
    </div>
  );
}

export default SignIn;

import { A } from '@solidjs/router';
import { createSignal, Show } from 'solid-js';

import { beginPasskeyLogin, getSiweNonce } from '#ui/api';
import { ROUTE_PATH } from '#ui/constants';
import { useAuth } from '#ui/hooks';
import { useI18n } from '#ui/i18n';
import { decodeRequestOptions, isWebAuthnSupported, passkeyErrorMessage } from '#ui/utils';

interface EthereumProvider {
  request: (args: { method: string; params?: unknown[] }) => Promise<unknown>;
}

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}

function SignIn() {
  const { t } = useI18n();
  const [auth, actions] = useAuth();
  const [email, setEmail] = createSignal('');
  const [password, setPassword] = createSignal('');
  const [submitting, setSubmitting] = createSignal(false);
  const [walletBusy, setWalletBusy] = createSignal(false);
  const [walletError, setWalletError] = createSignal<string | null>(null);
  const [passkeyBusy, setPasskeyBusy] = createSignal(false);
  const [passkeyError, setPasskeyError] = createSignal<string | null>(null);

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
      setWalletError(t('auth.signIn.wallet.notFound'));
      return;
    }
    setWalletBusy(true);
    try {
      // 1. Address from the injected provider.
      const accounts = (await provider.request({ method: 'eth_requestAccounts' })) as string[];
      const address = accounts[0] ?? '';
      if (!address) throw new Error(t('auth.signIn.wallet.noAddress'));
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
      setWalletError(err instanceof Error ? err.message : t('auth.signIn.wallet.failed'));
    } finally {
      setWalletBusy(false);
    }
  };

  const onPasskeySignIn = async () => {
    actions.clearError();
    setPasskeyError(null);
    const mail = email().trim();
    if (!mail) {
      setPasskeyError(t('auth.signIn.passkey.emailRequired'));
      return;
    }
    if (!isWebAuthnSupported()) {
      setPasskeyError(t('auth.signIn.passkey.unsupported'));
      return;
    }
    setPasskeyBusy(true);
    let credential: PublicKeyCredential | null = null;
    try {
      // 1. Server-issued challenge + allowCredentials (raw options, b64url).
      const options = await beginPasskeyLogin(mail);
      // 2. Browser ceremony: fingerprint / face / device PIN.
      credential = (await navigator.credentials.get({
        publicKey: decodeRequestOptions(options),
      })) as PublicKeyCredential | null;
      if (!credential) throw new Error(t('auth.signIn.passkey.noCredential'));
    } catch (err) {
      setPasskeyError(passkeyErrorMessage(err));
      setPasskeyBusy(false);
      return;
    }
    try {
      // 3. Verify server-side and persist the session through the auth
      // provider, so success behaves exactly like a password login.
      await actions.passkeyLogin(mail, credential);
    } catch {
      // auth.error already carries the server's envelope message.
    } finally {
      setPasskeyBusy(false);
    }
  };

  return (
    <div class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-2xl">{t('auth.signIn.title')}</h2>
        <p class="text-sm text-base-content/60">{t('auth.signIn.subtitle')}</p>

        <Show when={auth.error}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {auth.error}
          </div>
        </Show>

        <form onSubmit={onSubmit} class="mt-2 space-y-4">
          <label class="form-control w-full">
            <span class="label-text mb-1">{t('auth.signIn.email')}</span>
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
            <span class="label-text mb-1">{t('auth.signIn.password')}</span>
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
            {submitting() ? t('auth.signIn.submitting') : t('auth.signIn.submit')}
          </button>
        </form>

        <div class="divider my-2 text-xs text-base-content/50">{t('auth.signIn.or')}</div>

        <Show when={passkeyError()}>
          <div role="alert" class="alert alert-error py-2 text-sm">
            {passkeyError()}
          </div>
        </Show>
        <button
          type="button"
          class="btn btn-outline w-full"
          disabled={passkeyBusy()}
          onClick={onPasskeySignIn}
        >
          {passkeyBusy() ? t('auth.signIn.passkey.submitting') : t('auth.signIn.passkey.submit')}
        </button>
        <p class="mt-1 text-xs text-base-content/50">
          {t('auth.signIn.passkey.hint')}
        </p>

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
          {walletBusy() ? t('auth.signIn.wallet.submitting') : t('auth.signIn.wallet.submit')}
        </button>

        <div class="mt-4 flex items-center justify-between text-sm">
          <A href={ROUTE_PATH.forgotPassword} class="link link-primary">
            {t('auth.signIn.forgotPassword')}
          </A>
          <span class="text-base-content/60">
            {t('auth.signIn.noAccount')}{' '}
            <A href={ROUTE_PATH.signUp} class="link link-primary">
              {t('auth.signIn.signUp')}
            </A>
          </span>
        </div>
      </div>
    </div>
  );
}

export default SignIn;
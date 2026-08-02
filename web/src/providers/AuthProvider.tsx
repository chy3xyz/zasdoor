import { useNavigate } from '@solidjs/router';
import { type JSX, onMount } from 'solid-js';
import { createStore } from 'solid-js/store';

import { type AuthUser, login as apiLogin, logout as apiLogout, register as apiRegister, setAuthToken, setUnauthorizedHandler } from '#ui/api';
import { APP_CONFIG } from '#ui/config';
import { ROUTE_PATH } from '#ui/constants';
import { AuthContext, type AuthActions, type AuthContextValue, type AuthState } from '#ui/context';

function readStoredSession(): { token: string; user: AuthUser } | null {
  try {
    const token = localStorage.getItem(APP_CONFIG.storage.token);
    const rawUser = localStorage.getItem(APP_CONFIG.storage.user);
    if (!token || !rawUser) return null;
    const user = JSON.parse(rawUser) as AuthUser;
    if (!user?.email) return null;
    return { token, user };
  } catch {
    return null;
  }
}

function persistSession(token: string, user: AuthUser) {
  localStorage.setItem(APP_CONFIG.storage.token, token);
  localStorage.setItem(APP_CONFIG.storage.user, JSON.stringify(user));
}

function clearSession() {
  localStorage.removeItem(APP_CONFIG.storage.token);
  localStorage.removeItem(APP_CONFIG.storage.user);
}

export function AuthProvider(props: JSX.HTMLAttributes<HTMLElement>) {
  const navigate = useNavigate();
  const [store, setStore] = createStore<AuthState>(AuthContext.defaultValue[0]);

  const applySession = (token: string, user: AuthUser) => {
    setAuthToken(token);
    persistSession(token, user);
    setStore({ status: 'verified', token, user, error: null });
  };

  const clearAuth = () => {
    setAuthToken(null);
    clearSession();
    setStore({ status: 'unverified', token: null, user: null, error: null });
  };

  onMount(() => {
    const session = readStoredSession();
    if (session) {
      setAuthToken(session.token);
      setStore({
        status: 'verified',
        token: session.token,
        user: session.user,
        error: null,
      });
    } else {
      setStore('status', 'unverified');
    }
    // Global 401 (expired JWT) → clear session; keep the error message out of
    // the flow since the redirect to sign-in already communicates it.
    setUnauthorizedHandler(() => clearAuth());
  });

  const actions: AuthActions = {
    async login(email, password) {
      setStore('error', null);
      try {
        const result = await apiLogin({ email, password });
        applySession(result.token, result.user);
        navigate(ROUTE_PATH.index, { replace: true });
      } catch (err) {
        setStore(
          'error',
          err instanceof Error ? err.message : '登录失败，请稍后重试',
        );
        throw err;
      }
    },
    async register(name, email, password) {
      setStore('error', null);
      try {
        const result = await apiRegister({ name, email, password });
        applySession(result.token, result.user);
        navigate(ROUTE_PATH.index, { replace: true });
      } catch (err) {
        setStore(
          'error',
          err instanceof Error ? err.message : '注册失败，请稍后重试',
        );
        throw err;
      }
    },
    async logout() {
      try {
        await apiLogout();
      } catch {
        // Always clear local session even if remote logout fails (stateless JWT).
      }
      clearAuth();
      navigate(ROUTE_PATH.signIn, { replace: true });
    },
    clearError() {
      setStore('error', null);
    },
    setCurrentUser(user) {
      const token = store.token;
      if (token) persistSession(token, user);
      setStore('user', user);
    },
  };

  const value: AuthContextValue = [store, actions];

  return <AuthContext.Provider value={value}>{props.children}</AuthContext.Provider>;
}

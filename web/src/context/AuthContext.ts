import { createContext } from 'solid-js';

import type { AuthUser } from '#ui/api';

export type AuthStatus = 'bootstrapping' | 'unverified' | 'verified';

export type AuthState = {
  status: AuthStatus;
  token: string | null;
  user: AuthUser | null;
  error: string | null;
};

export type AuthActions = {
  login: (email: string, password: string) => Promise<void>;
  register: (name: string, email: string, password: string) => Promise<void>;
  logout: () => Promise<void>;
  clearError: () => void;
  /** Update the cached user after a profile change. */
  setCurrentUser: (user: AuthUser) => void;
};

export type AuthContextValue = [AuthState, AuthActions];

export const AuthContext = createContext<AuthContextValue>([
  {
    status: 'bootstrapping',
    token: null,
    user: null,
    error: null,
  },
  {
    login: async () => {},
    register: async () => {},
    logout: async () => {},
    clearError: () => {},
    setCurrentUser: () => {},
  },
]);

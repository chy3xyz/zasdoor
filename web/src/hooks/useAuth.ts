import { useContext } from 'solid-js';

import { AuthContext, type AuthContextValue } from '#ui/context';

export function useAuth(): AuthContextValue {
  return useContext(AuthContext);
}

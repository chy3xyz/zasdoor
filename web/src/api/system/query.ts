import { http } from '#ui/api/client';
import { unwrapEnvelope } from '#ui/api/envelope';

import { SYSTEM_PATH } from './path';
import type { DashboardData } from './types';

export async function getDashboard(): Promise<DashboardData> {
  const { data } = await http.get<{ code: number; msg: string; data: DashboardData }>(SYSTEM_PATH.dashboard);
  return unwrapEnvelope(data);
}

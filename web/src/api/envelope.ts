/**
 * zasdoor JSON envelope: `{ code, msg, data }`.
 * `code === 0` means success (RuoYi-compatible).
 */
export interface ApiEnvelope<T = unknown> {
  code: number;
  msg: string;
  data: T;
}

export class ApiError extends Error {
  readonly code: number;

  constructor(code: number, msg: string) {
    super(msg || `API error ${code}`);
    this.name = 'ApiError';
    this.code = code;
  }
}

export function unwrapEnvelope<T>(envelope: ApiEnvelope<T>): T {
  if (envelope.code !== 0) {
    throw new ApiError(envelope.code, envelope.msg || 'Request failed');
  }
  return envelope.data;
}

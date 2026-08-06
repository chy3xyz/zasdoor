import { describe, expect, it } from 'vitest';

import { formatDateTime } from './format';

describe('formatDateTime', () => {
  it('formats unix seconds as local datetime', () => {
    // 2026-08-04 12:00:00 UTC 秒值
    const unix = 1783224000;
    const out = formatDateTime(unix);
    expect(out).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
  });

  it('returns "-" for falsy input', () => {
    expect(formatDateTime(0)).toBe('-');
    expect(formatDateTime(NaN)).toBe('-');
  });

  it('keeps a stable local datetime shape for any valid input', () => {
    const unix = 1767599220;
    const out = formatDateTime(unix);
    expect(out).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/);
  });
});

import { describe, expect, it, beforeEach } from 'vitest';

import { dictionaries, en, interpolate, LOCALE_STORAGE_KEY, setLocale, t, toggleLocale, zh } from './index';
import type { TranslationKey } from './zh';

// jsdom in this setup does not expose localStorage; install a minimal in-memory stub
// so locale persistence can be exercised deterministically.
const store = new Map<string, string>();
if (typeof globalThis.localStorage === 'undefined') {
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, String(v)),
      removeItem: (k: string) => void store.delete(k),
      clear: () => store.clear(),
    },
  });
}


describe('i18n dictionaries', () => {
  it('zh and en have exact key parity', () => {
    const zhKeys = Object.keys(zh).sort();
    const enKeys = Object.keys(en).sort();
    expect(enKeys).toEqual(zhKeys);
    expect(zhKeys.length).toBeGreaterThan(150);
  });

  it('every dictionary entry is a non-empty string', () => {
    for (const locale of ['zh', 'en'] as const) {
      for (const [key, value] of Object.entries(dictionaries[locale])) {
        expect(typeof value, `${locale}.${key}`).toBe('string');
        expect(value.length, `${locale}.${key}`).toBeGreaterThan(0);
      }
    }
  });

  it('both locales interpolate all placeholders used by their templates', () => {
    for (const dict of [zh, en]) {
      for (const template of Object.values(dict) as string[]) {
        for (const placeholder of template.match(/\{(\w+)\}/g) ?? []) {
          expect(interpolate(template, { [placeholder.slice(1, -1)]: 'X' })).toContain('X');
        }
      }
    }
  });
});

describe('interpolate', () => {
  it('replaces named placeholders with string and number params', () => {
    expect(interpolate('Hello {name}, you have {count} messages', { name: 'Ann', count: 3 }))
      .toBe('Hello Ann, you have 3 messages');
  });

  it('leaves unknown placeholders untouched', () => {
    expect(interpolate('Hi {name}, {missing}', { name: 'Ann' })).toBe('Hi Ann, {missing}');
  });

  it('replaces repeated placeholders', () => {
    expect(interpolate('{name} / {name}', { name: 'x' })).toBe('x / x');
  });
});

describe('locale signal + persistence', () => {
  beforeEach(() => {
    store.clear();
    setLocale('zh');
  });

  it('t() follows the active locale', () => {
    expect(t('common.save')).toBe('保存');
    setLocale('en');
    expect(t('common.save')).toBe('Save');
  });

  it('setLocale persists selection to localStorage', () => {
    setLocale('en');
    expect(localStorage.getItem(LOCALE_STORAGE_KEY)).toBe('en');
  });

  it('toggleLocale flips between zh and en', () => {
    expect(t('common.save')).toBe('保存');
    toggleLocale();
    expect(t('common.save')).toBe('Save');
    toggleLocale();
    expect(t('common.save')).toBe('保存');
  });

  it('interpolates through t() for both locales', () => {
    expect(t('common.pageInfo', { page: 2, totalPages: 5, total: 42 })).toBe('第 2 / 5 页 · 共 42 条');
    setLocale('en');
    expect(t('common.pageInfo', { page: 2, totalPages: 5, total: 42 })).toBe('Page 2 / 5 · 42 items');
  });

  it('typed keys are accepted by t()', () => {
    const key: TranslationKey = 'auth.signIn.title';
    expect(typeof t(key)).toBe('string');
  });
});
import { createSignal, type Accessor } from 'solid-js';

import { en } from './en';
import { zh, type TranslationKey } from './zh';

export type Locale = 'zh' | 'en';
export { zh, en };
export type { TranslationKey };
export type TranslateParams = Record<string, string | number>;

export const dictionaries: Record<Locale, Record<TranslationKey, string>> = { zh, en };

export const LOCALE_STORAGE_KEY = 'zasdoor.locale';

function readStoredLocale(): Locale {
  if (typeof localStorage === 'undefined') return 'zh';
  const saved = localStorage.getItem(LOCALE_STORAGE_KEY);
  return saved === 'en' || saved === 'zh' ? saved : 'zh';
}

const [locale, setLocaleSignal] = createSignal<Locale>(readStoredLocale());

export function interpolate(template: string, params?: TranslateParams): string {
  return template.replace(/\{(\w+)\}/g, (match, name: string) =>
    params && Object.prototype.hasOwnProperty.call(params, name) ? String(params[name]) : match,
  );
}

/** Reactive translator: reading locale() here makes every t() call in JSX auto-update. */
export function t(key: TranslationKey, params?: TranslateParams): string {
  return interpolate(dictionaries[locale()][key], params);
}

export function setLocale(next: Locale): void {
  setLocaleSignal(next);
  if (typeof localStorage !== 'undefined') localStorage.setItem(LOCALE_STORAGE_KEY, next);
}

export function toggleLocale(): void {
  setLocale(locale() === 'zh' ? 'en' : 'zh');
}

export interface I18nApi {
  locale: Accessor<Locale>;
  setLocale: (next: Locale) => void;
  toggleLocale: () => void;
  t: typeof t;
}

export function useI18n(): I18nApi {
  return { locale, setLocale, toggleLocale, t };
}
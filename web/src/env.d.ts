/// <reference types="@rsbuild/core/types" />

interface ImportMetaEnv {
  readonly PUBLIC_API_MODE?: string;
  readonly PUBLIC_API_BASE_URL?: string;
  readonly PUBLIC_API_PREFIX?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}

import { fileURLToPath } from 'node:url';

import { defineConfig, loadEnv } from '@rsbuild/core';
import { pluginBabel } from '@rsbuild/plugin-babel';
import { pluginSolid } from '@rsbuild/plugin-solid';

const srcDir = fileURLToPath(new URL('./src', import.meta.url));

const { publicVars } = loadEnv();

export default defineConfig({
  html: {
    title: 'Zasdoor Admin',
    lang: 'zh-CN',
  },
  source: {
    define: publicVars,
  },
  server: {
    port: 3001,
    proxy: {
      '/api': 'http://127.0.0.1:8000',
    },
  },
  resolve: {
    alias: {
      '#ui/': `${srcDir}/`,
      '#ui': srcDir,
    },
    extensions: ['.tsx', '.ts', '.jsx', '.js', '.mjs', '.json'],
  },
  plugins: [
    pluginBabel({
      include: /\.(?:jsx|tsx)$/,
    }),
    pluginSolid(),
  ],
});

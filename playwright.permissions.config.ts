import { defineConfig } from '@playwright/test';
import { resolve } from 'node:path';

const evidence = process.env.SYLULIVE_PERMISSION_EVIDENCE_DIR || resolve('test-results/permissions-evidence');

export default defineConfig({
  testDir: './astrbot_plugin_sylulive/tests/ui',
  outputDir: './test-results/permissions',
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [['list'], ['json', { outputFile: resolve(evidence, 'browser.json') }]],
  use: { baseURL: 'http://127.0.0.1:6197', headless: true, trace: 'retain-on-failure' },
});

import { defineConfig } from '@playwright/test';

export function webTestConfig(port: number) {
  const baseURL = `http://127.0.0.1:${port}/web/`;
  return defineConfig({
    testDir: '../../web/e2e',
    outputDir: '../../test-results',
    globalSetup: '../playwright-preflight.ts',
    fullyParallel: false,
    workers: 1,
    reporter: 'list',
    use: { baseURL, viewport: { width: 1440, height: 1000 } },
    webServer: {
      cwd: '../..',
      command: `pnpm --filter @sylulive/web dev --port ${port}`,
      url: baseURL,
      reuseExistingServer: true,
      env: { SYLULIVE_API_ORIGIN: 'http://127.0.0.1:8080' },
      timeout: 30000,
    },
  });
}

export default webTestConfig(5173);

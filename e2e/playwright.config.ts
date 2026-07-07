import { defineConfig, devices } from '@playwright/test';

const PORT = process.env.DASHBOARD_E2E_PORT ?? '8099';
const baseURL = `http://127.0.0.1:${PORT}`;

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  reporter: 'html',
  use: {
    baseURL,
    trace: 'on-first-retry',
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  ],
  // Boots a standalone dashboard instance (e2e/harness) seeded with sample logs.
  webServer: {
    command: 'go run -tags e2e ./harness',
    cwd: __dirname,
    env: { DASHBOARD_E2E_ADDR: `127.0.0.1:${PORT}` },
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },
});

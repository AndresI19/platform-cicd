import { defineConfig, devices } from '@playwright/test';

// The oracle drives the LIVE platform by default. Override with PLATFORM_BASE to point at a snapshot
// deploy on a different host, or a local port-forward.
const BASE = process.env.PLATFORM_BASE ?? 'https://andres.project-platform.me';

// The three front ends live under one host, plus the API host. Specs read these off the config.
export const HOSTS = {
  home: BASE,
  quiz: `${BASE}/cloud-developer-quiz/`,
  vmcp: `${BASE}/vmcp/`,
  api: process.env.PLATFORM_API ?? 'https://api-andres.project-platform.me',
};

export default defineConfig({
  testDir: './tests',
  fullyParallel: true,
  timeout: 60_000,
  expect: { timeout: 15_000 },
  // The live site is behind Cloudflare; one retry absorbs a transient edge hiccup without masking a
  // real regression (a real break fails both attempts).
  retries: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: BASE,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    ignoreHTTPSErrors: true,
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
});

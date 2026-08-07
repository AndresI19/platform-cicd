import { test, expect } from '@playwright/test';

// The vMCP dashboard (Carbon + React Router). Every page must load, and Recent Calls must show the
// telemetry the gateway records — the proof that tool calls actually cross the gateway.

const PAGES: [path: string, heading: RegExp][] = [
  ['/vmcp/', /Overview/],
  ['/vmcp/servers', /Servers/],
  ['/vmcp/all-tools', /Tools/],
  ['/vmcp/users', /Users/],
  ['/vmcp/calls', /Calls/],
];

test.describe('vmcp dashboard', () => {
  test('overview loads and renders', async ({ page }) => {
    await page.goto('/vmcp/');
    await expect(page).toHaveTitle(/vMCP Gateway/);
    await expect(page.locator('h1')).toHaveText(/Overview/);
    await expect(page.locator('#main-content')).toBeVisible();
  });

  for (const [path, heading] of PAGES) {
    test(`page ${path} loads without error`, async ({ page }) => {
      const errors: string[] = [];
      page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
      await page.goto(path);
      await expect(page.locator('h1')).toContainText(heading);
      // no uncaught render error surfaced to the console
      expect(errors.join('\n')).not.toMatch(/Uncaught|is not a function|Cannot read/);
    });
  }

  test('Recent Calls shows gateway telemetry rows', async ({ page }) => {
    await page.goto('/vmcp/calls');
    await expect(page.locator('h1')).toContainText(/Calls/);
    // The FVT traffic runner drives tool calls through the gateway on a loop, so this table is
    // populated in steady state — a table with at least one data row.
    const rows = page.locator('table tbody tr');
    await expect(rows.first()).toBeVisible();
    expect(await rows.count()).toBeGreaterThan(0);
  });

  test('sign-in control is present (public dashboard is read-only)', async ({ page }) => {
    await page.goto('/vmcp/');
    await expect(page.getByRole('button', { name: /Sign in/ })).toBeVisible();
  });
});

import { test, expect, type Page } from '@playwright/test';

// The quiz app: setup screen → card-playing engine → garden. Each test runs in a fresh browser
// context, so the per-browser localStorage progress doc is isolated and nothing persists on live.

// A fresh context can pop the pin gate / first-visit greeting; continue as guest so the run proceeds.
async function dismissGate(page: Page): Promise<void> {
  const guest = page.getByRole('button', { name: /Continue as a guest/ });
  if (await guest.isVisible().catch(() => false)) {
    await guest.click().catch(() => {});
    await page.waitForTimeout(200);
  }
}

async function startRun(page: Page): Promise<void> {
  await page.goto('/cloud-developer-quiz/');
  await dismissGate(page);
  await page.getByRole('button', { name: /All \(\d+\)/ }).click(); // select all sections → non-empty deck
  await page.locator('#start').click();
  await dismissGate(page);
}

test.describe('quiz', () => {
  test('loads the setup screen', async ({ page }) => {
    await page.goto('/cloud-developer-quiz/');
    await dismissGate(page);
    await expect(page).toHaveTitle(/Cloud Developer Quiz/);
    await expect(page.locator('h1')).toHaveText(/Cloud Developer Quiz/);
    await expect(page.locator('#secchips')).toBeVisible();
    await expect(page.locator('#start')).toBeVisible();
    await expect(page.getByRole('button', { name: /All \(\d+\)/ })).toBeVisible();
  });

  test('starts a run and renders a playable card', async ({ page }) => {
    await startRun(page);
    // The engine chrome that's deterministic across card types: the card and the pause pill. (Hint
    // and Reveal controls vary by card type, so they'd make the oracle flaky.)
    await expect(page.locator('.qcard')).toBeVisible();
    await expect(page.locator('#pausebtn')).toBeVisible();
  });

  test('pause pill keeps the card mounted (no stuck-render regression)', async ({ page }) => {
    await startRun(page);
    await expect(page.locator('.qcard')).toBeVisible();
    await page.locator('#pausebtn').click();
    // A legacy stuck-render bug threw mid-render on pause; the card must survive the toggle.
    await expect(page.locator('.qcard')).toBeVisible();
  });

  test('garden opens with its tool palette', async ({ page }) => {
    await page.goto('/cloud-developer-quiz/');
    await dismissGate(page);
    await page.locator('#homegarden').click();
    await expect(page.locator('#gback')).toBeVisible(); // ← Back
    await expect(page.locator('#toolview')).toBeVisible(); // the View tool in the palette
    await page.locator('#gback').click();
    await expect(page.locator('#start')).toBeVisible(); // back on the setup screen
  });
});

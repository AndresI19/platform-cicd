import { test, expect } from '@playwright/test';

// The portfolio home page: masthead, the four architecture diagrams behind the pull-down, the
// version report, the first-visit sign-in gate, and the cross-links to the other two front ends.

test.describe('home', () => {
  test('loads with the masthead', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle(/Andres Irarragorri/);
    await expect(page.locator('.masthead h1')).toHaveText(/Andres Irarragorri/);
  });

  test('/version reports both the image and platform versions', async ({ request }) => {
    const r = await request.get('/version');
    expect(r.ok()).toBeTruthy();
    const v = await r.json();
    expect(v.version).toMatch(/^\d+\.\d+\.\d+/); // the image's own version
    expect(v.platform).toMatch(/^\d+\.\d+\.\d+/); // the orchestration repo's version
  });

  test('architecture pull-down reveals the panel and pages all four diagrams', async ({ page }) => {
    await page.goto('/');
    await page.locator('.arch-pull').click();
    await expect(page.locator('#arch-panel')).toBeVisible();
    // The diagrams are paged by a role=tab slider; clicking a tab makes it is-active.
    for (const label of ['Platform Topography', 'CICD', 'Auth and Entrypoint', 'Security']) {
      const tab = page.getByRole('tab', { name: label });
      await tab.click();
      await expect(tab).toHaveClass(/is-active/);
    }
  });

  test('topology diagram draws fvt-traffic as a consumer, not a cluster box', async ({ page }) => {
    await page.goto('/');
    await page.locator('.arch-pull').click();
    await page.getByRole('tab', { name: 'Platform Topography' }).click();
    const topo = page.locator('#arch-panel .arch-diagram').first(); // topology is the first slide
    await expect(topo.getByText('rs-mcp-server').first()).toBeVisible();
    // fvt-traffic is named in the caller box, bold, and has NO standalone cluster box any more.
    await expect(topo.getByText('FVT-traffic')).toBeVisible();
    await expect(topo.locator('.arch-name', { hasText: /^fvt-traffic$/ })).toHaveCount(0);
  });

  test('first-visit gate opens and can be dismissed as a guest', async ({ page }) => {
    await page.goto('/');
    await page.getByRole('button', { name: 'Guest' }).click();
    // The three doors of the pin gate. We do NOT create an account (that writes to the live auth DB);
    // opening + dismissing as guest exercises the gate without a side effect.
    await expect(page.getByText('Before you start')).toBeVisible();
    await expect(page.getByRole('button', { name: /Create an account/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /I have an account/ })).toBeVisible();
    await page.getByRole('button', { name: /Continue as a guest/ }).click();
    await expect(page.getByText('Before you start')).toBeHidden();
  });

  test('cross-links to the quiz and the vMCP dashboard are present', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('a[href="/cloud-developer-quiz/"]').first()).toBeVisible();
    await expect(page.locator('a[href="/vmcp/"]').first()).toBeVisible();
  });
});

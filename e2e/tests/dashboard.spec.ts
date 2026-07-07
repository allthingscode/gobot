import { test, expect } from '@playwright/test';

test.describe('GoBot Dashboard', () => {
  test('loads with the expected title and header', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveTitle('GoBot Dashboard');
    await expect(page.locator('.logo')).toHaveText('GoBot Dashboard');
  });

  test('renders seeded log entries from the SSE backlog', async ({ page }) => {
    await page.goto('/');
    const logOutput = page.locator('#log-output');
    await expect(logOutput.locator('.log-line').first()).toBeVisible();
    await expect(logOutput).toContainText('gobot started');
    await expect(logOutput).toContainText('rate limit approaching');
    await expect(logOutput).toContainText('example error for tests');
  });

  test('streams live heartbeat entries', async ({ page }) => {
    await page.goto('/');
    const heartbeats = page.locator('#log-output .log-line', { hasText: 'heartbeat' });
    await expect(heartbeats.first()).toBeVisible({ timeout: 5000 });
  });

  test('filter box hides non-matching lines', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('#log-output')).toContainText('gobot started');
    await page.locator('#filter').fill('rate limit');
    await expect(page.getByText('rate limit approaching')).toBeVisible();
    await expect(
      page.locator('#log-output .log-line', { hasText: 'gobot started' }),
    ).toBeHidden();
  });
});

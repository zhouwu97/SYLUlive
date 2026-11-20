import { chromium, expect } from '@playwright/test';
import { execFile } from 'node:child_process';
import path from 'node:path';

const origin = process.env.QR_CHAIN_ORIGIN;
if (new URL(origin).hostname !== '127.0.0.1') throw new Error('Only an isolated loopback API is allowed');
const browser = await chromium.launch({ headless: true });
let externalRequests = 0;
let complete;
const uploaded = new Promise(resolve => { complete = resolve; });
try {
  const context = await browser.newContext();
  await context.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    if (url.origin !== origin) { externalRequests++; return route.abort(); }
    if (url.pathname.startsWith('/api/academic-transfer/')) {
      // 等 App 完成同密文重试后才让网页确认，避免确认清除与重试互相抢占。
      if (request.method() === 'GET') await uploaded;
      return route.continue().catch(() => undefined);
    }
    if (url.pathname === '/api/user/profile') return route.fulfill({ json: { id: 7, nickname: '跨端合成用户', role: 'user' } });
    if (url.pathname.startsWith('/api/')) return route.fulfill({ json: { items: [] } });
    return route.continue();
  });
  const page = await context.newPage();
  await page.goto(origin + '/web/schedule');
  await page.locator('.source-line').getByRole('button', { name: '手机 App 扫码同步' }).click();
  const form = page.locator('.phone-scan');
  await expect(form.getByRole('status')).toContainText('等待手机扫码');
  await form.getByText('无法扫码？', { exact: true }).click();
  const link = await form.getByRole('textbox', { name: '同步链接', exact: true }).inputValue();
  const command = process.platform === 'win32' ? 'powershell.exe' : process.env.QR_CHAIN_FLUTTER;
  const args = process.platform === 'win32'
    ? ['-NoProfile', '-NonInteractive', '-Command', '& $env:QR_CHAIN_FLUTTER test --no-pub test/integration/academic_transfer_chain_test.dart --reporter expanded; exit $LASTEXITCODE']
    : ['test', '--no-pub', 'test/integration/academic_transfer_chain_test.dart', '--reporter', 'expanded'];
  try {
    await new Promise((resolve, reject) => execFile(command, args, {
      cwd: path.resolve('client'), env: { ...process.env, QR_CHAIN_LINK: link }, timeout: 180000,
    }, (error, stdout, stderr) => error ? reject(new Error(stdout + stderr)) : resolve()));
  } finally { complete(); }
  await expect(form.getByRole('status')).toContainText('同步完成');
  await form.getByRole('button', { name: '完成', exact: true }).click();
  await expect(page.getByRole('button', { name: /跨端扫码课程/ })).toBeVisible();
  expect(externalRequests).toBe(0);
  console.log(JSON.stringify({ passed: true, chain: 'Web → Flutter API/crypto → Go relay → Web decrypt/import', repeatedCiphertext: 'accepted', externalRequests }));
} finally { complete(); await browser.close(); }

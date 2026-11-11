import {test, expect, type Page} from '@playwright/test';
import {webcrypto} from 'node:crypto';

const PROTOCOL = 'sylulive-academic-transfer-v1';
const SESSION = 'AAECAwQFBgcICQoLDA0ODw';
const encoder = new TextEncoder();
const b64u = (bytes: ArrayBuffer | Uint8Array) => Buffer.from(bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)).toString('base64url');

// 按 App 端的做法加密：一次性 P-256 密钥 → ECDH → HKDF-SHA256 → AES-256-GCM。
async function encryptLikeApp(webPublicKey: string, sessionId: string, payload: unknown) {
  const subtle = webcrypto.subtle;
  const app = await subtle.generateKey({name: 'ECDH', namedCurve: 'P-256'}, true, ['deriveBits']);
  const web = await subtle.importKey('raw', Buffer.from(webPublicKey, 'base64url'), {name: 'ECDH', namedCurve: 'P-256'}, false, []);
  const material = await subtle.importKey('raw', await subtle.deriveBits({name: 'ECDH', public: web}, app.privateKey, 256), 'HKDF', false, ['deriveKey']);
  const key = await subtle.deriveKey({name: 'HKDF', hash: 'SHA-256', salt: encoder.encode(sessionId), info: encoder.encode(PROTOCOL)}, material, {name: 'AES-GCM', length: 256}, false, ['encrypt']);
  const nonce = webcrypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await subtle.encrypt({name: 'AES-GCM', iv: nonce, additionalData: encoder.encode(`${PROTOCOL}|${sessionId}`)}, key, encoder.encode(JSON.stringify(payload)));
  return {app_public_key: b64u(await subtle.exportKey('raw', app.publicKey)), nonce: b64u(nonce), ciphertext: b64u(ciphertext)};
}

type Session = {status: string; payload?: unknown; gone?: boolean; deleted: number; created: number};

async function setup(page: Page): Promise<Session> {
  const session: Session = {status: 'pending', deleted: 0, created: 0};
  await page.route('**/api/**', route => route.fulfill({json: {items: []}}));
  await page.route('**/api/user/profile', route => route.fulfill({json: {id: 7, nickname: '测试用户', role: 'user'}}));
  await page.route('**/api/academic-transfer/sessions', route => {
    session.created += 1;
    expect(route.request().headers()['x-expected-app-user']).toBe('7');
    return route.fulfill({status: 201, json: {session_id: SESSION, status: 'pending', ttl_seconds: 300}});
  });
  await page.route(`**/api/academic-transfer/sessions/${SESSION}`, route => {
    if (route.request().method() === 'DELETE') { session.deleted += 1; return route.fulfill({status: 204}); }
    if (session.gone) return route.fulfill({status: 404, json: {code: 'TRANSFER_SESSION_NOT_FOUND', message: '二维码已失效，请在网页重新生成'}});
    return route.fulfill({json: {session_id: SESSION, status: session.status, ttl_seconds: 280, ...(session.payload ? {payload: session.payload} : {})}});
  });
  // 页面的公钥只出现在二维码里；测试在生成密钥时旁路记录一份，代替「手机扫码」这一步。
  await page.addInitScript(() => {
    const original = crypto.subtle.generateKey.bind(crypto.subtle) as (...args: unknown[]) => Promise<CryptoKeyPair>;
    (crypto.subtle as unknown as {generateKey: unknown}).generateKey = async (...args: unknown[]) => {
      const pair = await original(...args);
      if ((args[0] as {name?: string})?.name === 'ECDH') {
        const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
        (window as unknown as {__transferKey: string}).__transferKey = btoa(String.fromCharCode(...raw)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
      }
      return pair;
    };
  });
  return session;
}

const today = new Date().getDay() || 7;
const payload = {
  version: 1,
  generatedAt: new Date().toISOString(),
  schedules: [
    {id: 'current', kind: 'current', label: '2026-2027 第一学期', provider: 'undergraduate', term: {year: '2026', semester: '3'}, termStart: '', fetchedAt: new Date().toISOString(),
      courses: [{id: 'c1', name: '扫码同步课程', teacher: '王老师', room: '信息楼 301', day: today, periods: [1, 2], weeks: [1, 2, 3]}]},
    {id: 'archive:a1', kind: 'archive', label: '大二下备份', provider: 'undergraduate', term: {year: '2025', semester: '12'}, termStart: '', fetchedAt: '',
      courses: [{id: 'old1', name: '存档里的课程', teacher: '', room: '旧教学楼', day: today, periods: [3, 4], weeks: [1]}]},
  ],
  grades: {fetchedAt: new Date().toISOString(), items: [{id: 'g1', name: '线性代数', credit: 3, score: '92', gpa: 4.2, nature: '必修', term: '2025-2026 第一学期'}]},
  erke: {fetchedAt: new Date().toISOString(), requiredTotal: 60, earnedTotal: 42.5, graduationGap: 17.5, conclusion: '未达标',
    categories: [{code: 'A', name: '思想成长', required: 10, earned: 8}], activities: [{item: '志愿服务', score: '1.5', date: '2026-10-01', category: '志愿公益'}]},
  physical: {fetchedAt: new Date().toISOString(), years: [{year: '2025', totalScore: 82.5, totalGrade: '良好', scores: [{name: '50米跑', result: '7.2', grade: '良好', score: 80}]}]},
};

test('手机扫码后解密并写入课表、成绩、二课和体测', async ({page}) => {
  const session = await setup(page);
  await page.goto('schedule');
  await expect(page.getByRole('button', {name: '我的账号'})).toBeVisible();
  await page.locator('.schedule-empty-hint').getByRole('button', {name: '手机 App 扫码同步'}).click();
  const dialog = page.locator('.phone-scan');
  await expect(dialog.getByRole('img', {name: '手机 App 扫码同步二维码'})).toBeVisible();
  await expect(dialog.getByRole('status')).toContainText('等待手机扫码');
  await expect(dialog.getByRole('status')).toContainText('后失效');

  session.status = 'claimed';
  await expect(dialog.getByRole('status')).toContainText('手机已扫码');

  const key = await page.evaluate(() => (window as unknown as {__transferKey: string}).__transferKey);
  session.payload = await encryptLikeApp(key, SESSION, payload);
  session.status = 'ready';
  await expect(dialog.getByRole('status')).toContainText('同步完成');
  await expect(dialog).toContainText('已同步：课表 2 份、成绩 1 门、二课、体测');
  await expect(dialog).toContainText('可以切换其他学期和存档课表');
  await expect.poll(() => session.deleted).toBe(1);
  await dialog.getByRole('button', {name: '完成'}).click();

  await expect(page.locator('.source-line')).toContainText('来自手机 App 同步');
  await expect(page.getByRole('button', {name: /扫码同步课程/})).toBeVisible();
  await expect(page.locator('.schedule-empty-hint')).toHaveCount(0);
  await page.getByLabel('切换课表').selectOption('archive:a1');
  await expect(page.getByRole('button', {name: /存档里的课程/})).toBeVisible();
  await expect(page.getByRole('button', {name: /扫码同步课程/})).toHaveCount(0);

  // 资料只在页面内存里，必须用站内导航而不是重新加载。
  await page.locator('.sidebar-more summary').click();
  await page.getByRole('link', {name: '成绩与学业'}).first().click();
  await expect(page.locator('.data-table')).toContainText('线性代数');
  await page.getByRole('tab', {name: '二课'}).click();
  await expect(page.locator('.panel-pad')).toContainText('来源：手机 App 同步');
  await expect(page.locator('.panel-pad')).toContainText('思想成长');
  await expect(page.locator('.panel-pad')).toContainText('还差 2');
  await page.getByRole('tab', {name: '体测'}).click();
  await expect(page.locator('.panel-pad')).toContainText('50米跑');
  await expect(page.locator('.panel-pad')).toContainText('总分 82.5');
});

test('二维码失效可重新生成，关闭弹窗会作废未完成的会话', async ({page}) => {
  const session = await setup(page);
  await page.goto('schedule');
  await expect(page.getByRole('button', {name: '我的账号'})).toBeVisible();
  await page.locator('.source-line').getByRole('button', {name: '手机 App 扫码同步'}).click();
  const dialog = page.locator('.phone-scan');
  await expect(dialog.getByRole('status')).toContainText('等待手机扫码');

  session.gone = true;
  await expect(dialog.getByRole('status')).toContainText('二维码已失效');
  session.gone = false;
  const before = session.created;
  await dialog.getByRole('button', {name: '重新生成二维码'}).click();
  await expect(dialog.getByRole('status')).toContainText('等待手机扫码');
  expect(session.created).toBeGreaterThan(before);

  // 另一张码的密文在这里解不开：只提示重试，不写入任何资料。
  session.payload = await encryptLikeApp(await page.evaluate(() => (window as unknown as {__transferKey: string}).__transferKey), 'another-session-id', payload);
  session.status = 'ready';
  await expect(dialog).toContainText('无法解密手机发来的资料');
  const deleted = session.deleted;
  await dialog.getByRole('button', {name: '取消'}).click();
  await expect.poll(() => session.deleted).toBeGreaterThan(deleted);
  await expect(page.locator('.source-line')).toContainText('未读取学校课表');
  await expect(page.locator('.schedule-empty-hint')).toBeVisible();
});

test('其他扫码工具打开同步链接时提示改用 App', async ({page}) => {
  await setup(page);
  await page.goto(`app-scan#v=1&s=${SESSION}&k=${'A'.repeat(87)}`);
  await expect(page.getByRole('heading', {name: '请用沈理校园 App 扫码'})).toBeVisible();
  await expect(page.getByRole('link', {name: '在沈理校园 App 中打开'})).toHaveAttribute('href', `sylulive://academic-transfer?v=1&s=${SESSION}&k=${'A'.repeat(87)}`);
  await page.goto('app-scan#v=1&s=short');
  await expect(page.locator('.app-scan-landing')).toContainText('链接不完整或已经失效');
});

// Captures the built product with synthetic local API responses and zero school traffic.
import {chromium} from '@playwright/test';
import {readFile, writeFile, mkdir, mkdtemp, rm} from 'node:fs/promises';
import {dirname, resolve, join, extname, sep} from 'node:path';
import {fileURLToPath} from 'node:url';
import {tmpdir} from 'node:os';
import {createHash} from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url)), root = resolve(here, '../..');
const web = join(root, 'web/dist'), extension = join(root, 'browser-extension/dist-store');
const output = join(root, 'browser-extension/release-store/assets');
const temporary = await mkdtemp(join(tmpdir(), 'sylulive-store-capture-'));
await mkdir(output, {recursive:true});
const context = await chromium.launchPersistentContext(join(temporary, 'profile'), {channel:'chromium', headless:true,
  viewport:{width:1280,height:800}, deviceScaleFactor:1,
  args:[`--disable-extensions-except=${extension}`, `--load-extension=${extension}`]});
const errors = [], blocked = [];
try {
  await context.route('**/*', async route => {
    const url = new URL(route.request().url());
    if (url.protocol === 'chrome-extension:') return route.continue();
    if (url.origin !== 'https://sylulive.online') { blocked.push(url.origin); return route.abort(); }
    if (url.pathname.startsWith('/api/')) return route.fulfill({json:url.pathname === '/api/user/profile'
      ? {id:9001,nickname:'演示同学',role:'user'} : {items:[],posts:[],has_more:false}});
    if (!url.pathname.startsWith('/web/')) return route.fulfill({status:404,body:'Local fixture: not available'});
    const relative = url.pathname.slice('/web/'.length);
    const file = resolve(web, relative.startsWith('assets/') ? relative : 'index.html');
    if (!file.startsWith(web + sep)) throw new Error('unexpected built asset path');
    const types = {'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.woff2':'font/woff2'};
    return route.fulfill({contentType:types[extname(file)] || 'application/octet-stream',body:await readFile(file)});
  });
  const page = await context.newPage();
  page.on('pageerror', error => errors.push(error.name));
  const records = [];
  for (const [path, filename] of [['schedule','schedule-1280x800.png'],['grades','grades-1280x800.png']]) {
    await page.goto(`https://sylulive.online/web/${path}`);
    await page.getByRole('heading').first().waitFor();
    await page.getByText('正在加载').first().waitFor({state:'hidden'}).catch(()=>{});
    await page.evaluate(async () => { await document.fonts.ready; });
    await page.locator('.connection-form, .academic-connect, main').first().waitFor();
    await page.evaluate(() => {
      const label = document.createElement('div'); label.textContent = '功能截图 · 演示状态 · 无真实个人资料';
      label.style.cssText = 'position:fixed;bottom:8px;right:12px;z-index:2147483647;padding:5px 10px;background:#fff;color:#334155;border:1px solid #cbd5e1;border-radius:6px;font:12px system-ui';
      document.body.append(label);
    });
    await page.screenshot({path:join(output,filename)});
    records.push({filename,width:1280,height:800,route:`/web/${path}`,kind:'actual product with synthetic local API'});
  }
  const icon = (await readFile(join(extension,'icon-128.png'))).toString('base64');
  await page.setViewportSize({width:440,height:280});
  await page.setContent(`<svg xmlns="http://www.w3.org/2000/svg" width="440" height="280" viewBox="0 0 440 280"><rect width="440" height="280" fill="#eaf6f3"/><rect x="22" y="22" width="396" height="236" rx="24" fill="white"/><image href="data:image/png;base64,${icon}" x="164" y="41" width="112" height="112"/><text x="220" y="191" text-anchor="middle" font-family="Microsoft YaHei, sans-serif" font-weight="700" font-size="25" fill="#12382f">沈理校园教务助手</text><text x="220" y="222" text-anchor="middle" font-family="Microsoft YaHei, sans-serif" font-size="15" fill="#42675f">本机学校查询 · 连接校园 Web</text></svg>`);
  await page.screenshot({path:join(output,'tile-440x280.png')});
  records.push({filename:'tile-440x280.png',width:440,height:280,kind:'promotional vector artwork'});
  if (errors.length || blocked.length) throw new Error(`Capture failed: pageErrors=${errors.length}, blockedRequests=${blocked.length}`);
  for (const record of records) record.sha256 = createHash('sha256').update(await readFile(join(output,record.filename))).digest('hex');
  await writeFile(join(output,'manifest.json'), JSON.stringify({synthetic_data:true,school_requests:0,records},null,2)+'\n');
  console.log(JSON.stringify({assets:records.length,school_requests:0,page_errors:errors.length}));
} finally {
  await context.close();
  if (!resolve(temporary).startsWith(resolve(tmpdir(),'sylulive-store-capture-'))) throw new Error('unexpected temporary profile');
  await rm(temporary,{recursive:true,force:true});
}

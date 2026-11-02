import { chromium } from '@playwright/test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
const root=path.dirname(fileURLToPath(import.meta.url));
const browser=await chromium.launch({headless:true});
const results=[];
try {
  await fs.mkdir(path.join(root,'previews'),{recursive:true});
  for(const file of ['a-studio','b-editorial','c-commons']){
    const page=await browser.newPage({viewport:{width:1440,height:1080}});
    const errors=[];page.on('pageerror',e=>errors.push(e.message));
    await page.goto(pathToFileURL(path.join(root,`${file}.html`)).href);
    await page.screenshot({path:path.join(root,'previews',`${file}-desktop.png`),fullPage:true});
    await page.locator('nav [data-page="schedule"]').first().click();
    assert.equal(await page.locator('.lesson').count(),7);
    await page.locator('#state').selectOption('error');
    await page.locator('[data-retry]').click();
    assert.equal(await page.locator('.timetable').count(),1);
    await page.locator('#state').selectOption('permission');
    await page.locator('[data-connect]').click();
    await page.locator('[data-demo-connect]').click();
    assert.equal(await page.locator('dialog').evaluate(d=>d.open),false);
    await page.locator('#state').selectOption('loading');
    assert.match(await page.locator('main').innerText(),/正在整理/);
    await page.locator('#state').selectOption('empty');
    assert.match(await page.locator('main').innerText(),/还没有内容/);
    await page.locator('#state').selectOption('ready');
    await page.locator('nav [data-page="community"]').first().click();
    await page.locator('[data-filter="学习交流"]').click();
    assert.equal(await page.locator('.post').count(),1);
    const like=page.locator('[data-like]').first();await like.click();assert.equal(await like.getAttribute('aria-pressed'),'true');
    await page.locator('[data-detail]').first().click();
    await page.locator('#comment-text').fill('<script>演示文本</script>');
    await page.locator('#comment button').click();
    assert.equal(await page.locator('#comments').innerText(),'<script>演示文本</script>');
    await page.keyboard.press('Escape');
    await page.locator('#search').fill('不存在的功能');
    assert.match(await page.locator('main').innerText(),/没有匹配功能/);
    await page.locator('#search').fill('课表');
    await page.locator('main [data-page="schedule"]').click();
    await page.locator('nav [data-page="ai"]').first().click();
    await page.locator('#question').fill('学习');await page.locator('#chat button').click();
    await page.locator('nav [data-page="home"]').first().click();
    await page.waitForTimeout(750);
    assert.equal(await page.locator('#answer').count(),0);
    for(const size of [{width:1440,height:1080},{width:390,height:844}]){
      await page.setViewportSize(size);
      for(const id of ['home','schedule','community','market','ai','grades','admin']){
        await page.locator(`nav [data-page="${id}"]`).first().click();
        assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`${file} ${size.width} ${id}: overflow`);
      }
    }
    await page.reload();
    await page.screenshot({path:path.join(root,'previews',`${file}-mobile.png`),fullPage:true});
    assert.deepEqual(errors,[]);
    results.push(`${file}: desktop/mobile layout, navigation, search, filtering, like, safe comment, error/retry, permission, loading/empty, stale AI callback PASS`);
    await page.close();
  }
  console.log(results.join('\n'));
} finally {await browser.close()}

import {test, expect} from '@playwright/test';
import {readFile} from 'node:fs/promises';

for (const colorScheme of ['light','dark'] as const) {
  for (const [path, filename, title] of [
    ['/terms','terms','沈理校园用户协议'],
    ['/privacy','privacy','沈理校园隐私政策'],
    ['/extension/privacy','extension-privacy','沈理校园教务助手隐私说明'],
  ]) {
    test(`公开正文移动端可读 ${path} ${colorScheme}`, async ({page}) => {
      await page.setViewportSize({width:375,height:812});
      await page.emulateMedia({colorScheme, reducedMotion:'reduce'});
      const html = await readFile(`server/static/legal/${filename}.html`, 'utf8');
      await page.route(`**${path}`, route => route.fulfill({contentType:'text/html; charset=utf-8',body:html}));
      await page.goto(`http://127.0.0.1:5173${path}`);
      await expect(page.getByRole('heading',{level:1})).toHaveText(title);
      expect(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      const contact = page.locator('.body').filter({hasText:'1517088507@qq.com'}).last();
      await expect(contact).toBeVisible();
      const fits = await contact.evaluate(element => {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let node: Node | null;
        while ((node = walker.nextNode())) {
          for (const email of ['3170305904@qq.com','2350016823@qq.com','1517088507@qq.com']) {
            const start = node.textContent?.indexOf(email) ?? -1;
            if (start < 0) continue;
            const range = document.createRange(); range.setStart(node,start); range.setEnd(node,start+email.length);
            if ([...range.getClientRects()].some(rect=>rect.left < 0 || rect.right > innerWidth)) return false;
          }
        }
        return true;
      });
      expect(fits).toBe(true);
    });
  }
}

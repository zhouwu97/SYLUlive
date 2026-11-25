import {test,expect,chromium} from '@playwright/test';
import {resolve} from 'node:path';
import {mkdtemp,rm,cp,readFile,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';

test('开发扩展真实加载、握手及非业务命令隔离',async({baseURL})=>{
  const profile=await mkdtemp(resolve(tmpdir(),'sylulive-extension-test-'));
  const extension=resolve(profile,'extension');
  await cp(resolve('browser-extension/dist-dev'),extension,{recursive:true});
  const origin=new URL(baseURL!).origin;
  const manifest=JSON.parse(await readFile(resolve(extension,'manifest.json'),'utf8'));
  manifest.host_permissions.push(`${origin}/*`);
  for(const script of manifest.content_scripts)script.matches.push(`${origin}/*`);
  await writeFile(resolve(extension,'manifest.json'),JSON.stringify(manifest));
  const context=await chromium.launchPersistentContext(profile,{channel:'chromium',headless:true,args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`]});
  try{
    const worker=context.serviceWorkers()[0]||await context.waitForEvent('serviceworker');
    expect(worker.url()).toContain('background.js');
    const page=await context.newPage();await page.goto(`${origin}/web/schedule`);
    const response=await page.evaluate(()=>new Promise<any>((resolve,reject)=>{
      const id=crypto.randomUUID();const timer=setTimeout(()=>reject(new Error('扩展握手超时')),5000);
      const listener=(e:MessageEvent)=>{if(e.data?.id===id&&e.data?.direction==='response'){clearTimeout(timer);window.removeEventListener('message',listener);resolve(e.data)}};
      window.addEventListener('message',listener);window.postMessage({channel:'sylulive-academic-v1',direction:'request',version:1,id,operation:'hello',payload:{}},location.origin);
    }));
    expect(response.ok).toBe(true);expect(response.result.capabilities).toHaveLength(4);
    // 授权位与已有连接都来自扩展本地 API，这条断言确认 Service Worker 里真的取到了它们。
    expect(Object.values(response.result.authorized)).toHaveLength(4);
    expect(Object.values(response.result.authorized).every(v=>typeof v==='boolean')).toBe(true);
    expect(Array.isArray(response.result.connections)).toBe(true);
    const rejected=await page.evaluate(()=>new Promise<boolean>(resolve=>{
      const id=crypto.randomUUID();let received=false;
      const listener=(e:MessageEvent)=>{if(e.data?.id===id&&e.data?.direction==='response')received=true};
      window.addEventListener('message',listener);
      window.postMessage({channel:'sylulive-academic-v1',direction:'request',version:1,id,operation:'fetch',payload:{url:'https://example.com'}},location.origin);
      setTimeout(()=>{window.removeEventListener('message',listener);resolve(!received)},250);
    }));expect(rejected).toBe(true);
  }finally{await context.close();if(!resolve(profile).startsWith(resolve(tmpdir(),'sylulive-extension-test-')))throw new Error('临时测试目录超出预期范围');await rm(profile,{recursive:true,force:true});}
});

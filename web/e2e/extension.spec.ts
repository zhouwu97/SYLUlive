import {test,expect,chromium} from '@playwright/test';
import {resolve} from 'node:path';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';

test('开发扩展真实加载、握手及非业务命令隔离',async()=>{
  const profile=await mkdtemp(resolve(tmpdir(),'sylulive-extension-test-'));
  const extension=resolve('browser-extension/dist-dev');
  const context=await chromium.launchPersistentContext(profile,{channel:'chromium',headless:true,args:[`--disable-extensions-except=${extension}`,`--load-extension=${extension}`]});
  try{
    const worker=context.serviceWorkers()[0]||await context.waitForEvent('serviceworker');
    expect(worker.url()).toContain('background.js');
    const page=await context.newPage();await page.goto('http://127.0.0.1:5173/web/schedule');
    const response=await page.evaluate(()=>new Promise<any>((resolve,reject)=>{
      const id=crypto.randomUUID();const timer=setTimeout(()=>reject(new Error('扩展握手超时')),5000);
      const listener=(e:MessageEvent)=>{if(e.data?.id===id&&e.data?.direction==='response'){clearTimeout(timer);window.removeEventListener('message',listener);resolve(e.data)}};
      window.addEventListener('message',listener);window.postMessage({channel:'sylulive-academic-v1',direction:'request',version:1,id,operation:'hello',payload:{}},location.origin);
    }));
    expect(response.ok).toBe(true);expect(response.result.capabilities).toHaveLength(4);
    const rejected=await page.evaluate(()=>new Promise<boolean>(resolve=>{
      const id=crypto.randomUUID();let received=false;
      const listener=(e:MessageEvent)=>{if(e.data?.id===id&&e.data?.direction==='response')received=true};
      window.addEventListener('message',listener);
      window.postMessage({channel:'sylulive-academic-v1',direction:'request',version:1,id,operation:'fetch',payload:{url:'https://example.com'}},location.origin);
      setTimeout(()=>{window.removeEventListener('message',listener);resolve(!received)},250);
    }));expect(rejected).toBe(true);
  }finally{await context.close();if(!resolve(profile).startsWith(resolve(tmpdir(),'sylulive-extension-test-')))throw new Error('临时测试目录超出预期范围');await rm(profile,{recursive:true,force:true});}
});

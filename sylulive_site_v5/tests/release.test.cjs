const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../assets/release.js'), 'utf8');
const valid = {latest_version_name:'2.4.1',file_size:10485760,published_at:'2026-10-27T02:00:00Z',download_url:'/api/app/releases/1/download',sha256:'a'.repeat(64),changelog:'新的更新说明'};
function fixture({hostname='sylulive.online', fetcher=async()=>({ok:true,json:async()=>valid})}={}) {
  class Element extends EventTarget {
    constructor(){super();this.textContent='';this.attrs={};this.classes=new Set();this.classList={remove:k=>this.classes.delete(k),toggle:(k,v)=>v?this.classes.add(k):this.classes.delete(k)};}
    setAttribute(k,v){this.attrs[k]=v;}
    click(){this.dispatchEvent(new Event('click'));}
  }
  const el=Object.fromEntries(['versionName','fileSize','publishedAt','changelog','downloadBtn','downloadText','downloadHint','shaText','retryBtn','releaseState','releaseCard'].map(id=>[id,new Element()]));
  const requests=[], navigations=[], timers=new Map();let timerId=0;
  vm.runInNewContext(source,{
    document:{getElementById:id=>el[id]},location:{hostname,protocol:'https:',assign:url=>navigations.push(url)},URL,Intl,AbortController,
    fetch:(url,options)=>{requests.push({url,...options});return fetcher(url,options,requests.length);},
    setTimeout:cb=>{timers.set(++timerId,cb);return timerId;},clearTimeout:id=>timers.delete(id),
  });
  return {el,requests,navigations,timeout:()=>[...timers.values()].forEach(fn=>fn())};
}
const flush=()=>new Promise(resolve=>setImmediate(resolve));
test('stable APK renders metadata and opens the release address only on click',async()=>{
  const f=fixture();assert.equal(f.el.downloadBtn.disabled,true);await flush();
  assert.equal(f.el.versionName.textContent,'v2.4.1');assert.equal(f.el.fileSize.textContent,'10.0 MB');
  assert.equal(f.el.shaText.textContent,'a'.repeat(64));assert.equal(f.el.downloadBtn.disabled,false);
  assert.equal(f.el.releaseCard.attrs['aria-busy'],'false');assert.equal(f.navigations.length,0);
  f.el.downloadBtn.click();assert.deepEqual(f.navigations,['https://sylulive.online/api/app/releases/1/download']);
});
test('external market uses the market action and accurate button label',async()=>{
  const f=fixture({fetcher:async()=>({ok:true,json:async()=>({...valid,delivery_mode:'external_market',action_url:'https://example.com/market/app'})})});await flush();
  assert.equal(f.el.downloadText.textContent,'前往应用市场');f.el.downloadBtn.click();assert.equal(f.navigations[0],'https://example.com/market/app');
});
test('failed request exposes a retry and a successful retry resets failure state',async()=>{
  const f=fixture({fetcher:async(_u,_o,n)=>n===1?{ok:false}:{ok:true,json:async()=>valid}});await flush();
  assert.equal(f.el.retryBtn.hidden,false);assert.equal(f.el.downloadBtn.disabled,true);assert.equal(f.el.downloadHint.classes.has('error'),true);
  f.el.retryBtn.click();assert.equal(f.el.downloadBtn.disabled,true);await flush();
  assert.equal(f.requests.length,2);assert.equal(f.el.downloadBtn.disabled,false);assert.equal(f.el.downloadHint.classes.has('error'),false);
});
test('no published release is an empty state, with no download action',async()=>{
  const f=fixture({fetcher:async()=>({ok:true,json:async()=>({update_available:false,latest_version_name:''})})});await flush();
  assert.equal(f.el.versionName.textContent,'尚未发布');assert.equal(f.el.releaseState.textContent,'待发布');
  assert.equal(f.el.downloadBtn.disabled,true);f.el.downloadBtn.click();assert.equal(f.navigations.length,0);
});
test('local preview never calls the production API',async()=>{
  const f=fixture({hostname:'127.0.0.1'});await flush();
  assert.equal(f.requests.length,0);assert.equal(f.el.retryBtn.hidden,true);assert.equal(f.el.releaseState.textContent,'本地预览');
  assert.equal(f.el.releaseCard.attrs['aria-busy'],'false');
});
test('unsafe and missing URLs cannot enable downloads',async()=>{
  for(const url of ['javascript:alert(1)','data:text/html,bad','http://example.com/app.apk','https://name:password@example.com/app.apk','']){
    const f=fixture({fetcher:async()=>({ok:true,json:async()=>({...valid,download_url:url})})});await flush();
    assert.equal(f.el.downloadBtn.disabled,true,url);f.el.downloadBtn.click();assert.equal(f.navigations.length,0);
  }
});
test('request timeout clears busy state and permits retry',async()=>{
  const f=fixture({fetcher:(_u,o)=>new Promise((_resolve,reject)=>o.signal.addEventListener('abort',()=>reject(new Error('timeout'))))});
  f.timeout();await flush();assert.equal(f.el.releaseCard.attrs['aria-busy'],'false');assert.equal(f.el.retryBtn.hidden,false);assert.equal(f.el.downloadBtn.disabled,true);
});
test('a late stale response cannot replace a newer release',async()=>{
  let resolveFirst;
  const f=fixture({fetcher:(_u,_o,n)=>n===1?new Promise(r=>resolveFirst=r):Promise.resolve({ok:true,json:async()=>({...valid,latest_version_name:'3.0.0'})})});
  f.el.retryBtn.click();await flush();resolveFirst({ok:true,json:async()=>valid});await flush();
  assert.equal(f.el.versionName.textContent,'v3.0.0');assert.equal(f.requests[0].signal.aborted,true);
});
test('malformed release content uses plain text and invalid metadata has a fallback',async()=>{
  const f=fixture({fetcher:async()=>({ok:true,json:async()=>({...valid,file_size:'bad',published_at:'bad',sha256:'bad',changelog:'<img src=x onerror=alert(1)>'})})});await flush();
  assert.equal(f.el.fileSize.textContent,'—');assert.equal(f.el.publishedAt.textContent,'—');assert.equal(f.el.shaText.textContent,'当前版本未提供校验值。');assert.equal(f.el.changelog.textContent,'<img src=x onerror=alert(1)>');
});

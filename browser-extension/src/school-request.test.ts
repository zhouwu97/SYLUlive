import {afterEach, beforeEach, expect, it, vi} from 'vitest';
import {schoolRequest} from './school';

const tabs = vi.fn();
const request = vi.fn();
beforeEach(() => {
  tabs.mockReset().mockResolvedValue([]);
  request.mockReset().mockImplementation(async (url:string) => ({ok: true, status: 200, url,
    headers: new Headers({'content-type':'text/html; charset=utf-8'}),
    arrayBuffer: async () => new TextEncoder().encode('<html>ok</html>').buffer}));
  vi.stubGlobal('chrome', {tabs: {query: tabs}});
  vi.stubGlobal('fetch', request);
});
afterEach(() => vi.unstubAllGlobals());

it.each(['undergraduate','erke'] as const)('%s 查询无需枚举浏览器标签页', async provider => {
  await schoolRequest(provider, '/student/test');
  expect(tabs).not.toHaveBeenCalled();
  expect(request).toHaveBeenCalledTimes(1);
});

it('研究生仍从当前标签页保留 ASP 会话前缀', async () => {
  tabs.mockResolvedValue([{active:true, url:'https://yjsgl.sylu.edu.cn/(S(session123))/home/index'}]);
  await schoolRequest('graduate', '/student/test');
  expect(tabs).toHaveBeenCalledWith({url:'https://yjsgl.sylu.edu.cn/*'});
  expect(request.mock.calls[0][0]).toBe('https://yjsgl.sylu.edu.cn/(S(session123))/student/test');
});

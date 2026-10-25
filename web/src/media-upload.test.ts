import { afterEach, expect, it, vi } from "vitest";
import { beginAuthTransition, setAuthSession } from "./api";
import { uploadImageFiles } from "./media";
import { uploadIDs } from "./community";
afterEach(() => { beginAuthTransition(); vi.unstubAllGlobals(); });
it("切号取消批量上传后不会在新会话回退单文件上传", async () => {
  setAuthSession(1);
  let reject!: (error: Error) => void;
  const fetchMock = vi.fn(() => new Promise<Response>((_, fail) => { reject = fail; }));
  vi.stubGlobal("fetch", fetchMock);
  const pending = uploadImageFiles([new File([new Uint8Array([1])], "one.png", { type: "image/png" })]);
  await vi.waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
  setAuthSession(2);
  reject(new DOMException("请求已取消", "AbortError"));
  await expect(pending).rejects.toMatchObject({ name: "AbortError" });
  expect(fetchMock).toHaveBeenCalledTimes(1);
});
it("旧实例缺少批量端点仍可回退，并返回真实文件编号", async () => {
  setAuthSession(1);
  const fetchMock = vi.fn()
    .mockResolvedValueOnce(new Response(JSON.stringify({ message: "接口不存在" }), { status: 404, headers: { "content-type": "application/json" } }))
    .mockResolvedValueOnce(new Response(JSON.stringify({ file_id: 73 }), { status: 200, headers: { "content-type": "application/json" } }));
  vi.stubGlobal("fetch", fetchMock);
  await expect(uploadImageFiles([new File([new Uint8Array([1])], "one.png", { type: "image/png" })])).resolves.toEqual([73]);
  expect(fetchMock.mock.calls.map((args) => args[0])).toEqual(["/api/upload_multiple", "/api/upload"]);
});

it.each([401, 403, 413, 429, 500])("批量上传返回 %s 时保留失败，不额外上传", async (status) => {
  setAuthSession(1);
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ error: "上传被拒绝" }), {
    status, headers: { "content-type": "application/json" },
  })));
  vi.stubGlobal("fetch", fetchMock);
  await expect(uploadImageFiles([new File(["one"], "one.png", { type: "image/png" })])).rejects.toMatchObject({ status });
  expect(fetchMock).toHaveBeenCalledTimes(1);
});

it("批量部分成功时不重复上传，保留服务端错误原因", async () => {
  setAuthSession(1);
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ results: [{ file_id: 73 }, { error: "图片损坏" }] }), {
    status: 200, headers: { "content-type": "application/json" },
  })));
  vi.stubGlobal("fetch", fetchMock);
  await expect(uploadImageFiles(["one", "two"].map((name) => new File([name], `${name}.png`, { type: "image/png" })))).rejects.toThrow("图片损坏");
  expect(fetchMock).toHaveBeenCalledTimes(1);
});

it("相同文件的上传缓存只在原会话内复用，A → B → A 重新上传", async () => {
  setAuthSession(1);
  let id = 70;
  const fetchMock = vi.fn().mockImplementation(() => Promise.resolve(new Response(JSON.stringify({ results: [{ file_id: ++id }] }), {
    headers: { "content-type": "application/json" },
  })));
  vi.stubGlobal("fetch", fetchMock);
  const form = new FormData();
  form.append("images", new File(["one"], "one.png", { type: "image/png" }));
  await expect(uploadIDs(form)).resolves.toEqual([71]);
  await expect(uploadIDs(form)).resolves.toEqual([71]);
  setAuthSession(2);
  await expect(uploadIDs(form)).resolves.toEqual([72]);
  setAuthSession(1);
  await expect(uploadIDs(form)).resolves.toEqual([73]);
  expect(fetchMock).toHaveBeenCalledTimes(3);
});

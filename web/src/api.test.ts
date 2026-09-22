import { beforeEach, describe, expect, it, vi } from "vitest";
import {
  ApiError,
  beginAuthTransition,
  request,
  requestBlob,
  setAuthSession,
  write,
} from "./api";

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

type FetchCall = {
  path: string;
  method: string;
  accept?: string;
  signal?: AbortSignal | null;
};

beforeEach(() => {
  // 每个用例从干净世代开始，避免上一个用例的 abort 影响断言。
  beginAuthTransition();
  vi.unstubAllGlobals();
});

function stubFetch(handlers: Array<(call: FetchCall) => Response | Promise<Response>>) {
  const calls: FetchCall[] = [];
  let index = 0;
  vi.stubGlobal(
    "fetch",
    async (input: unknown, init: RequestInit = {}) => {
      const path = typeof input === "string" ? input : String(input);
      const call: FetchCall = {
        path,
        method: String(init.method || "GET"),
        accept: new Headers(init.headers).get("accept") || "",
        signal: init.signal,
      };
      calls.push(call);
      const handler = handlers[index++];
      if (!handler) throw new Error(`未预期的请求: ${call.method} ${path}`);
      return handler(call);
    },
  );
  return calls;
}

it("读请求遇到 401 时刷新会话后重放一次", async () => {
  setAuthSession(1);
  const calls = stubFetch([
    () => jsonResponse({ message: "未登录" }, 401),
    () => new Response(null, { status: 204 }),
    () => jsonResponse({ id: 7 }),
  ]);
  await expect(request<{ id: number }>("/api/posts")).resolves.toEqual({ id: 7 });
  expect(calls.map((call) => call.path)).toEqual([
    "/api/posts",
    "/api/refresh",
    "/api/posts",
  ]);
});

it("写请求遇到 401 不自动重放，避免跨账号执行非幂等操作", async () => {
  setAuthSession(1);
  const calls = stubFetch([() => jsonResponse({ message: "未登录" }, 401)]);
  await expect(write("/api/posts", { title: "投稿" })).rejects.toMatchObject({
    status: 401,
  });
  expect(calls.map((call) => call.path)).toEqual(["/api/posts"]);
});

it("刷新完成前切号，旧请求不得用新账号会话重放", async () => {
  setAuthSession(1);
  let resolveRefresh!: () => void;
  const calls = stubFetch([
    () => jsonResponse({ message: "未登录" }, 401),
    () =>
      new Promise<Response>((resolve) => {
        resolveRefresh = () => resolve(new Response(null, { status: 204 }));
      }),
    () => jsonResponse({ id: 7 }),
  ]);
  const pending = request<{ id: number }>("/api/posts");
  await vi.waitFor(() => expect(calls.length).toBe(2));
  setAuthSession(2);
  resolveRefresh();
  await expect(pending).rejects.toBeInstanceOf(ApiError);
  await expect(pending).rejects.toMatchObject({ status: 409, code: "auth_session_changed" });
  expect(calls.map((call) => call.path)).toEqual(["/api/posts", "/api/refresh"]);
});

it("切号或退出会中止在途请求", async () => {
  setAuthSession(1);
  let abortSignal: AbortSignal | undefined;
  vi.stubGlobal(
    "fetch",
    (_input: unknown, init: RequestInit = {}) =>
      new Promise<Response>((_resolve, reject) => {
        abortSignal = init.signal ?? undefined;
        init.signal?.addEventListener("abort", () =>
          reject(new DOMException("Aborted", "AbortError")),
        );
      }),
  );
  const pending = write("/api/posts", { title: "投稿" });
  await vi.waitFor(() => expect(abortSignal).toBeDefined());
  beginAuthTransition();
  await expect(pending).rejects.toBeInstanceOf(Error);
  expect(abortSignal?.aborted).toBe(true);
});

it("刷新失败后不会留下长期占用的刷新状态", async () => {
  setAuthSession(1);
  const calls = stubFetch([
    () => jsonResponse({ message: "未登录" }, 401),
    () => jsonResponse({ message: "刷新失败" }, 500),
    () => jsonResponse({ message: "未登录" }, 401),
    () => jsonResponse({ ok: true }),
    () => jsonResponse({ id: 9 }),
  ]);
  await expect(request("/api/posts")).rejects.toMatchObject({ status: 401 });
  await expect(request<{ id: number }>("/api/posts")).resolves.toEqual({ id: 9 });
  expect(calls.filter((call) => call.path === "/api/refresh").length).toBe(2);
});

function imageResponse(bytes = new Uint8Array([1, 2, 3]), status = 200) {
  return new Response(bytes, {
    status,
    headers: { "content-type": "image/png" },
  });
}

describe("受保护附件读取", () => {
  it("按图片协商内容，不把二进制当 JSON 解析", async () => {
    setAuthSession(1);
    const calls = stubFetch([() => imageResponse()]);
    const blob = await requestBlob("/api/feedback/attachments/7");
    expect(blob.size).toBe(3);
    expect(calls[0].accept).toContain("image/");
  });

  it("401 会刷新会话后重放一次，仍失败才报登录失效", async () => {
    setAuthSession(1);
    const calls = stubFetch([
      () => jsonResponse({ message: "未登录" }, 401),
      () => new Response(null, { status: 204 }),
      () => jsonResponse({ message: "未登录" }, 401),
    ]);
    await expect(requestBlob("/api/feedback/attachments/7")).rejects.toMatchObject({
      status: 401,
      code: "attachment_auth_expired",
    });
    expect(calls.map((call) => call.path)).toEqual([
      "/api/feedback/attachments/7",
      "/api/refresh",
      "/api/feedback/attachments/7",
    ]);
  });

  it("404 归类为无权查看，不报成接口数据格式错误", async () => {
    setAuthSession(1);
    stubFetch([() => new Response(null, { status: 404 })]);
    await expect(requestBlob("/api/feedback/attachments/8")).rejects.toMatchObject({
      status: 404,
      code: "attachment_unavailable",
      message: "无权查看该附件，或文件已被删除",
    });
  });

  it("切号会中止在途附件读取", async () => {
    setAuthSession(1);
    let abortSignal: AbortSignal | undefined;
    vi.stubGlobal(
      "fetch",
      (_input: unknown, init: RequestInit = {}) =>
        new Promise<Response>((_resolve, reject) => {
          abortSignal = init.signal ?? undefined;
          init.signal?.addEventListener("abort", () =>
            reject(new DOMException("Aborted", "AbortError")),
          );
        }),
    );
    const pending = requestBlob("/api/feedback/attachments/7");
    await vi.waitFor(() => expect(abortSignal).toBeDefined());
    beginAuthTransition();
    await expect(pending).rejects.toBeInstanceOf(Error);
    expect(abortSignal?.aborted).toBe(true);
  });
});

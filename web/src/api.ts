import { useQuery } from "@tanstack/react-query";
export type Entity = Record<string, any>;
export interface User extends Entity {
  id: number;
  nickname: string;
  role: string;
  avatar?: string;
}
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
  ) {
    super(message);
  }
}
let refreshing: { epoch: number; promise: Promise<Response> } | undefined;
let authEpoch = 0;
let authUserId: number | null = null;
const inFlight = new Set<AbortController>();

// 登录、退出和跨标签切号共享同一世代；世代变化后旧请求最多被取消，不能再重放。
export function beginAuthTransition() {
  authEpoch += 1;
  for (const controller of inFlight) controller.abort();
  inFlight.clear();
  refreshing = undefined;
}

export function setAuthSession(userId: number | null) {
  if (authUserId === userId) return;
  authUserId = userId;
  beginAuthTransition();
}

function isReadMethod(method: string) {
  return ["GET", "HEAD", "OPTIONS"].includes(method.toUpperCase());
}

async function send(path: string, init: RequestInit = {}): Promise<Response> {
  if (!path.startsWith("/api/")) throw new Error("业务请求必须使用同源 API");
  const headers = new Headers(init.headers);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  headers.set("X-Requested-With", "SYLUlive-Web");
  if (init.body && !(init.body instanceof FormData))
    headers.set("Content-Type", "application/json");
  const options = {
    ...init,
    headers,
    credentials: "same-origin" as RequestCredentials,
  };
  const requestEpoch = authEpoch;
  const requestUserId = authUserId;
  const controller = new AbortController();
  const abort = () => controller.abort();
  if (init.signal?.aborted) controller.abort();
  else init.signal?.addEventListener("abort", abort, { once: true });
  inFlight.add(controller);
  options.signal = controller.signal;
  try {
    let response = await fetch(path, options);
    if (requestEpoch !== authEpoch || requestUserId !== authUserId)
      throw new ApiError(409, "auth_session_changed", "账号已切换，请重新确认操作");
    if (
      response.status === 401 &&
      isReadMethod(String(options.method || "GET")) &&
      !["/api/login", "/api/refresh", "/api/logout"].includes(path)
    ) {
      const refreshEpoch = authEpoch;
      if (!refreshing || refreshing.epoch !== refreshEpoch) {
        const promise = fetch("/api/refresh", {
          method: "POST",
          credentials: "same-origin",
          headers: { "X-Requested-With": "SYLUlive-Web" },
        });
        refreshing = { epoch: refreshEpoch, promise };
        promise.finally(() => {
          if (refreshing?.promise === promise) refreshing = undefined;
        });
      }
      const refreshed = await refreshing.promise;
      if (requestEpoch !== authEpoch || requestUserId !== authUserId)
        throw new ApiError(409, "auth_session_changed", "账号已切换，请重新确认操作");
      if (refreshed.ok) response = await fetch(path, options);
    }
    return response;
  } finally {
    inFlight.delete(controller);
    init.signal?.removeEventListener("abort", abort);
  }
}

export async function request<T = Entity>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  const response = await send(path, init);
  const contentType = response.headers.get("content-type") || "";
  const data = contentType.includes("application/json")
    ? await response.json()
    : null;
  if (!response.ok)
    throw new ApiError(
      response.status,
      data?.code || "request_failed",
      data?.message || data?.error || `请求未完成（${response.status}）`,
    );
  if (data === null && response.status !== 204)
    throw new ApiError(502, "invalid_response", "接口没有返回可读取的数据");
  return data as T;
}

// 受保护的二进制读取：工单截图这类私有文件只能通过带鉴权的接口取，
// 不能把 file_id 拼成无鉴权的 /uploads 地址。错误按状态码分成可恢复与不可恢复两类，
// 让调用方能显示「登录已失效，请重新登录」而不是永久空白。
export async function requestBlob(
  path: string,
  init: RequestInit = {},
): Promise<Blob> {
  const response = await send(path, {
    ...init,
    headers: { ...(init.headers || {}), Accept: "image/*,application/octet-stream" },
  });
  if (!response.ok) {
    const status = response.status;
    throw new ApiError(
      status,
      status === 401
        ? "attachment_auth_expired"
        : status === 403 || status === 404
          ? "attachment_unavailable"
          : "request_failed",
      status === 401
        ? "登录已失效，重新登录后可查看附件"
        : status === 403 || status === 404
          ? "无权查看该附件，或文件已被删除"
          : `附件读取失败（${status}）`,
    );
  }
  return await response.blob();
}

export const write = <T = Entity>(
  path: string,
  body: unknown = {},
  method = "POST",
) =>
  request<T>(path, {
    method,
    body: body instanceof FormData ? body : JSON.stringify(body),
  });
export function useApi<T = Entity>(path: string | null) {
  return useQuery<T, Error>({
    queryKey: ["api", path],
    queryFn: ({ signal }) => request<T>(path!, { signal }),
    enabled: !!path,
    retry: false,
  });
}
export function rows(data: unknown, ...keys: string[]): Entity[] {
  if (Array.isArray(data)) return data;
  if (!data || typeof data !== "object") return [];
  const obj = data as Entity;
  for (const key of [
    ...keys,
    "items",
    "data",
    "list",
    "posts",
    "results",
    "tickets",
    "notifications",
    "events",
    "records",
  ])
    if (Array.isArray(obj[key])) return obj[key];
  if (obj.data && typeof obj.data === "object") return rows(obj.data, ...keys);
  return [];
}
export function entity(data: Entity | undefined, ...keys: string[]): Entity {
  if (!data) return {};
  for (const k of keys)
    if (data[k] && typeof data[k] === "object" && !Array.isArray(data[k]))
      return data[k];
  return data;
}
export function query(path: string, params: Record<string, unknown>) {
  const q = new URLSearchParams();
  Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== "") q.set(k, String(v));
  });
  return path + (q.size ? "?" + q : "");
}
export function asset(value: unknown): string | undefined {
  if (typeof value !== "string" || !value) return undefined;
  try {
    const u = new URL(value, location.origin);
    if (!["https:", "http:"].includes(u.protocol)) return undefined;
    // 同源上传地址、相对路径和线上资源都通过当前站点代理，避免浏览器直接请求被拦截。
    if (u.origin === location.origin || u.hostname === "sylulive.online")
      return u.pathname + u.search + u.hash;
    return u.href;
  } catch {
    return undefined;
  }
}
export async function upload(file: File): Promise<string> {
  const body = new FormData();
  body.append("file", file);
  const d = await write("/api/upload", body);
  const url = d.url || d.path || d.data?.url;
  if (typeof url !== "string") throw new Error("上传接口未返回文件地址");
  return url;
}
export function downloadJSON(name: string, value: unknown) {
  const u = URL.createObjectURL(
    new Blob([JSON.stringify(value, null, 2)], { type: "application/json" }),
  );
  const a = document.createElement("a");
  a.href = u;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(u), 1000);
}
export const errorText = (error: unknown) =>
  error instanceof Error ? error.message : "操作未完成，请重试";
export const time = (s: unknown) =>
  typeof s === "string" && Number.isFinite(Date.parse(s))
    ? new Date(s).toLocaleString("zh-CN", { hour12: false })
    : "";

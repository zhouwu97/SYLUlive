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
let refreshing: Promise<Response> | undefined;
export async function request<T = Entity>(
  path: string,
  init: RequestInit = {},
): Promise<T> {
  if (!path.startsWith("/api/")) throw new Error("业务请求必须使用同源 API");
  const headers = new Headers(init.headers);
  headers.set("Accept", "application/json");
  headers.set("X-Requested-With", "SYLUlive-Web");
  if (init.body && !(init.body instanceof FormData))
    headers.set("Content-Type", "application/json");
  const options = {
    ...init,
    headers,
    credentials: "same-origin" as RequestCredentials,
  };
  let response = await fetch(path, options);
  if (
    response.status === 401 &&
    !["/api/login", "/api/refresh", "/api/logout"].includes(path)
  ) {
    refreshing ||= fetch("/api/refresh", {
      method: "POST",
      credentials: "same-origin",
      headers: { "X-Requested-With": "SYLUlive-Web" },
    }).finally(() => {
      refreshing = undefined;
    });
    if ((await refreshing).ok) response = await fetch(path, options);
  }
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

import {
  isProvider,
  type AcademicProvider,
  type AssistantConnection,
} from "@sylulive/academic-contracts";

/**
 * hello 是页面重建界面用的只读快照，不是存储导出接口：只取本次请求来源
 * origin 名下的连接，并且只回传 provider、学号、姓名和代次令牌。
 * appUserId、origin、confirmed 属于扩展内部状态，一律不外泄。
 */
export function pickHelloConnections(
  storage: Record<string, unknown>,
  origin: string,
): AssistantConnection[] {
  const prefix = `connection:${origin}:`,
    result: AssistantConnection[] = [];
  for (const [key, value] of Object.entries(storage)) {
    if (!key.startsWith(prefix)) continue;
    const provider = key.slice(prefix.length);
    if (!isProvider(provider)) continue;
    const c = value as Record<string, unknown> | undefined;
    if (!c || typeof c.studentId !== "string" || typeof c.epoch !== "string")
      continue;
    result.push({
      provider: provider as AcademicProvider,
      studentId: c.studentId,
      displayName: typeof c.displayName === "string" ? c.displayName : "",
      epoch: c.epoch,
      state: c.state === "expired" ? "expired" : "connected",
    });
  }
  return result;
}

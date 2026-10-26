import { useCallback, useEffect, useRef, useState } from "react";
import {
  isProvider,
  type AcademicProvider,
  type AssistantConnection,
} from "@sylulive/academic-contracts";
import { bridge } from "./bridge";

export type AssistantProbeState = "idle" | "checking" | "ready" | "missing";
type HelloResult = {
  extensionVersion?: unknown;
  capabilities?: unknown;
  connections?: unknown;
  authorized?: unknown;
};

export type AssistantProbe = {
  state: AssistantProbeState;
  extensionVersion: string;
  capabilityCount: number;
  connections: AssistantConnection[];
  /**
   * undefined 表示本机助手版本还没有上报授权状态。此时按「未知」处理：
   * 不显示授权提示，也不为授权继续轮询。
   */
  authorized: Partial<Record<AcademicProvider, boolean>> | undefined;
  recheck: () => void;
  setPaused: (paused: boolean) => void;
  markReady: () => void;
};

// hello 的结果来自扩展的消息注入，属于系统边界，字段一律重新判定后再用。
function parseConnections(value: unknown): AssistantConnection[] {
  if (!Array.isArray(value)) return [];
  const list: AssistantConnection[] = [];
  for (const item of value) {
    const c = item as Partial<AssistantConnection> | null;
    if (
      !c ||
      !isProvider(c.provider) ||
      typeof c.studentId !== "string" ||
      typeof c.epoch !== "string"
    )
      continue;
    list.push({
      provider: c.provider,
      studentId: c.studentId,
      displayName: typeof c.displayName === "string" ? c.displayName : "",
      epoch: c.epoch,
      state: c.state === "expired" ? "expired" : "connected",
    });
  }
  return list;
}
function parseAuthorized(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value))
    return undefined;
  const out: Partial<Record<AcademicProvider, boolean>> = {};
  for (const [key, granted] of Object.entries(value))
    if (isProvider(key)) out[key] = granted === true;
  return out;
}

/**
 * hello 要等约 1.8 秒才超时，所以轮询必须由上一次探测结束后再排队，
 * 并把下一次放进同一个定时器槽位，避免重排时叠加出并发请求。
 */
export function useAssistantProbe({
  intervalMs = 1500,
  autoStart = true,
  watchProvider,
}: {
  intervalMs?: number;
  autoStart?: boolean;
  watchProvider?: AcademicProvider;
} = {}): AssistantProbe {
  const [state, setState] = useState<AssistantProbeState>(autoStart ? "checking" : "idle"),
    [extensionVersion, setExtensionVersion] = useState(""),
    [capabilityCount, setCapabilityCount] = useState(0),
    [connections, setConnections] = useState<AssistantConnection[]>([]),
    [authorized, setAuthorized] = useState<
      Partial<Record<AcademicProvider, boolean>> | undefined
    >(undefined);
  const commands = useRef<
    | {
        recheck: () => void;
        markReady: () => void;
        setPaused: (paused: boolean) => void;
      }
    | undefined
  >(undefined);

  useEffect(() => {
    let alive = true,
      polling = autoStart,
      paused = false,
      inFlight = false,
      timer: ReturnType<typeof setTimeout> | undefined;

    const schedule = () => {
      clearTimeout(timer);
      if (polling) timer = setTimeout(run, intervalMs);
    };
    async function probe() {
      if (inFlight) return;
      inFlight = true;
      // 复检期间保持 missing，否则安装步骤会在每个轮询周期被「正在检测…」顶掉。
      setState((previous) => (previous === "ready" || previous === "missing" ? previous : "checking"));
      try {
        const data = await bridge<HelloResult>("hello");
        if (!alive) return;
        const granted = parseAuthorized(data?.authorized),
          known = parseConnections(data?.connections);
        setExtensionVersion(String(data?.extensionVersion || ""));
        setCapabilityCount(Array.isArray(data?.capabilities) ? data.capabilities.length : 0);
        setAuthorized(granted);
        setConnections(known);
        // 握手不含网络请求，所以确认到「本机还未授权这个学校系统」时值得继续轮询，
        // 用户在助手页点完授权后本页就能免刷新恢复；未上报授权状态的老助手
        // 保持「ready 即停」，不会退化成无限轮询。
        polling = watchProvider !== undefined && granted?.[watchProvider] === false;
        schedule();
        setState("ready");
      } catch {
        if (!alive) return;
        setState("missing");
        schedule();
      } finally {
        inFlight = false;
      }
    }
    function run() {
      if (!alive) return;
      if (paused) {
        schedule();
        return;
      }
      void probe();
    }

    commands.current = {
      recheck: () => {
        if (!alive) return;
        polling = true;
        void probe();
      },
      markReady: () => {
        if (!alive) return;
        polling = false;
        clearTimeout(timer);
        setState("ready");
      },
      setPaused: (value: boolean) => {
        if (!alive) return;
        paused = value;
        if (!value) schedule();
      },
    };
    if (autoStart) void probe();
    return () => {
      alive = false;
      clearTimeout(timer);
      commands.current = undefined;
    };
  }, [autoStart, intervalMs, watchProvider]);

  const recheck = useCallback(() => commands.current?.recheck(), []),
    markReady = useCallback(() => commands.current?.markReady(), []),
    setPaused = useCallback((paused: boolean) => commands.current?.setPaused(paused), []);

  return {
    state,
    extensionVersion,
    capabilityCount,
    connections,
    authorized,
    recheck,
    setPaused,
    markReady,
  };
}

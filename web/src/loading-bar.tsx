// 桌面网页顶部的加载进度条：首次读取数据或懒加载页面时出现，让点击后立刻有回应。
// 只统计还没有数据的读取（status === "pending"），后台刷新、轮询不会让进度条闪烁。
import { useEffect, useState, useSyncExternalStore } from "react";
import { useIsFetching } from "@tanstack/react-query";

let suspended = 0;
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => { listeners.add(listener); return () => { listeners.delete(listener); }; };

/** 懒加载页面的 Suspense 占位：挂载期间让顶部进度条保持前进，并显示页面骨架。 */
export function PageLoading({ label = "正在加载页面…" }: { label?: string }) {
  useEffect(() => {
    suspended += 1;
    listeners.forEach((listener) => listener());
    return () => {
      suspended -= 1;
      listeners.forEach((listener) => listener());
    };
  }, []);
  return (
    <div className="loading-state loading-page" role="status">
      <span className="loading-label">{label}</span>
    </div>
  );
}

type Phase = "idle" | "active" | "done";

export function LoadingBar() {
  const fetching = useIsFetching({ predicate: (query) => query.state.status === "pending" && query.state.fetchStatus === "fetching" });
  const lazy = useSyncExternalStore(subscribe, () => suspended, () => 0);
  const busy = fetching + lazy > 0;
  const [phase, setPhase] = useState<Phase>("idle");
  useEffect(() => {
    if (busy) {
      // 120ms 内完成的读取不显示，避免每次点击都闪一下。
      const timer = setTimeout(() => setPhase("active"), 120);
      return () => clearTimeout(timer);
    }
    setPhase((current) => (current === "active" ? "done" : current));
  }, [busy]);
  useEffect(() => {
    if (phase !== "done") return;
    const timer = setTimeout(() => setPhase("idle"), 520);
    return () => clearTimeout(timer);
  }, [phase]);
  return <div className="route-progress" data-phase={phase} aria-hidden="true"><span /></div>;
}

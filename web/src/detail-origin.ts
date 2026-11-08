// 详情页的来源分区：帖子 / 投票详情没有独立的导航归属，外壳（侧栏选中、集市收起、分区渐变）跟随进入它的列表页。
// 路由 state.from 同步可读；直接打开详情时由详情页按内容类型兜底上报（例如闲置帖归集市）。
import { useEffect, useSyncExternalStore } from "react";

let reported = "";
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const publish = (value: string) => {
  if (reported === value) return;
  reported = value;
  listeners.forEach((listener) => listener());
};

/** 详情页上报自己的来源路径（含查询串），卸载时清空。 */
export function useReportDetailOrigin(path: string) {
  useEffect(() => {
    publish(path);
    return () => publish("");
  }, [path]);
}

export function useReportedDetailOrigin() {
  return useSyncExternalStore(subscribe, () => reported, () => "");
}

/** 详情路由：/post/:id、/polls/:id */
export const isDetailPath = (pathname: string) => /^\/(post|polls)\/[^/]+/.test(pathname);

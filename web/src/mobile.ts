import { useSyncExternalStore } from "react";
import type { AcademicTerm } from "@sylulive/academic-contracts";

const phoneQuery = "(max-width: 600px)";
function subscribe(listener: () => void) {
  const media = window.matchMedia(phoneQuery);
  media.addEventListener("change", listener);
  return () => media.removeEventListener("change", listener);
}

export function useMobile() {
  return useSyncExternalStore(subscribe, () => window.matchMedia(phoneQuery).matches, () => false);
}

export function mobileTermLabel(term: AcademicTerm) {
  const semester = ["12", "2"].includes(term.semester) ? "第二" : "第一";
  return `${term.year}-${Number(term.year) + 1} ${semester}学期`;
}

export function mobilePostTime(value: unknown) {
  if (typeof value !== "string") return "";
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return "";
  const minutes = Math.max(0, Math.floor((Date.now() - date.getTime()) / 60000));
  if (minutes < 1) return "刚刚";
  if (minutes < 60) return `${minutes}分钟前`;
  if (minutes < 1440) return `${Math.floor(minutes / 60)}小时前`;
  if (minutes < 10080) return `${Math.floor(minutes / 1440)}天前`;
  return date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
}

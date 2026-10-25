import { useEffect, useLayoutEffect, useRef } from "react";

// 先确定新页面的最终宽度，再补偿位移；商品网格不会在收展途中反复换列。
export function useWorkspaceMotion(route: string, enabled: boolean) {
  const workspace = useRef<HTMLElement>(null);
  const targetLeft = useRef<number | null>(null);
  const motion = useRef<Animation | null>(null);

  useLayoutEffect(() => {
    const node = workspace.current;
    if (!node) return;
    const transform = getComputedStyle(node).transform;
    const offset = transform === "none" ? 0 : new DOMMatrixReadOnly(transform).m41;
    const previous = targetLeft.current === null ? null : targetLeft.current + offset;
    motion.current?.cancel();
    motion.current = null;
    const next = node.getBoundingClientRect().left;
    targetLeft.current = next;
    if (previous === null || !enabled || window.matchMedia("(prefers-reduced-motion: reduce)").matches || window.matchMedia("(max-width: 760px)").matches) return;
    const distance = previous - next;
    if (Math.abs(distance) < .5) return;
    // 中途反向时读取当前可见位置，取消旧动画后从同一位置继续。
    motion.current = node.animate([
      { transform: `translateX(${distance}px)` },
      { transform: "translateX(0)" },
    ], { duration: 220, easing: "cubic-bezier(.23, 1, .32, 1)" });
  }, [route, enabled]);

  useEffect(() => {
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");
    const reset = () => {
      motion.current?.cancel();
      motion.current = null;
      targetLeft.current = workspace.current?.getBoundingClientRect().left ?? null;
    };
    window.addEventListener("resize", reset);
    reduced.addEventListener("change", reset);
    return () => {
      window.removeEventListener("resize", reset);
      reduced.removeEventListener("change", reset);
      motion.current?.cancel();
    };
  }, []);
  return workspace;
}

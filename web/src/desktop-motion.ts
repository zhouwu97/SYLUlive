// 桌面网页（≥601px）的导航动效：顶栏、侧栏、页面标签与分段控件的选中块滑动，
// 收起侧栏时的名称提示，深浅色圆形展开。手机网页对照 Android App，600px 及以下全部不生效。
import { useEffect, useRef } from "react";

const desktopQuery = "(min-width: 601px)";
const reducedQuery = "(prefers-reduced-motion: reduce)";
const isDesktop = () => window.matchMedia(desktopQuery).matches;

/**
 * 在容器里放一块跟随当前项滑动的底色。
 * 当前项由 activeSelector 决定；路由切换只改 class，所以用 MutationObserver 监听，
 * 侧栏收展、分组展开导致的尺寸变化由 ResizeObserver 即时跟随（不做动画，避免滞后）。
 */
type Position = { x: number; y: number; w: number; h: number; at: number };
// 记住每组标签最后的位置；同一组在这段时间内重新挂载视为同一次切换
const memory = new Map<string, Position>();
const REMOUNT_WINDOW = 1500;
// 用选择器、容器类名和各项文字识别「同一组」标签，与具体 DOM 节点无关
const slotOf = (container: HTMLElement, activeSelector: string) => [
  activeSelector,
  container.className.replace(/\bhas-nav-ind\b/g, "").trim(),
  [...container.children].filter((child) => !child.classList.contains("nav-ind")).map((child) => child.textContent?.trim()).join("/"),
].join("|");

export function mountSlidingIndicator(container: HTMLElement, activeSelector: string): () => void {
  const ind = document.createElement("span");
  ind.className = "nav-ind";
  ind.setAttribute("aria-hidden", "true");
  container.prepend(ind);
  container.classList.add("has-nav-ind");
  let current: HTMLElement | null = null;
  let frame = 0;
  // 同一路由可能有多个匹配项（/community?sort=bookmarks 时「校园社区」与「我的收藏」都带 active），
  // 取最后一个，即更具体的入口；并标记出来，让其余匹配项退回普通样式，只高亮一处。
  const find = () => {
    const all = container.querySelectorAll<HTMLElement>(activeSelector);
    return all.length ? all[all.length - 1] : null;
  };

  const slot = slotOf(container, activeSelector);
  let first = true;
  const mountedAt = performance.now();
  // 挂载时读到的上一次位置（用于开发模式 StrictMode 的模拟卸载后还原）
  const inherited = memory.get(slot);
  const set = (pos: Position) => {
    ind.style.width = `${pos.w}px`;
    ind.style.height = `${pos.h}px`;
    ind.style.transform = `translate(${pos.x}px, ${pos.y}px)`;
  };

  const place = (instant: boolean) => {
    const target = find();
    container.querySelectorAll<HTMLElement>("[data-ind-current]").forEach((el) => { if (el !== target) delete el.dataset.indCurrent; });
    if (target) target.dataset.indCurrent = "";
    const box = container.getBoundingClientRect();
    const rect = target?.getBoundingClientRect();
    if (!target || !rect || !rect.width || !rect.height || !box.width || !isDesktop()) {
      ind.style.opacity = "0";
      ind.classList.remove("is-ready");
      return;
    }
    const next: Position = {
      x: rect.left - box.left + container.scrollLeft,
      y: rect.top - box.top + container.scrollTop,
      w: rect.width,
      h: rect.height,
      at: performance.now(),
    };
    const previous = memory.get(slot);
    memory.set(slot, next);
    // 页面随 URL 参数整页重建（首页排序、社区标签、集市分类）时，新滑块从上一次的位置滑过来
    if (first && previous && next.at - previous.at < REMOUNT_WINDOW && (previous.x !== next.x || previous.y !== next.y)) {
      first = false;
      ind.classList.remove("is-ready");
      ind.style.opacity = "";
      set(previous);
      void ind.offsetWidth; // 先提交旧位置，再打开过渡移到新位置
      ind.classList.add("is-ready");
      set(next);
      return;
    }
    first = false;
    // 首次出现或从隐藏恢复时直接就位，之后的位置变化才滑动
    if (instant || ind.style.opacity === "0") ind.classList.remove("is-ready");
    ind.style.opacity = "";
    set(next);
    if (!ind.classList.contains("is-ready")) {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => { frame = requestAnimationFrame(() => ind.classList.add("is-ready")); });
    }
  };

  // 尺寸变化分两种：
  // 1) 侧栏收展这类持续变化 —— 即时跟随，否则滑块会落后于条目；
  // 2) 切换选中项时文字变粗导致的一次性变化 —— 必须仍然滑动，否则过渡会被取消成瞬移。
  // 用「距上次选中项变化多久」区分；开始监听新目标时的初始回调也忽略。
  const SELECTION_SETTLE = 160;
  let lastSelection = 0;
  const sizes = new WeakMap<Element, string>();
  const resize = new ResizeObserver((entries) => {
    let changed = false;
    for (const entry of entries) {
      const size = `${Math.round(entry.contentRect.width)}x${Math.round(entry.contentRect.height)}`;
      if (sizes.has(entry.target) && sizes.get(entry.target) !== size) changed = true;
      sizes.set(entry.target, size);
    }
    if (changed) place(performance.now() - lastSelection > SELECTION_SETTLE);
  });
  const track = () => {
    const next = find();
    if (next === current) return;
    if (current) resize.unobserve(current);
    current = next;
    if (current) resize.observe(current);
  };
  const mutation = new MutationObserver((records) => {
    if (records.every((record) => record.target === ind)) return;
    lastSelection = performance.now();
    track();
    requestAnimationFrame(() => place(false));
  });
  mutation.observe(container, { subtree: true, childList: true, attributes: true, attributeFilter: ["class", "open"] });
  resize.observe(container);
  track();
  place(true);
  const media = window.matchMedia(desktopQuery);
  const onMedia = () => place(true);
  media.addEventListener("change", onMedia);
  // 「学习与成长」展开动画期间下方条目会整体下移，逐帧跟随；其他元素的悬停过渡不处理
  let followUntil = 0, followFrame = 0;
  const follow = () => {
    place(true);
    if (performance.now() < followUntil) followFrame = requestAnimationFrame(follow);
  };
  const onTransition = (event: TransitionEvent) => {
    if (event.pseudoElement !== "::details-content" && !(event.target as Element).matches?.("details")) return;
    followUntil = performance.now() + 480;
    cancelAnimationFrame(followFrame);
    followFrame = requestAnimationFrame(follow);
  };
  container.addEventListener("transitionrun", onTransition);
  container.addEventListener("transitionend", onTransition);

  return () => {
    mutation.disconnect();
    resize.disconnect();
    media.removeEventListener("change", onMedia);
    container.removeEventListener("transitionrun", onTransition);
    container.removeEventListener("transitionend", onTransition);
    cancelAnimationFrame(frame);
    cancelAnimationFrame(followFrame);
    // 从卸载时刻起计算重新挂载的时间窗
    // StrictMode 会在挂载后立即模拟一次卸载再挂载；这时还原挂载前的旧位置，第二次挂载才能照常滑动
    const last = performance.now() - mountedAt < 100 && inherited ? inherited : memory.get(slot);
    if (last) memory.set(slot, { ...last, at: performance.now() });
    ind.remove();
    container.classList.remove("has-nav-ind");
  };
}

/** 给页面里的标签栏、分段控件挂上滑动选中块；容器卸载时自动清理。 */
export function useSlidingIndicator<T extends HTMLElement>(activeSelector: string) {
  const ref = useRef<T>(null);
  useEffect(() => {
    const node = ref.current;
    return node ? mountSlidingIndicator(node, activeSelector) : undefined;
  }, [activeSelector]);
  return ref;
}

/**
 * 侧栏收成图标栏（集市页、601–860px）时，悬停条目立即显示名称。
 * 链接本身保留 title（无障碍与测试依赖），悬停期间暂时移走，避免与系统提示重复。
 */
export function mountCollapsedTooltips(sidebar: HTMLElement): () => void {
  const tip = document.createElement("div");
  tip.className = "nav-tip";
  tip.setAttribute("aria-hidden", "true");
  document.body.append(tip);
  let owner: HTMLElement | null = null;

  const collapsed = () => isDesktop() && sidebar.getBoundingClientRect().width < 120;
  const restore = () => {
    if (owner?.dataset.navTitle) {
      owner.setAttribute("title", owner.dataset.navTitle);
      delete owner.dataset.navTitle;
    }
    owner = null;
    tip.classList.remove("is-shown");
  };
  const over = (event: Event) => {
    const item = (event.target as Element).closest<HTMLElement>(".nav-item");
    if (item === owner) return;
    restore();
    if (!item || !collapsed()) return;
    const label = item.getAttribute("aria-label") || item.textContent?.trim() || "";
    if (!label) return;
    owner = item;
    const title = item.getAttribute("title");
    if (title) { item.dataset.navTitle = title; item.removeAttribute("title"); }
    const rect = item.getBoundingClientRect();
    tip.textContent = label;
    tip.style.left = `${Math.round(rect.right + 10)}px`;
    tip.style.top = `${Math.round(rect.top + rect.height / 2)}px`;
    tip.classList.add("is-shown");
  };
  sidebar.addEventListener("pointerover", over);
  sidebar.addEventListener("pointerleave", restore);
  sidebar.addEventListener("scroll", restore, { passive: true });
  sidebar.addEventListener("click", restore);
  return () => {
    restore();
    sidebar.removeEventListener("pointerover", over);
    sidebar.removeEventListener("pointerleave", restore);
    sidebar.removeEventListener("scroll", restore);
    sidebar.removeEventListener("click", restore);
    tip.remove();
  };
}

/**
 * 深浅色切换：新主题从按钮位置圆形展开。
 * 不支持 View Transitions、减少动态效果或手机端时直接切换。apply 必须同步改好 DOM。
 */
export function revealTheme(from: Element | null, apply: () => void) {
  const doc = document as Document & { startViewTransition?: (update: () => void) => { ready: Promise<void> } };
  if (!from || !doc.startViewTransition || !isDesktop() || window.matchMedia(reducedQuery).matches) {
    apply();
    return;
  }
  const rect = from.getBoundingClientRect();
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2;
  const radius = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y));
  const transition = doc.startViewTransition(apply);
  transition.ready.then(() => {
    document.documentElement.animate(
      { clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${radius}px at ${x}px ${y}px)`] },
      { duration: 560, easing: "cubic-bezier(.22, 1, .36, 1)", pseudoElement: "::view-transition-new(root)" },
    );
  }).catch(() => undefined);
}

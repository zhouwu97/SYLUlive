// 首页信息流的负反馈（不感兴趣、不看 TA）在本页立即生效的本地状态。
// 服务端负责长期过滤与降权；这里只保证点击后卡片马上收起、可以撤销，
// 并且只作用于传入 feedSource 的信息流卡片，搜索结果、收藏、个人主页照常显示。
import { useSyncExternalStore } from "react";
import { write } from "./api";

export type FeedSource = "all" | "time" | "featured" | "following";
export type Dismissal =
  | { kind: "post"; postId: number }
  | { kind: "author"; authorId: number; postId: number; authorName: string };

type State = { owner: number | null; posts: Map<number, Dismissal>; authors: Map<number, Dismissal> };

let state: State = { owner: null, posts: new Map(), authors: new Map() };
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((listener) => listener());

function update(next: Partial<Omit<State, "owner">>) {
  state = { ...state, ...next };
  emit();
}

/** 账号切换后丢弃上一个账号的临时状态，避免把 A 的「不感兴趣」带给 B。 */
function ensureOwner(userId: number | null) {
  if (state.owner === userId) return;
  state = { owner: userId, posts: new Map(), authors: new Map() };
}

/** 服务端只接受这四种来源；热门、社区筛选等其他入口统一按「推荐」记录。 */
export function feedSourceOf(sort: string | null | undefined): FeedSource {
  return sort === "time" || sort === "featured" || sort === "following" ? sort : "all";
}

export function markDismissed(userId: number, dismissal: Dismissal) {
  ensureOwner(userId);
  if (dismissal.kind === "post") update({ posts: new Map(state.posts).set(dismissal.postId, dismissal) });
  else update({ authors: new Map(state.authors).set(dismissal.authorId, dismissal) });
}

export function clearDismissed(userId: number, dismissal: Dismissal) {
  if (state.owner !== userId) return;
  if (dismissal.kind === "post") {
    const posts = new Map(state.posts);
    posts.delete(dismissal.postId);
    update({ posts });
  } else {
    const authors = new Map(state.authors);
    authors.delete(dismissal.authorId);
    update({ authors });
  }
}

/** 卡片在当前信息流中的去留：placeholder 显示撤销条，hidden 直接不渲染。 */
export function dismissalFor(userId: number | null | undefined, postId: number, authorId: number | undefined):
  { mode: "visible" } | { mode: "placeholder"; dismissal: Dismissal } | { mode: "hidden" } {
  if (!userId || state.owner !== userId) return { mode: "visible" };
  const post = state.posts.get(postId);
  if (post) return { mode: "placeholder", dismissal: post };
  const author = authorId ? state.authors.get(authorId) : undefined;
  if (author) return author.postId === postId ? { mode: "placeholder", dismissal: author } : { mode: "hidden" };
  return { mode: "visible" };
}

export function useDismissals() {
  return useSyncExternalStore(
    (listener) => { listeners.add(listener); return () => { listeners.delete(listener); }; },
    () => state,
    () => state,
  );
}

export const feedFeedbackApi = {
  notInterested: (postId: number, source: FeedSource) =>
    write(`/api/feed/posts/${postId}/not-interested?source=${source}`, {}, "PUT"),
  undoNotInterested: (postId: number) => write(`/api/feed/posts/${postId}/not-interested`, {}, "DELETE"),
  hideAuthor: (authorId: number) => write(`/api/feed/authors/${authorId}/hidden`, {}, "PUT"),
  restoreAuthor: (authorId: number) => write(`/api/feed/authors/${authorId}/hidden`, {}, "DELETE"),
};

/** 仅供测试重置模块状态。 */
export function resetDismissalsForTest() {
  state = { owner: null, posts: new Map(), authors: new Map() };
  emit();
}

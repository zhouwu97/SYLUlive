import { useEffect, useRef, useState, type ReactNode } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Link } from "react-router-dom";
import { ApiError, query, request, rows, write, type Entity } from "./api";
import { useAuth } from "./auth";
import { Icon, useUI } from "./ui";

// 会话初始化会取消同帧启动的读取；只重试一次被取消的读请求，不重放写操作。
export function retryInterruptedRead(count: number, error: Error) {
  return count < 1 && (error.name === "AbortError" || (error instanceof ApiError && error.code === "auth_session_changed"));
}

function CopyLink({ url }: { url: string }) {
  return (
    <div className="post-copy-link">
      <p>暂时无法自动复制。选中下方链接后，可手动复制分享。</p>
      <label>
        帖子链接
        <input value={url} readOnly onFocus={(event) => event.currentTarget.select()} />
      </label>
    </div>
  );
}

export function postShareURL(post: Entity) {
  return `${window.location.origin}/web/${post.poll_meta?.id ? `polls/${post.poll_meta.id}` : `post/${post.id}`}`;
}

/** 复制帖子链接；剪贴板不可用时退回到可手动选中的链接弹窗。 */
export async function copyPostLink(post: Entity, ui: ReturnType<typeof useUI>) {
  const url = postShareURL(post);
  try {
    await navigator.clipboard.writeText(url);
    ui.notify("帖子链接已复制");
  } catch {
    ui.open("分享帖子", <CopyLink url={url} />);
  }
}

type LikeState = { liked: boolean; count: number };

export function PostActions({
  post,
  from,
  onComment,
  more,
}: {
  post: Entity;
  from?: string;
  onComment?: () => void;
  more?: ReactNode;
}) {
  const auth = useAuth(), ui = useUI(), qc = useQueryClient();
  const [pending, setPending] = useState("");
  // 点赞先在本地切换，服务端确认前按钮保持忙碌；失败时回到原状态。
  const [likeOverride, setLikeOverride] = useState<LikeState | null>(null);
  const [popped, setPopped] = useState(false);
  const locked = useRef(false);
  const serverLike = `${!!post.is_liked}:${Number(post.like_count) || 0}`;
  const lastServerLike = useRef(serverLike);
  useEffect(() => {
    if (lastServerLike.current === serverLike) return;
    lastServerLike.current = serverLike;
    // 列表重新读取到新的服务端状态后，以服务端为准。
    if (!locked.current) setLikeOverride(null);
  }, [serverLike]);
  const like: LikeState = likeOverride ?? { liked: !!post.is_liked, count: Number(post.like_count) || 0 };
  const bookmarkKey = ["api", "post-bookmark-ids", auth.user?.id];
  // 收藏列表有分页；完整读取后才判断未收藏，避免把第二页的收藏误判为未收藏。
  const bookmarks = useQuery({
    queryKey: bookmarkKey,
    enabled: !!auth.user,
    retry: retryInterruptedRead,
    queryFn: async ({ signal }) => {
      const ids = new Set<number>();
      for (let page = 1; ; page++) {
        const data = await request<Entity>(query("/api/user/bookmarks", { page, limit: 50 }), { signal });
        const previousSize = ids.size;
        rows(data).forEach((item) => ids.add(Number(item.id)));
        if (!data.has_more) return [...ids];
        if (ids.size === previousSize) throw new Error("收藏列表读取不完整，请重试");
      }
    },
  });
  const bookmarked = !!auth.user && !!bookmarks.data?.includes(Number(post.id));
  async function mutate(action: "like" | "bookmark") {
    if (locked.current || !auth.requireUser()) return;
    locked.current = true;
    setPending(action);
    try {
      if (action === "bookmark" && bookmarks.error) {
        const result = await bookmarks.refetch();
        ui.notify(result.error ? result.error.message : "收藏状态已更新，可继续操作");
        return;
      }
      if (action === "like") {
        const previous = like;
        const next = { liked: !previous.liked, count: Math.max(0, previous.count + (previous.liked ? -1 : 1)) };
        setLikeOverride(next);
        if (next.liked) setPopped(true);
        const ok = await ui.act(
          () => write(`/api/posts/${post.id}/like`, {}, previous.liked ? "DELETE" : "POST"),
          previous.liked ? "已取消点赞" : "已点赞",
        );
        if (!ok) { setLikeOverride(previous); setPopped(false); }
        return;
      }
      const id = Number(post.id), was = bookmarked;
      const toggle = (ids: number[] | undefined) => was ? (ids || []).filter((item) => item !== id) : [...(ids || []), id];
      qc.setQueryData<number[]>(bookmarkKey, toggle);
      const ok = await ui.act(
        () => write(`/api/posts/${post.id}/bookmark`, {}, was ? "DELETE" : "PUT"),
        was ? "已取消收藏" : "已收藏",
      );
      if (!ok) qc.setQueryData<number[]>(bookmarkKey, (ids) => was ? [...(ids || []).filter((item) => item !== id), id] : (ids || []).filter((item) => item !== id));
    } finally {
      locked.current = false;
      setPending("");
    }
  }
  async function share() {
    if (locked.current) return;
    locked.current = true;
    setPending("share");
    try {
      await copyPostLink(post, ui);
    } finally {
      locked.current = false;
      setPending("");
    }
  }
  const commentContent = <><Icon name="community" size={19} /><span className="post-action-label">评论</span><span className="post-action-count">{post.reply_count || 0}</span></>;
  return (
    <div className="post-toolbar">
      <div className="post-interactions" role="group" aria-label="帖子互动">
        <button type="button" className={`post-interaction post-like${popped ? " is-popped" : ""}`} aria-pressed={like.liked} aria-busy={pending === "like"} disabled={!!pending || auth.loading} onClick={() => mutate("like")} onAnimationEnd={() => setPopped(false)}>
          <Icon name="heart" size={19} /><span className="post-action-label">{like.liked ? "已赞" : "点赞"}</span><span className="post-action-count">{like.count}</span>
        </button>
        {onComment ? <button type="button" className="post-interaction" onClick={onComment}>{commentContent}</button> : <Link className="post-interaction" to={`/post/${post.id}#post-comments`} state={{ from }}>{commentContent}</Link>}
        <button type="button" className="post-interaction" title={bookmarks.error?.message} aria-pressed={bookmarked} aria-busy={pending === "bookmark" || (!!auth.user && bookmarks.isPending)} disabled={!!pending || auth.loading || (!!auth.user && bookmarks.isPending)} onClick={() => mutate("bookmark")}>
          <Icon name="bookmark" size={19} /><span className="post-action-label">{bookmarks.error ? "重试收藏" : bookmarked ? "已收藏" : "收藏"}</span>
        </button>
        <button type="button" className="post-interaction" aria-busy={pending === "share"} disabled={!!pending} onClick={share}>
          <Icon name="share" size={19} /><span className="post-action-label">分享</span>
        </button>
      </div>
      {more}
    </div>
  );
}

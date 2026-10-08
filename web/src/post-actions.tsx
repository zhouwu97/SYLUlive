import { useRef, useState, type ReactNode } from "react";
import { useQuery } from "@tanstack/react-query";
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
  const auth = useAuth(), ui = useUI();
  const [pending, setPending] = useState("");
  const locked = useRef(false);
  // 收藏列表有分页；完整读取后才判断未收藏，避免把第二页的收藏误判为未收藏。
  const bookmarks = useQuery({
    queryKey: ["api", "post-bookmark-ids", auth.user?.id],
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
      await ui.act(
        () => write(`/api/posts/${post.id}/${action}`, {}, action === "like" ? (post.is_liked ? "DELETE" : "POST") : (bookmarked ? "DELETE" : "PUT")),
        action === "like" ? (post.is_liked ? "已取消点赞" : "已点赞") : (bookmarked ? "已取消收藏" : "已收藏"),
      );
    } finally {
      locked.current = false;
      setPending("");
    }
  }
  async function share() {
    if (locked.current) return;
    locked.current = true;
    setPending("share");
    const url = `${window.location.origin}/web/post/${post.id}`;
    try {
      await navigator.clipboard.writeText(url);
      ui.notify("帖子链接已复制");
    } catch {
      ui.open("分享帖子", <CopyLink url={url} />);
    } finally {
      locked.current = false;
      setPending("");
    }
  }
  const commentContent = <><Icon name="community" size={19} /><span className="post-action-label">评论</span><span className="post-action-count">{post.reply_count || 0}</span></>;
  return (
    <div className="post-toolbar">
      <div className="post-interactions" role="group" aria-label="帖子互动">
        <button type="button" className="post-interaction" aria-pressed={!!post.is_liked} aria-busy={pending === "like"} disabled={!!pending || auth.loading} onClick={() => mutate("like")}>
          <Icon name="heart" size={19} /><span className="post-action-label">{post.is_liked ? "已赞" : "点赞"}</span><span className="post-action-count">{post.like_count || 0}</span>
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

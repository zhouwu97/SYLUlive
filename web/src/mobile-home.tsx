import { useHomeFeed } from "./home-feed";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { ApiError, query, rows, useApi } from "./api";
import { useAuth } from "./auth";
import { isPublicPost } from "./campus-chrome";
import { PostCard } from "./community";
import { feedSourceOf } from "./feed-feedback";
import { Empty, Icon, QueryState } from "./ui";

export function MobileHome() {
  const auth = useAuth(), navigate = useNavigate();
  const [params] = useSearchParams();
  const sort = params.get("sort") || "all";
  const replies = useApi(auth.user ? "/api/notifications/replies/unread?limit=3" : null);
  const feed = useHomeFeed(sort, sort === "featured" ? "/api/posts/featured" : "/api/posts");
  const pages = feed.data?.pages || [];
  const posts = [...new Map(pages.flatMap(page => rows(page, "posts")).map(post => [post.id, post])).values()];
  const pinned = [...new Map([...rows(pages[0], "pinned_posts"), ...posts].filter(isPublicPost).map(post => [post.id, post])).values()];
  const content = posts.filter(post => !pinned.some(item => item.id === post.id));
  const nextPageFailed = Boolean(feed.isFetchNextPageError);
  const refreshFailed = Boolean(feed.isRefetchError) && !nextPageFailed;
  const expired = feed.error instanceof ApiError && feed.error.code === 'feed_session_expired';
  return <div className="mobile-home">
    <form className="mobile-feed-search" role="search" onSubmit={event => {
      event.preventDefault();
      const value = String(new FormData(event.currentTarget).get("q") || "").trim();
      navigate(query("/community", { q: value }));
    }}><Icon name="search" size={19} /><input type="search" enterKeyHint="search" name="q" aria-label="搜索帖子" placeholder="搜索帖子标题、关键词、校园话题" /><button className="sr-only" type="submit">搜索</button></form>
    {rows(replies.data).length > 0 && <Link className="mobile-reply-reminder" to="/notifications"><Icon name="community" size={17} /><b>互动回复</b><span>{replies.data?.count ?? rows(replies.data).length} 条新回复</span><span aria-hidden="true">›</span></Link>}
    {pinned.length > 0 && <section className="mobile-pinned-posts" aria-label="公共帖子">{pinned.map(post => <Link key={post.id} to={`/post/${post.id}`} state={{ from: `/${params.size ? `?${params}` : ""}` }}><span>置顶</span><b>{post.title || post.content}</b><span aria-hidden="true">›</span></Link>)}</section>}
    <div className="dashboard-feed mobile-app-feed">
      {sort === "following" && !auth.loading && !auth.user ? <Empty icon="lock" title="登录后查看关注动态" description="关注同学，看看他们的校园日常。"><button className="btn primary" onClick={auth.login}>登录</button></Empty> :
      <QueryState skeleton="feed" query={{ isPending: feed.isPending, error: feed.data ? null : feed.error, refetch: feed.refetch }}>
        {content.map(post => <PostCard key={`${post.id}:${auth.user?.id}`} post={post} feedSource={feedSourceOf(sort)} />)}
        {!content.length && <Empty title="暂时没有帖子" description="分享一段校园日常，或换个分类看看。" />}
      </QueryState>}
    </div>
    {feed.data && <div className="mobile-feed-end">
      {refreshFailed ? <><p role="alert">刷新未完成，已读帖子已保留。</p><button className="btn" onClick={() => feed.refetch()}>重新刷新</button></> : nextPageFailed ? <><p role="alert">{expired ? '信息流已更新，请刷新后继续浏览。' : '后续内容加载失败，已读帖子已保留。'}</p><button className="btn" onClick={() => expired ? feed.refetch() : feed.fetchNextPage()}>{expired ? '刷新动态' : '重试加载'}</button></>
        : feed.hasNextPage ? <button className="btn" disabled={feed.isFetchingNextPage} onClick={() => feed.fetchNextPage()}>{feed.isFetchingNextPage ? "正在加载…" : "加载更多"}</button>
          : content.length > 0 && <span>已经看完啦</span>}
    </div>}
  </div>;
}

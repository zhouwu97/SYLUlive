import { useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { AiBotIdentity } from "./ai-bot-identity";
import { PublicPosts, isPublicPost } from "./campus-chrome";
import { ServerAvatar } from "./server-avatar";
import { userLevel } from "./user-level";
import { mobilePostTime, useMobile } from "./mobile";
import { useSlidingIndicator } from "./desktop-motion";
import { PollCard } from "./polls";
import { useInfiniteQuery, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Link,
  useNavigate,
  useLocation,
  useParams,
  useSearchParams,
} from "react-router-dom";
import {
  asset,
  captureAuthSession,
  entity,
  query,
  request,
  requestBlob,
  rows,
  time,
  useApi,
  write,
  type Entity,
} from "./api";
import { useAuth } from "./auth";
import { PostActions, retryInterruptedRead } from "./post-actions";
import { LevelBadge } from "./level-badge";
import { EmojiText } from "./inline-emoji";
import { truncateGraphemes } from "./emoji-text";
import { DismissedPost, PostCardMenu, ReportPostForm } from "./post-menu";
import { dismissalFor, feedSourceOf, useDismissals, type FeedSource } from "./feed-feedback";
import {
  Empty,
  Form,
  Head,
  Icon,
  Pagination,
  QueryState,
  Tabs,
  useUI,
} from "./ui";
import { MediaGallery, MediaUploadPicker, mediaURL, uploadImageFiles, uploadIDs } from "./media";
import { EmojiSelectionPreview, StickerPicker, StickerRenderer, favoritePublicImage, type StickerPayload } from "./emoji";
import { messageEmojiFields } from "./emoji-selection";
import { isDetailPath, useReportDetailOrigin } from "./detail-origin";
import "./community.css";
import "./market.css";
import {usePostEditor} from './post-editor-page';
export {uploadIDs} from "./media";
function PostAvatar({ author }: { author?: Entity }) {
  return <span className="post-avatar"><ServerAvatar src={author?.avatar} name={author?.nickname || "校园同学"} /></span>;
}

function PostTime({ value }: { value: unknown }) {
  const mobile = useMobile();
  const valid = typeof value === "string" && Number.isFinite(Date.parse(value));
  return <time dateTime={valid ? value : undefined} title={time(value)}>{valid ? mobile ? mobilePostTime(value) : new Date(value).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }) : ""}</time>;
}

function PostThumbnail({ post, className }: { post: Entity; className: string }) {
  const [failed, setFailed] = useState<string>();
  const src = mediaURL(post.images?.[0], "thumb") || mediaURL(post.images?.[0], "origin");
  return <span className={className}>
    {src && src !== failed ? <img src={src} alt="" loading="lazy" decoding="async" onError={() => setFailed(src)} /> : <span className="post-thumbnail-empty"><Icon name="market" size={28} />{className === "market-img" && <span>{src ? "图片暂不可用" : "暂无图片"}</span>}</span>}
  </span>;
}

function useAuthorFollow(authorId: number, initialFollowed: boolean, syncKey: string) {
  const auth = useAuth(), ui = useUI();
  const [pending, setPending] = useState(false);
  const lock = useRef(false);
  const [followed, setFollowed] = useState(initialFollowed);
  useEffect(() => {
    setFollowed(initialFollowed);
  }, [syncKey, initialFollowed]);
  async function toggle() {
    if (!authorId || lock.current || !auth.requireUser()) return;
    lock.current = true;
    setPending(true);
    try {
      if (await ui.act(() => write(`/api/user/${authorId}/follow`, {}, followed ? "DELETE" : "POST"), followed ? "已取消关注" : "已关注")) {
        setFollowed(!followed);
      }
    } finally {
      lock.current = false;
      setPending(false);
    }
  }
  return { followed, pending, toggle };
}

function PostAuthor({
  post,
  menu,
  authorOverride,
  badges,
  meta,
  followed: controlledFollowed,
  followPending: controlledPending,
  onToggleFollow,
}: {
  post: Entity;
  menu?: ReactNode;
  authorOverride?: Entity;
  badges?: ReactNode;
  meta?: ReactNode;
  followed?: boolean;
  followPending?: boolean;
  onToggleFollow?: () => Promise<void>;
}) {
  const auth = useAuth();
  const author = authorOverride || post.author;
  const authorId = Number(post.author_id || author?.id) || 0;
  const localFollow = useAuthorFollow(authorId, Boolean(author?.is_following || post.is_following), `${post.id}:${auth.user?.id ?? ""}`);
  const followed = controlledFollowed ?? localFollow.followed;
  const pending = controlledPending ?? localFollow.pending;
  const toggleFollow = onToggleFollow ?? localFollow.toggle;
  return (
    <div className="author post-author">
      <PostAvatar author={author} />
      <div className="author-meta">
        <div className="author-name-line"><b>{author?.nickname || "校园同学"}</b><LevelBadge className="author-level" level={userLevel(author, post.author_level)} />{badges}</div>
        <AiBotIdentity user={author} />
        <span>{meta ?? <><PostTime value={post.created_at} />{author?.followers_count != null ? ` · ${author.followers_count} 位关注者` : ""}</>}</span>
      </div>
      {auth.user && authorId > 0 && authorId !== auth.user.id && (
        <button className={`author-follow ${followed ? "active" : ""}`} type="button" disabled={pending} aria-pressed={followed} aria-busy={pending} onClick={toggleFollow}><span className="follow-control"><span className="follow-sign" aria-hidden="true"><Icon name={followed ? "check" : "plus"} size={13} /></span>{followed ? "已关注" : "关注"}</span></button>
      )}
      {menu}
    </div>
  );
}

function detailOrigin(path: string): { label: string; icon: string } {
  const [pathname, search = ""] = path.split("?");
  const section = pathname.split("/")[1] || "dashboard";
  const sort = new URLSearchParams(search).get("sort");
  if (section === "dashboard") return { label: "校园首页", icon: "dashboard" };
  if (section === "polls") return { label: "投票 · 组队", icon: "polls" };
  if (section === "market") return { label: "二手集市", icon: "market" };
  if (section === "community" && sort === "bookmarks") return { label: "我的收藏", icon: "bookmark" };
  if (section === "community" && sort === "mine") return { label: "我的帖子", icon: "file" };
  if (section === "community") return { label: "校园社区", icon: "community" };
  if (section === "profile") return { label: "个人主页", icon: "profile" };
  return { label: "上一页", icon: "arrow" };
}
export function PostCard({
  post,
  market = false,
  feedSource,
}: {
  post: Entity;
  market?: boolean;
  /** 首页信息流传入当前 Tab；带上后卡片提供「不感兴趣 / 不看 TA」，并按本地负反馈收起。 */
  feedSource?: FeedSource;
}) {
  const auth = useAuth(), openPostEditor = usePostEditor();
  const mobile = useMobile();
  useDismissals();
  // 桌面信息流的作者行显示所在板块，和侧栏板块共用同一份缓存；手机端保持 App 的作者行。
  const sections = useApi(market || mobile ? null : "/api/water/sections");
  const sectionLabel = rows(sections.data, "sections").find((item) => String(item.slug ?? item.id ?? "") === String(post.post_type ?? ""));
  const marketType = post.post_type || post.type;
  const marketLabel = ({ sell: "出售", buy: "求购", lost: "寻物", found: "招领", proxy: "办事", marketplace_sell: "出售", marketplace_buy: "求购" } as Record<string, string>)[marketType] || "出售";
  const marketStateLabel = ({ sold: "已售出", closed: "已结束" } as Record<string, string>)[post.status]
    || (post.status === "normal" && ["sell", "marketplace_sell"].includes(marketType) ? "出售中" : "");
  const location=useLocation(), navigate=useNavigate();
  const back={from:location.pathname+location.search};
  if (market)
    return (
      <Link className={`market-card ${post.status === "sold" ? "market-sold" : ""}`} to={`/post/${post.id}`} state={back}>
        <div className="market-cover">
          <PostThumbnail key={post.id} post={post} className="market-img" />
          <span className="tag market-status">
            {mobile ? marketLabel : post.status === "sold"
              ? "已售出"
              : post.post_type === "marketplace_buy"
                ? "求购"
                : "出售"}
          </span>
        </div>
        <div className="market-info">
          <h3><EmojiText text={post.title || post.content || ""} /></h3>
          <div className="market-price-row">
            {mobile && ["lost", "found"].includes(marketType) ? <span className="mobile-market-type">{marketStateLabel || marketLabel}</span> : <>
              {!mobile && post.price === 0 ? <strong className="price is-free">免费送</strong> : <strong className="price"><small>¥</small> {post.price ?? "待议"}</strong>}
              {mobile && marketStateLabel && <span className="mobile-market-type">{marketStateLabel}</span>}
            </>}
            {Number(post.reply_count) > 0 && <span>{post.reply_count} 条讨论</span>}
          </div>
          <div className="market-meta">
            <span className="market-seller"><PostAvatar author={post.author} /><span>{post.author?.nickname || "校园同学"}</span></span>
            <PostTime value={post.created_at} />
          </div>
        </div>
      </Link>
    );
  const dismissal = feedSource ? dismissalFor(auth.user?.id, Number(post.id), Number(post.author_id || post.author?.id) || undefined) : { mode: "visible" as const };
  if (dismissal.mode === "hidden") return null;
  if (dismissal.mode === "placeholder") return <DismissedPost dismissal={dismissal.dismissal} />;
  if (post.poll_meta) return <PollCard key={`${post.id}:${auth.user?.id}`} post={post} compact />;
  const menu = <PostCardMenu post={post} feedSource={feedSource} onEdit={() => openPostEditor({postId: Number(post.id)})} />;
  const summary = truncateGraphemes(post.content || "", 220);
  const openPostFromCard = (event: ReactMouseEvent<HTMLElement>) => {
    const target = event.target instanceof Element ? event.target : null;
    if (target?.closest("a,button,input,textarea,select,details,summary,[role=\"button\"],.post-author,.post-toolbar,.media-gallery")) return;
    navigate(`/post/${post.id}`, { state: back });
  };
  const openPostFromKeyboard = (event: ReactKeyboardEvent<HTMLElement>) => {
    if (event.target !== event.currentTarget || !["Enter", " "].includes(event.key)) return;
    event.preventDefault();
    navigate(`/post/${post.id}`, { state: back });
  };
  return (
    <article className="feed-card feed-card-clickable" tabIndex={0} aria-label={`打开帖子：${post.title || post.content?.slice(0, 40) || "无标题"}`} onClick={openPostFromCard} onKeyDown={openPostFromKeyboard}>
      <PostAuthor key={`author:${post.id}:${auth.user?.id}`} post={post} menu={menu} meta={mobile ? undefined : <>{sectionLabel && <>{sectionLabel.title || sectionLabel.name} · </>}<PostTime value={post.created_at} /></>} />
      <Link className="post-summary" to={`/post/${post.id}`} state={back}>
        {post.title && <h3 className="post-title"><EmojiText text={post.title} /></h3>}
        {post.content && <p className={`post-body ${post.title ? "" : "post-text-only"}`}><EmojiText text={summary.text} />{summary.truncated && "…"}</p>}
        {summary.truncated && <span className="post-read-more">查看全文 <span aria-hidden="true">→</span></span>}
      </Link>
      <MediaGallery items={post.images} title={post.title || "帖子图片"} />
      <PostActions key={`actions:${post.id}:${auth.user?.id}`} post={post} from={back.from} />
    </article>
  );
}
export function Community({ market = false }: { market?: boolean }) {
  const mobile = useMobile();
  const auth = useAuth(), openPostEditor = usePostEditor();
  const [params, setParams] = useSearchParams();
  const marketTypes = useSlidingIndicator<HTMLDivElement>("button[aria-pressed=\"true\"]");
  const page = Number(params.get("page")) || 1,
    sort = params.get("sort") || (market ? "time" : "all");
  const personal=sort==='mine'||sort==='bookmarks';
  const sections = useApi(market ? null : "/api/water/sections");
  const q = useApi(
    personal&&!auth.user?null:query(sort==='bookmarks'?'/api/user/bookmarks':sort==='mine'?`/api/user/${auth.user?.id}/${market?'market-posts':'posts'}`:"/api/posts", {
      board: market ? 2 : 1,
      page,
      limit: 20,
      sort,
      type: params.get("type"),
      q: params.get("q"),
      status: params.get("available") === "1" ? "normal" : undefined,
      capabilities: !market ? "poll_v1" : undefined,
      // 个人集市记录接口默认只返回出售，显式请求全部类型（代办、求购等）
      post_type: market && sort === "mine" ? "all" : undefined,
    }),
  );
  const posts = rows(q.data, "posts");
  // 社区默认列表与首页走同一套服务端负反馈过滤；搜索和分区筛选不过滤，也不提供「不感兴趣」。
  const feedSource = !market && !personal && !params.get("q") && !params.get("type") ? feedSourceOf(sort) : undefined;
  const publicPosts = !market && !personal && page === 1
    ? [...new Map([...rows(q.data, "pinned_posts"), ...posts].filter(isPublicPost).map(post => [post.id, post])).values()]
    : [];
  function filter(k: string, v: string) {
    const next = new URLSearchParams(params);
    next.set(k, v);
    next.set("page", "1");
    setParams(next);
  }
  if (mobile && personal && !auth.loading && !auth.user) {
    return <div className="community-page"><Empty icon="lock" title={sort === 'bookmarks' ? '登录后查看我的收藏' : '登录后查看我的发布'} description="登录沈理校园后，继续查看个人内容。"><button className="btn primary" onClick={auth.login}>登录</button></Empty></div>;
  }
  return (
    <div className={market ? "market-page" : "community-page"}>
      <Head
        title={market ? mobile ? "集市" : "二手集市" : "校园社区"}
        description={market ? "校园二手、求购和办事信息" : undefined}
      >
        <button
          className="btn primary"
          onClick={() => openPostEditor({market})}
        >
          <Icon name="plus" size={18} />{market ? "发布闲置" : "发布"}
        </button>
      </Head>
      {!market && (
        <Tabs
          tabs={[
            ["all", "推荐"],
            ["following", "关注"],
            ["time", "最新"],
            ["featured", "精华"],
            ["mine", "我的发布"],
            ["bookmarks", "收藏"],
          ]}
          value={sort}
          onChange={(v) => filter("sort", v)}
        />
      )}
      <div className="filter-row">
        <form
          onSubmit={(e) => {
            e.preventDefault();
            filter("q", String(new FormData(e.currentTarget).get("q") || ""));
          }}
        >
          <Icon name="search" size={18} />
          <input
            name="q"
            defaultValue={params.get("q") || ""}
            aria-label="搜索内容"
            placeholder={market ? "搜索闲置物品" : "搜索校园内容"}
          />
          <button className="btn">搜索</button>
        </form>
        {market ? (
          <>
            <select
              aria-label="价格排序"
              value={sort}
              onChange={(e) => filter("sort", e.target.value)}
            >
              <option value="time">最新发布</option>
              <option value="price">价格从低到高</option>
              <option value="price_desc">价格从高到低</option>
            </select>
            <label>
              <input
                type="checkbox"
                checked={params.get("available") === "1"}
                onChange={(e) =>
                  filter("available", e.target.checked ? "1" : "0")
                }
              />{" "}
              仅看未售
            </label>
          </>
        ) : (
          <select
            aria-label="社区分区"
            value={params.get("type") || ""}
            onChange={(e) => filter("type", e.target.value)}
          >
            <option value="">全部分区</option>
            {rows(sections.data, "sections").map((s) => (
              <option key={s.slug} value={s.slug}>
                {s.title || s.name}
              </option>
            ))}
          </select>
        )}
      </div>
      {market && <div className="market-results-head"><div role="group" aria-label="闲置分类" className="market-types" ref={marketTypes}>{(mobile ? [["", "全部"], ["sell", "出售"], ["buy", "求购"], ["lost", "寻物"], ["found", "招领"], ["proxy", "办事"]] : [["", "全部闲置"], ["marketplace_sell", "出售"], ["marketplace_buy", "求购"]]).map(([value, label]) => <button type="button" key={value} aria-pressed={(params.get("type") || "") === value} onClick={() => filter("type", value)}>{label}</button>)}</div>{q.data && !q.error && <span>本页 {posts.length} 件</span>}</div>}
      <QueryState query={q} skeleton={market ? undefined : "feed"}>
        {!market && !personal && page === 1 && publicPosts.length > 0 && <PublicPosts posts={publicPosts} />}
        <div className={market ? "market-grid" : "panel community-feed"}>
          {posts.filter(post => !publicPosts.some(item => item.id === post.id)).map((post) => (
            <PostCard key={post.id} post={post} market={market} feedSource={feedSource} />
          ))}
        </div>
        {!posts.length && <Empty title={market ? "没有找到闲置" : "暂时没有帖子"} description={params.get("q") || params.get("type") || params.get("available") === "1" ? "试试调整搜索词或筛选条件。" : market ? "发布一件闲置，或稍后再来逛逛。" : "分享一段校园日常，开启讨论。"} />}
        <Pagination
          page={page}
          hasMore={q.data?.has_more ?? posts.length === 20}
          onChange={(v) => {
            const next = new URLSearchParams(params);
            next.set("page", String(v));
            setParams(next);
          }}
        />
      </QueryState>
    </div>
  );
}
const MARKET_TYPE_LABELS: Record<string, string> = {
  sell: "出售",
  buy: "求购",
  lost: "寻物",
  found: "招领",
  proxy: "办事",
  marketplace_sell: "出售",
  marketplace_buy: "求购",
  exposure: "曝光",
};
const TEAM_STATUS_LABELS: Record<string, string> = {
  recruiting: "招募中",
  full: "已满员",
  closed: "已关闭",
  expired: "已截止",
};

export function PostDetail({ poll = false }: { poll?: boolean }) {
  const mobile = useMobile();
  const openPostEditor = usePostEditor();
  const location=useLocation(),navigate=useNavigate();
  const commentRef = useRef<HTMLElement>(null);
  const [commentSort, setCommentSort] = useState("hot");
  const { id: routeId } = useParams(),
    ui = useUI(),
    auth = useAuth();
  const q = useApi(poll ? `/api/polls/${routeId}` : `/api/posts/${routeId}`);
  const p = entity(q.data, "post");
  const id = p.id ? String(p.id) : poll ? "" : routeId;
  const isPoll = poll || !!p.poll_meta;
  const authorId = Number(p.author_id || p.author?.id) || 0;
  const authorProfile = useQuery({
    queryKey: ["api", "user-public", authorId, auth.user?.id],
    enabled: authorId > 0,
    queryFn: ({ signal }) => request<Entity>(`/api/user/${authorId}`, { signal }),
    retry: retryInterruptedRead,
  });
  const authorInfo = authorProfile.data?.id
    ? { ...p.author, ...authorProfile.data, level: p.author?.level ?? authorProfile.data?.level }
    : p.author;
  const followState = useAuthorFollow(
    authorId,
    Boolean(authorInfo?.is_following || p.is_following),
    `${p.id}:${auth.user?.id ?? ""}`,
  );
  const sections = useApi(!p.id || p.board_id === 2 || isPoll ? null : "/api/water/sections");
  const matchedSection = rows(sections.data, "sections").find((item) => String(item.slug ?? item.id ?? "") === String(p.post_type ?? ""));
  const sectionLabel = matchedSection ? String(matchedSection.title || matchedSection.name || "") : "";
  const marketTypeLabel = p.board_id === 2 ? MARKET_TYPE_LABELS[p.post_type || p.type] || "" : "";
  const marketTags = p.board_id === 2 && typeof p.market_tags === "string"
    ? p.market_tags.split(",").map((tag: string) => tag.trim()).filter(Boolean)
    : [];
  const comments = useInfiniteQuery({
    queryKey: ["api", "post-replies", id, auth.user?.id, commentSort],
    initialPageParam: "",
    enabled: !!id,
    queryFn: ({ pageParam, signal }) => request<Entity>(query(`/api/posts/${id}/replies`, { limit: 30, cursor: pageParam, sort: commentSort }), { signal }),
    getNextPageParam: (lastPage) => lastPage.next_cursor || undefined,
    retry: retryInterruptedRead,
  });
  const replies = uniqueReplies(comments.data?.pages.flatMap((page) => rows(page, "replies")) || []);
  const replyIds = new Set(replies.map((reply) => Number(reply.id)));
  const roots = replies.filter((reply) => !reply.parent_reply_id || !replyIds.has(Number(reply.parent_reply_id)));
  function focusComments() {
    commentRef.current?.scrollIntoView({ block: "start" });
    commentRef.current?.focus({ preventScroll: true });
  }
  useEffect(() => {
    if (location.hash !== "#post-comments" || q.isPending) return;
    const frame = requestAnimationFrame(focusComments);
    return () => cancelAnimationFrame(frame);
  }, [location.hash, q.isPending]);
  function replyTo(reply?: Entity) {
    if (!auth.requireUser()) return;
    ui.open(reply ? `回复 ${reply.author?.nickname || "校园同学"}` : "发表评论", <ReplyComposer postId={Number(id)} parentReplyId={reply ? Number(reply.parent_reply_id || reply.id) : undefined} replyToReplyId={reply?.parent_reply_id ? Number(reply.id) : undefined} replyToUserId={reply?.parent_reply_id ? Number(reply.author_id) : undefined} onSent={ui.close} />);
  }
  const moreActions = (
    <PostMore>
            {p.images?.[0] && (
              <button type="button" onClick={async () => { if (!auth.requireUser()) return; const path = mediaURL(p.images[0], "origin"); if (!path) return; await ui.act(() => favoritePublicImage(path), "图片已收藏为表情"); }}>
                收藏首图为表情
              </button>
            )}
            <button
              type="button"
              onClick={() => auth.requireUser() && ui.open("举报内容", <ReportPostForm postId={Number(id)} />)}
            >
              举报
            </button>
            {p.viewer_permissions?.can_edit && (
              <button
                type="button"
                onClick={() => openPostEditor({postId: Number(id)})}
              >
                编辑
              </button>
            )}
            {p.author_id === auth.user?.id && p.board_id === 2 && (
              <button
                type="button"
                onClick={() =>
                  ui.act(() =>
                    write(
                      `/api/posts/${id}/status`,
                      { status: p.status === "sold" ? "normal" : "sold" },
                      "PATCH",
                    ),
                  )
                }
              >
                {p.status === "sold" ? "恢复在售" : "标记售出"}
              </button>
            )}
            {p.viewer_permissions?.can_delete && (
              <button
                type="button" className="post-danger-action"
                onClick={() =>
                  ui.open(
                    "删除内容",
                    <>
                      <p>删除后帖子将不再公开显示。</p>
                      <button
                        className="btn"
                        onClick={async () => {
                          if (
                            await ui.act(() =>
                              request(`/api/posts/${id}`, { method: "DELETE" }),
                            )
                          )
                            ui.close();
                        }}
                      >
                        确认删除
                      </button>
                    </>,
                  )
                }
              >
                删除
              </button>
            )}
          </PostMore>
  );
  // 返回目标跟随入口：从首页、投票列表、收藏等进入时回到原页（保留滚动位置），直接打开时按内容类型兜底。
  const from = typeof location.state?.from === "string" ? location.state.from as string : "";
  const fallback = isPoll ? "/polls" : p.board_id === 2 ? "/market" : "/community";
  const origin = detailOrigin(from || fallback);
  useReportDetailOrigin(from && !isDetailPath(from) ? from : q.data ? fallback : "");
  const goBack = () => from ? navigate(-1) : navigate(fallback);
  const postBadges = (isPublicPost(p) || p.is_featured || p.water_section_featured) ? (
    <>
      {isPublicPost(p) && <span className="post-badge is-pinned">置顶</span>}
      {(p.is_featured || p.water_section_featured) && <span className="post-badge is-featured">精华</span>}
    </>
  ) : undefined;
  const postMeta = (
    <>
      <PostTime value={p.created_at} />
      {sectionLabel && (
        <>
          <span aria-hidden="true"> · </span>
          <Link className="post-meta-section" to={`/community?type=${encodeURIComponent(p.post_type)}`}>{sectionLabel}</Link>
        </>
      )}
      {marketTypeLabel && (
        <>
          <span aria-hidden="true"> · </span>
          <Link className="post-meta-section" to={`/market?type=${encodeURIComponent(p.post_type || p.type)}`}>{marketTypeLabel}</Link>
        </>
      )}
      {Number(p.view_count) > 0 && (
        <>
          <span aria-hidden="true"> · </span>
          <span>{Number(p.view_count).toLocaleString("zh-CN")} 次浏览</span>
        </>
      )}
    </>
  );
  const teamMeta = p.team_recruitment_meta;
  return (
    <div className="post-detail-page">
      {mobile ? <header className="mobile-header mobile-detail-header page-head post-detail-head">
        <button className="mobile-icon-button" aria-label="返回上一页" onClick={goBack}><Icon name="arrow" size={24} /></button>
        <h1>{p.poll_meta ? "投票详情" : p.board_id === 2 ? "闲置详情" : "帖子详情"}</h1>
        {q.data && !q.error ? moreActions : <span className="mobile-icon-button" />}
      </header> : <header className="page-head post-detail-head">
        <div className="page-title post-detail-heading">
          <Link to={from || fallback} onClick={(event) => { if (!from) return; event.preventDefault(); goBack(); }}><Icon name={origin.icon} size={16} /><span>{origin.label}</span></Link>
          {sectionLabel && !isPoll && (
            <>
              <span aria-hidden="true" className="post-detail-separator">/</span>
              <Link to={`/community?type=${encodeURIComponent(p.post_type)}`}>{sectionLabel}</Link>
            </>
          )}
          <span aria-hidden="true" className="post-detail-separator">/</span>
          <h1>{isPoll ? "投票详情" : p.board_id === 2 ? "闲置详情" : "帖子详情"}</h1>
        </div>
        <button className="btn post-back" onClick={goBack}><Icon name="arrow" size={16} />返回列表</button>
      </header>}
      {mobile && p.poll_meta && <p className="mobile-poll-notice">非官方用户投票，结果仅代表参与用户的选择。</p>}
      <QueryState query={q} skeleton="post">
        <div className="post-detail-layout">
        <div className="post-detail-main">
        <article className="panel post-full">
          {p.poll_meta ? <PollCard key={`${p.id}:${auth.user?.id}`} post={p} /> : <>
          <PostAuthor
            key={`author:${p.id}:${auth.user?.id}`}
            post={p}
            authorOverride={authorInfo}
            badges={postBadges}
            meta={postMeta}
            followed={followState.followed}
            followPending={followState.pending}
            onToggleFollow={followState.toggle}
          />
          {p.title && <h1><EmojiText text={p.title} /></h1>}
          {p.board_id === 2 && (
            <div className="post-market-summary">
              {!mobile && p.price === 0 ? <strong className="post-market-price is-free">免费送</strong> : <strong className="post-market-price"><small>¥</small> {p.price ?? "待议"}</strong>}
              <span>{p.status === "sold" ? "已售出" : p.status === "closed" ? "已结束" : "交易中"}</span>
              {marketTags.map((tag: string) => <span className="post-market-tag" key={tag}>{tag}</span>)}
            </div>
          )}
          {p.content && <div className="post-body details-text"><EmojiText text={p.content} /></div>}
          {Array.isArray(p.topics) && p.topics.length > 0 && (
            <div className="post-detail-topics" aria-label="帖子话题">
              {p.topics.map((topic: Entity | string, index: number) => {
                const label = (typeof topic === "string" ? topic : topic?.name || topic?.title || "").replace(/^#+/, "").trim();
                if (!label) return null;
                return (
                  <Link key={(typeof topic === "object" && topic?.id) || `${label}-${index}`} className="post-topic-tag" to={`/community?q=${encodeURIComponent(label)}`}>
                    #{label}
                  </Link>
                );
              })}
            </div>
          )}
          {teamMeta && (
            <div className="post-team-box">
              <div className="post-team-box-head">
                <span className={`post-team-status ${(teamMeta.effective_status || teamMeta.status) === "recruiting" ? "is-active" : ""}`}>
                  {TEAM_STATUS_LABELS[teamMeta.effective_status || teamMeta.status] || "组队招募"}
                </span>
                {teamMeta.remaining_count != null && <b>还需 {teamMeta.remaining_count} 人</b>}
                {teamMeta.deadline && <small>截止 <PostTime value={teamMeta.deadline} /></small>}
              </div>
              {Array.isArray(teamMeta.roles) && teamMeta.roles.length > 0 && (
                <div className="post-team-roles">
                  {teamMeta.roles.map((role: string, index: number) => <span key={`${role}-${index}`}>{role}</span>)}
                </div>
              )}
              <Link className="post-team-link" to="/polls?tab=team">前往组队广场查看详情 <span aria-hidden="true">→</span></Link>
            </div>
          )}
          <MediaGallery items={p.images} title={p.title || "帖子图片"} className="post-detail-gallery" maxVisible={9} variant="detail" />
          {p.board_id === 2 && (
            <div className="info-box">
              <p>
                {p.contact_type}：{p.contact || "请通过评论联系"}
              </p>
            </div>
          )}
          </>}
          <PostActions key={`actions:${p.id}:${auth.user?.id}`} post={p} onComment={focusComments} more={mobile ? undefined : moreActions} />
        </article>
        <section className="panel post-comments section" id="post-comments" ref={commentRef} tabIndex={-1} aria-label="评论区">
          <div className="post-comments-head"><h2>全部评论 <span>{comments.data?.pages[0]?.total ?? p.reply_count ?? 0}</span></h2><select aria-label="评论排序" value={commentSort} onChange={(event) => setCommentSort(event.target.value)}><option value="hot">热门</option><option value="latest">最新</option></select></div>
          {mobile ? <div className="post-comment-prompt"><button className="mobile-icon-button" aria-label="添加图片或表情回复" onClick={() => replyTo()}><Icon name="plus" size={24} /></button><button type="button" className="post-comment-start" onClick={() => replyTo()}><span>{auth.user ? "写下你的想法…" : "登录后参与讨论…"}</span><Icon name="community" size={19} /></button></div> : <InlineCommentPrompt key={`${id}:${auth.user?.id}`} postId={Number(id)} />}
          <QueryState query={{ ...comments, error: comments.data ? null : comments.error }}>
            {!replies.length && <Empty icon="community" title="还没有评论" description="分享你的想法，开启这段讨论。" />}
            {roots.map((reply) => <CommentThread key={`${reply.id}:${auth.user?.id}`} postId={Number(id)} postAuthorId={authorId} reply={reply} preview={replies.filter((child) => Number(child.parent_reply_id) === Number(reply.id))} onReply={replyTo} />)}
            {comments.data && comments.error && <div className="post-comments-error" role="alert"><span>{comments.error.message}</span><button type="button" className="btn" disabled={comments.isFetching} onClick={() => comments.isFetchNextPageError ? comments.fetchNextPage() : comments.refetch()}>重试</button></div>}
            {comments.hasNextPage && <button type="button" className="btn post-load-more" disabled={comments.isFetchingNextPage} onClick={() => comments.fetchNextPage()}>{comments.isFetchingNextPage ? "正在加载…" : "加载更多评论"}</button>}
          </QueryState>
        </section>
        </div>
        <PostDetailRail post={p} author={authorInfo} follow={followState} onComment={focusComments} />
        </div>
      </QueryState>
    </div>
  );
}

function PostDetailRail({
  post,
  author,
  follow,
  onComment,
}: {
  post: Entity;
  author?: Entity;
  follow: { followed: boolean; pending: boolean; toggle: () => Promise<void> };
  onComment: () => void;
}) {
  const auth = useAuth(), location = useLocation();
  const market = post.board_id === 2;
  const authorId = Number(post.author_id || author?.id) || 0;
  const canFollow = !!auth.user && authorId > 0 && authorId !== auth.user.id;
  const authorPostCountQuery = useQuery({
    queryKey: ["api", "user-post-count", authorId],
    enabled: authorId > 0,
    queryFn: ({ signal }) => request<Entity>(`/api/user/${authorId}/posts/count`, { signal }),
    retry: retryInterruptedRead,
  });
  const authorMoreQuery = useQuery({
    queryKey: ["api", "user-more-posts", authorId, market, auth.user?.id],
    enabled: authorId > 0,
    queryFn: ({ signal }) => request<Entity>(
      market
        ? `/api/user/${authorId}/market-posts?post_type=all&limit=4`
        : `/api/user/${authorId}/posts?limit=4`,
      { signal },
    ),
    retry: retryInterruptedRead,
  });
  const more = useQuery({
    queryKey: ["api", "post-detail-more", market, auth.user?.id],
    queryFn: ({ signal }) => request<Entity>(query("/api/posts", { board: market ? 2 : 1, sort: "time", limit: 5, status: market ? "normal" : undefined }), { signal }),
    retry: retryInterruptedRead,
  });
  const authorOtherPosts = rows(authorMoreQuery.data, "posts")
    .filter((item) => Number(item.id) > 0 && Number(item.id) !== Number(post.id))
    .slice(0, 2);
  const authorPostCount = typeof authorPostCountQuery.data?.count === "number"
    ? authorPostCountQuery.data.count
    : typeof authorMoreQuery.data?.total === "number"
      ? authorMoreQuery.data.total
      : undefined;
  const authorStats: { label: string; value: number }[] = [];
  if (typeof author?.total_likes_received === "number") authorStats.push({ label: "获赞", value: author.total_likes_received });
  if (typeof author?.followers_count === "number") authorStats.push({ label: "粉丝", value: author.followers_count });
  if (typeof authorPostCount === "number") authorStats.push({ label: "发帖", value: authorPostCount });
  else if (typeof author?.following_count === "number") authorStats.push({ label: "关注", value: author.following_count });
  const posts = rows(more.data, "posts").filter((item) => Number(item.id) > 0 && Number(item.id) !== Number(post.id)).slice(0, 3);
  const browse = market ? "/market?sort=time" : "/community?sort=time";
  const level = userLevel(author, post.author_level);
  const personSub = author?.credit_score != null
    ? `信用分 ${author.credit_score}`
    : authorStats.length < 2 && author?.followers_count != null
      ? `${author.followers_count} 位关注者`
      : null;
  return <aside className="post-detail-rail" aria-label="帖子相关信息">
    <section className="rail-card post-context-author">
      <div className="rail-title">
        <h2><span className="rail-heading-icon"><Icon name="profile" size={16} /></span>关于作者</h2>
        {canFollow && (
          <button
            type="button"
            className={`post-context-follow ${follow.followed ? "active" : ""}`}
            disabled={follow.pending}
            aria-pressed={follow.followed}
            aria-busy={follow.pending}
            onClick={follow.toggle}
          >
            {follow.followed ? "已关注" : "+ 关注"}
          </button>
        )}
      </div>
      <div className="post-context-person">
        <PostAvatar author={author} />
        <div className="post-context-person-copy">
          <div className="post-context-name">
            <b>{author?.nickname || "校园同学"}</b>
            <span className="post-context-level">Lv.{level}</span>
          </div>
          <AiBotIdentity user={author} />
          {personSub && <span className="post-context-sub">{personSub}</span>}
        </div>
      </div>
      {authorStats.length >= 2 && (
        <dl className="post-context-stats" style={{ gridTemplateColumns: `repeat(${authorStats.length}, minmax(0, 1fr))` }}>
          {authorStats.map((stat) => (
            <div key={stat.label}>
              <dt>{stat.label}</dt>
              <dd>{stat.value}</dd>
            </div>
          ))}
        </dl>
      )}
      {authorOtherPosts.length > 0 && (
        <div className="post-author-more">
          <h3>{market ? "TA 的其他闲置" : "TA 的近期发布"}</h3>
          <div className="post-author-more-list">
            {authorOtherPosts.map((item) => (
              <Link
                key={item.id}
                className="post-author-more-item"
                to={`/post/${item.id}`}
                state={{ from: location.pathname + location.search }}
              >
                <span>{item.title || item.content?.slice(0, 60) || (market ? "校园闲置" : "校园动态")}</span>
                <small>{market && item.price != null ? (item.price === 0 ? "免费送" : `¥${item.price}`) : `${item.reply_count || 0} 评`}</small>
              </Link>
            ))}
          </div>
        </div>
      )}
      <button type="button" className="btn full-width post-context-comment" onClick={onComment}>
        <Icon name="community" size={16} />查看评论
      </button>
    </section>
    <section className="rail-card post-context-more" aria-labelledby="post-context-more-title">
      <div className="rail-title post-context-title">
        <h2 id="post-context-more-title">
          <span className="rail-heading-icon"><Icon name={market ? "market" : "trending"} size={16} /></span>
          {market ? "最新闲置" : "最新校园讨论"}
        </h2>
        <Link to={browse}>全部 <span aria-hidden="true">→</span></Link>
      </div>
      {more.isPending ? <p className="post-context-state" role="status">正在加载更多帖子…</p> : more.error ? <div className="post-context-state" role="alert"><p>暂时无法加载更多帖子</p><button type="button" className="btn" disabled={more.isFetching} onClick={() => more.refetch()}>{more.isFetching ? "正在重试…" : "重试"}</button></div> : posts.length ? <div className="post-context-list">{posts.map((item) => <Link key={item.id} className="post-context-item" to={`/post/${item.id}`} state={{ from: location.pathname + location.search }}>
        <div className="post-context-copy"><b>{item.title || item.content?.slice(0, 80) || (market ? "校园闲置" : "校园讨论")}</b>
        {item.title && item.content && <p>{item.content.slice(0, 100)}</p>}
        <span>{market && item.price != null ? <strong>¥ {item.price}</strong> : <span>{item.author?.nickname || "校园同学"}</span>}<span><Icon name="community" size={13} />{item.reply_count || 0}</span></span><AiBotIdentity user={item.author} /></div>
        {!!item.images?.length && <PostThumbnail key={item.id} post={item} className="post-context-thumb" />}
      </Link>)}</div> : <p className="post-context-state">暂时没有其他帖子</p>}
      <Link className="post-context-browse" to={browse}>继续逛逛{market ? "二手集市" : "校园社区"}<Icon name="arrow" size={15} /></Link>
    </section>
  </aside>;
}

function PostMore({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDetailsElement>(null);
  useEffect(() => {
    const dismiss = (event: PointerEvent) => { if (!ref.current?.contains(event.target as Node)) ref.current?.removeAttribute("open"); };
    const escape = (event: KeyboardEvent) => {
      if (event.key === "Escape" && ref.current?.open) { ref.current.open = false; ref.current.querySelector("summary")?.focus(); }
    };
    document.addEventListener("pointerdown", dismiss);
    document.addEventListener("keydown", escape);
    return () => { document.removeEventListener("pointerdown", dismiss); document.removeEventListener("keydown", escape); };
  }, []);
  return <details className="post-more" ref={ref}><summary aria-label="更多操作"><Icon name="more" size={20} /><span className="post-more-label">更多</span></summary><div className="post-more-menu" onClick={(event) => { if ((event.target as HTMLElement).closest("button") && ref.current) { ref.current.open = false; ref.current.querySelector("summary")?.focus(); } }}>{children}</div></details>;
}

function uniqueReplies(replies: Entity[]) {
  return [...new Map(replies.map((reply) => [Number(reply.id), reply])).values()];
}

function InlineCommentPrompt({ postId }: { postId: number }) {
  const auth = useAuth();
  const prompt = useRef<HTMLDivElement>(null);
  const [started, setStarted] = useState(false), [expanded, setExpanded] = useState(false);
  return <div ref={prompt} className={`post-comment-prompt${expanded ? " is-editing" : ""}`}>
    <PostAvatar author={auth.user || undefined} />
    <div className="post-comment-input">
      {!expanded && <button type="button" className="post-comment-start" disabled={auth.loading} onClick={() => {
        if (!auth.requireUser()) return;
        setStarted(true); setExpanded(true);
      }}><span>{auth.user ? "说说你的想法，一起聊聊…" : "登录后参与讨论…"}</span><Icon name="edit" size={18} /></button>}
      {started && <div hidden={!expanded}><ReplyComposer inline active={expanded} postId={postId} onCancel={() => { setExpanded(false); requestAnimationFrame(() => prompt.current?.querySelector<HTMLButtonElement>(".post-comment-start")?.focus({ preventScroll: true })); }} onSent={() => { setExpanded(false); setStarted(false); }} /></div>}
    </div>
  </div>;
}

function CommentRow({ postId, postAuthorId, reply, onReply }: { postId: number; postAuthorId?: number; reply: Entity; onReply: (reply: Entity) => void }) {
  const auth = useAuth(), ui = useUI();
  const mobile = useMobile();
  const replyButton = useRef<HTMLButtonElement>(null);
  const [replyStarted, setReplyStarted] = useState(false), [replying, setReplying] = useState(false);
  const [pending, setPending] = useState(false);
  const locked = useRef(false);
  const deleted = reply.status === "deleted";
  const author = reply.author || reply.user;
  const authorName = author?.nickname || "校园同学";
  const isPostAuthor = !deleted && !!postAuthorId && Number(reply.author_id) === postAuthorId;
  const hasLevel = !deleted && (author?.exp != null || author?.level != null);
  return <article className="post-comment" aria-label={`${reply.author?.nickname || "校园同学"}的评论`}>
    <PostAvatar author={author} />
    <div className="post-comment-main">
      <div className="post-comment-author">
        <b>{authorName}</b>
        {isPostAuthor && <span className="post-comment-op">作者</span>}
        {hasLevel && <span className="post-comment-level">Lv.{userLevel(author)}</span>}
        {!deleted && reply.reply_to_name && reply.parent_reply_id && (
          <span className="post-comment-reply-to">回复 <b>@{reply.reply_to_name}</b></span>
        )}
        <PostTime value={reply.created_at} />
      </div>
      <AiBotIdentity user={author} />
      {deleted ? <p className="post-comment-deleted">该评论已删除</p> : <>
        {reply.content && reply.content !== "[表情]" && <p className="details-text"><EmojiText text={reply.content} /></p>}
        {reply.sticker_id && <StickerRenderer stickerId={reply.sticker_id} assetKey={reply.asset_key} packId={reply.pack_id} />}
        {(reply.images || reply.attachments)?.length > 0 && <MediaGallery items={reply.images || reply.attachments} title="评论图片" maxVisible={4} />}
      </>}
      {!deleted && <div className="post-comment-footer"><div className="post-comment-actions">
        <button type="button" aria-label={`${reply.is_liked ? "取消点赞" : "点赞"}${authorName}的评论，${reply.like_count || 0}赞`} aria-pressed={!!reply.is_liked} aria-busy={pending} disabled={pending || auth.loading} onClick={async () => {
          if (locked.current || !auth.requireUser()) return;
          locked.current = true; setPending(true);
          try { await ui.act(() => write(`/api/replies/${reply.id}/like`, {}, reply.is_liked ? "DELETE" : "POST"), reply.is_liked ? "已取消点赞" : "已点赞"); }
          finally { locked.current = false; setPending(false); }
        }}><Icon name="heart" size={16} /><span>{reply.like_count || "赞"}</span></button>
        <button ref={replyButton} type="button" aria-expanded={mobile ? undefined : replying} onClick={() => {
          if (mobile) { onReply(reply); return; }
          if (!auth.requireUser()) return;
          setReplyStarted(true); setReplying((value) => !value);
        }}><Icon name="community" size={16} />回复</button>
      </div></div>}
      {!mobile && replyStarted && <div className="post-thread-composer" hidden={!replying}><ReplyComposer inline active={replying} postId={postId} parentReplyId={Number(reply.parent_reply_id || reply.id)} replyToReplyId={reply.parent_reply_id ? Number(reply.id) : undefined} replyToUserId={reply.parent_reply_id ? Number(reply.author_id) : undefined} replyToName={authorName} onCancel={() => { setReplying(false); replyButton.current?.focus({ preventScroll: true }); }} onSent={() => { setReplying(false); setReplyStarted(false); }} /></div>}
    </div>
  </article>;
}

function CommentThread({ postId, postAuthorId, reply, preview, onReply }: { postId: number; postAuthorId?: number; reply: Entity; preview: Entity[]; onReply: (reply: Entity) => void }) {
  const auth = useAuth();
  const [expanded, setExpanded] = useState(false);
  const children = useInfiniteQuery({
    queryKey: ["api", "reply-children", postId, reply.id, auth.user?.id],
    enabled: expanded,
    initialPageParam: "",
    queryFn: ({ pageParam, signal }) => request<Entity>(query(`/api/posts/${postId}/replies/${reply.id}/children`, { limit: 30, cursor: pageParam }), { signal }),
    getNextPageParam: (lastPage) => lastPage.next_cursor || undefined,
    retry: retryInterruptedRead,
  });
  const visible = uniqueReplies(expanded ? [...preview, ...(children.data?.pages.flatMap((page) => rows(page, "replies")) || [])] : preview);
  const remaining = Math.max(0, Number(reply.child_reply_count || 0) - preview.length);
  return <div className="post-comment-thread">
    <CommentRow postId={postId} postAuthorId={postAuthorId} reply={reply} onReply={onReply} />
    {!!visible.length && <div className="post-comment-children">{visible.map((child) => <CommentRow key={`${child.id}:${auth.user?.id}`} postId={postId} postAuthorId={postAuthorId} reply={child} onReply={onReply} />)}</div>}
    {!expanded && remaining > 0 && <button type="button" className="post-thread-toggle" onClick={() => setExpanded(true)}>展开其余 {remaining} 条回复<Icon name="chevron" size={14} /></button>}
    {expanded && <div className="post-thread-controls"><QueryState query={children}>{children.hasNextPage && <button type="button" className="post-thread-toggle" disabled={children.isFetchingNextPage} onClick={() => children.fetchNextPage()}>{children.isFetchingNextPage ? "正在加载…" : "加载更多回复"}</button>}</QueryState><button type="button" className="post-thread-toggle" onClick={() => setExpanded(false)}>收起回复</button></div>}
  </div>;
}

function ReplyComposer({ postId, parentReplyId, replyToReplyId, replyToUserId, replyToName, inline = false, active = true, onCancel, onSent }: { postId: number; parentReplyId?: number; replyToReplyId?: number; replyToUserId?: number; replyToName?: string; inline?: boolean; active?: boolean; onCancel?: () => void; onSent: () => unknown }) {
  const ui = useUI(), auth = useAuth(), qc = useQueryClient();
  const [sticker, setSticker] = useState<StickerPayload | null>(null);
  const [showStickers, setShowStickers] = useState(false);
  const [sending, setSending] = useState(false);
  const editor = useRef<HTMLFieldSetElement>(null), emojiTrigger = useRef<HTMLButtonElement>(null);
  const [content, setContent] = useState(""), [fileCount, setFileCount] = useState(0);
  const alive = useRef(true), originalUser = useRef(auth.user?.id), invalidated = useRef(false);
  const uploadedFavorite = useRef<{ favoriteId: number; fileId: number } | null>(null);
  if (auth.user?.id !== originalUser.current) invalidated.current = true;
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useEffect(() => {
    if (inline && active) editor.current?.querySelector<HTMLTextAreaElement>("textarea")?.focus({ preventScroll: true });
    if (!active) setShowStickers(false);
  }, [inline, active]);
  useEffect(() => {
    if (!inline || !showStickers) return;
    const dismiss = (event: PointerEvent) => { if (!editor.current?.contains(event.target as Node)) setShowStickers(false); };
    document.addEventListener("pointerdown", dismiss);
    return () => document.removeEventListener("pointerdown", dismiss);
  }, [inline, showStickers]);
  if (invalidated.current) return <div className="emoji-state"><b>账号已切换，请重新打开评论</b><button type="button" className="btn" onClick={ui.close}>关闭</button></div>;
  return <fieldset ref={editor} className={`reply-emoji-composer${inline ? " reply-inline-composer" : ""}`} disabled={sending} aria-label={replyToName ? `回复 ${replyToName}` : "发表评论"} aria-busy={sending} onKeyDown={(event) => {
    if (!inline || event.nativeEvent.isComposing) return;
    if (event.key === "Escape") {
      // 表情面板先接管 Escape；再次按下才收起编辑器，文字与图片仍留在本页。
      if (event.defaultPrevented) return;
      event.preventDefault(); event.stopPropagation();
      if (showStickers) { setShowStickers(false); emojiTrigger.current?.focus(); }
      else if (!sending) onCancel?.();
    }
    if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); if (!sending) editor.current?.querySelector("form")?.requestSubmit(); }
  }}><Form fields={inline ? [] : [{ name: "content", label: "写下你的回复", type: "textarea" }]} submit="发布评论" submitDisabled={inline && !content.trim() && !sticker && !fileCount} onSubmit={async (_, fd) => {
    if (!auth.requireUser()) return;
    const session = captureAuthSession(), isCurrent = () => alive.current && !invalidated.current && session();
    const assertCurrent = () => { if (!isCurrent()) throw new Error("账号已切换，请重新确认评论"); };
    const content = String(fd.get("content") || "").trim();
    if (!content && !sticker && !fd.getAll("images").some((item) => item instanceof File && item.size > 0)) throw new Error("请输入内容、选择图片或表情");
    const hasImages = fd.getAll("images").some((item) => item instanceof File && item.size > 0);
    if (sticker && hasImages) throw new Error("图片和表情不能同时发送");
    setSending(true);
    try {
      const ids = await uploadIDs(fd); assertCurrent(); fd.delete("images");
      if (sticker?.kind === "image") {
        // 私有收藏在提交时读取并重新上传；公开评论不能引用原私有 file_id。
        if (uploadedFavorite.current?.favoriteId !== sticker.favorite_id) {
          const blob = await requestBlob(sticker.url); assertCurrent();
          const mime = blob.type || sticker.mime_type || "";
          const extension = mime === "image/gif" ? "gif" : mime === "image/png" ? "png" : mime === "image/jpeg" ? "jpg" : null;
          if (!extension) throw new Error("收藏图片格式不可用，请重新选择");
          const [fileId] = await uploadImageFiles([new File([blob], `favorite.${extension}`, { type: mime })]); assertCurrent();
          uploadedFavorite.current = { favoriteId: sticker.favorite_id, fileId };
        }
        ids.push(uploadedFavorite.current.fileId);
      } else if (sticker) {
        Object.entries(messageEmojiFields(sticker)).forEach(([key, value]) => fd.set(key, String(value)));
        if (!content) fd.set("content", "[表情]");
      }
      if (ids.length) fd.set("file_ids", JSON.stringify(ids));
      if (parentReplyId) fd.set("parent_reply_id", String(parentReplyId));
      if (replyToReplyId) fd.set("reply_to_reply_id", String(replyToReplyId));
      if (replyToUserId) fd.set("reply_to_user_id", String(replyToUserId));
      assertCurrent(); await write(`/api/posts/${postId}/replies`, fd); assertCurrent();
      setSticker(null); setShowStickers(false); uploadedFavorite.current = null;
      await qc.invalidateQueries({ queryKey: ["api"] });
      if (isCurrent()) { await onSent(); ui.notify("回复已发布"); }
    } finally { if (isCurrent()) setSending(false); }
  }}>
    {inline && <>
      {replyToName && <div className="reply-target">回复 <b>{replyToName}</b></div>}
      <label className="field reply-text-field"><span className="sr-only">写下你的回复</span><textarea name="content" rows={2} value={content} placeholder={replyToName ? `回复 ${replyToName}…` : "说说你的想法，一起聊聊…"} onChange={(event) => { setContent(event.target.value); const input = event.currentTarget; input.style.height = "auto"; input.style.height = `${Math.min(input.scrollHeight, 200)}px`; }} /></label>
    </>}
    <div className={inline ? "reply-attachments" : undefined}><MediaUploadPicker maxCount={4} compact={inline} disabled={sending || !!sticker} onFilesChange={(files) => setFileCount(files.length)} /></div>
    <div className={inline ? "reply-inline-tools" : "reply-emoji-row"}>
      <button ref={emojiTrigger} type="button" className={inline ? "reply-tool" : "btn"} aria-label={inline ? "添加表情" : undefined} title={inline ? "添加表情" : undefined} aria-expanded={showStickers} disabled={fileCount > 0} onClick={() => setShowStickers((value) => !value)}>{inline ? <span className="reply-smile" aria-hidden="true">☺</span> : <>☺ {showStickers ? "收起表情" : "添加表情"}</>}</button>
      {inline && <><button type="button" className="reply-tool" aria-label="添加图片" title={sticker ? "移除表情后可添加图片" : "添加图片 · 最多 4 张，可粘贴"} disabled={!!sticker || fileCount >= 4} onClick={() => editor.current?.querySelector<HTMLInputElement>('input[name="images"]')?.click()}><Icon name="image" size={20} /></button><span className="reply-shortcut">{fileCount ? `${fileCount}/4 张图片` : "Ctrl / ⌘ + Enter 发布"}</span><button type="button" className="reply-collapse" onClick={onCancel}>收起</button></>}
      {!inline && sticker && <span className="sticker-inline"><EmojiSelectionPreview selection={sticker} /><button type="button" className="link-btn" onClick={() => setSticker(null)}>移除</button></span>}
    </div>
    {inline && sticker && <div className="reply-selected-sticker"><EmojiSelectionPreview selection={sticker} /><button type="button" className="link-btn" onClick={() => setSticker(null)}>移除表情</button></div>}
    {showStickers && <div className={inline ? "reply-emoji-popover" : undefined} role={inline ? "region" : undefined} aria-label={inline ? "选择评论表情" : undefined}><StickerPicker compact disabled={sending} onSelect={(value) => { setSticker(value); setShowStickers(false); if (inline) editor.current?.querySelector("textarea")?.focus({ preventScroll: true }); }} /></div>}
  </Form></fieldset>;
}

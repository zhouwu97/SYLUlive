import { useEffect, useRef, useState, type ReactNode } from "react";
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
  entity,
  query,
  request,
  rows,
  time,
  useApi,
  write,
  type Entity,
} from "./api";
import { useAuth } from "./auth";
import { PostActions, retryInterruptedRead } from "./post-actions";
import {
  rejectAttachmentFiles,
  type AttachmentLimits,
} from "./attachments";
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
import { MediaGallery, MediaUploadPicker, mediaURL, uploadImageFiles } from "./media";
import { StickerPicker, StickerRenderer, favoritePublicImage, type StickerPayload } from "./emoji";
import "./community.css";
// 同一个 File 对象在「提交失败后原样重点提交」时不应再传一遍：
// 上传接口按字节去重，但重复请求仍会产生新记录与等待。
const uploadedFileIDs = new WeakMap<File, number>();
export async function uploadIDs(form: FormData, limits?: AttachmentLimits) {
  const files = form
    .getAll("images")
    .filter((item): item is File => item instanceof File && item.size > 0);
  if (limits) {
    const rejections = rejectAttachmentFiles(files, limits);
    if (rejections.length)
      throw new Error(
        `附件未通过检查：${rejections.map((x) => `${x.file}（${x.reason}）`).join("；")}`,
      );
  }
  const uncached = files.filter((file) => uploadedFileIDs.get(file) === undefined);
  const fresh = uncached.length ? await uploadImageFiles(uncached) : [];
  uncached.forEach((file, index) => { const id = fresh[index]; if (id !== undefined) uploadedFileIDs.set(file, id); });
  const ids: number[] = [];
  files.forEach((file) => { const id = uploadedFileIDs.get(file); if (typeof id === "number" && Number.isInteger(id) && id > 0 && !ids.includes(id)) ids.push(id); });
  return ids;
}
export function PostForm({
  market = false,
  post,
}: {
  market?: boolean;
  post?: Entity;
}) {
  const ui = useUI(),
    nav = useNavigate();
  const sections = useApi(market ? null : "/api/water/sections");
  return (
    <Form
      fields={[
        {
          name: "title",
          label: market ? "物品名称" : "标题",
          required: market,
          value: post?.title,
        },
        {
          name: "content",
          label: "内容",
          type: "textarea",
          required: true,
          value: post?.content,
        },
        {
          name: "post_type",
          label: market ? "发布类型" : "分区",
          required: true,
          value: post?.post_type,
          options: market
            ? [
                ["marketplace_sell", "出售"],
                ["marketplace_buy", "求购"],
              ]
            : rows(sections.data, "sections").map((s) => [
                s.slug,
                s.title || s.name,
              ]),
        },
        ...(market
          ? [
              {
                name: "price",
                label: "价格",
                type: "number",
                min: 0,
                required: true,
                value: post?.price,
              },
              {
                name: "contact_type",
                label: "联系方式类型",
                value: post?.contact_type || "wechat",
                options: [
                  ["wechat", "微信"],
                  ["qq", "QQ"],
                  ["phone", "电话"],
                ] as [string, string][],
              },
              {
                name: "contact",
                label: "联系方式",
                required: true,
                value: post?.contact,
              },
            ]
          : []),
      ]}
      submit={post ? "保存修改" : "发布"}
      onSubmit={async (_, form) => {
        const ids = await uploadIDs(form);
        form.delete("images");
        form.set("board_id", market ? "2" : "1");
        if (ids.length) form.set("file_ids", JSON.stringify(ids));
        const result = await write(
          post ? `/api/posts/${post.id}` : "/api/posts",
          form,
          post ? "PUT" : "POST",
        );
        ui.close();
        ui.notify("内容已保存");
        nav(`/post/${post?.id || result.post?.id || result.id}`);
      }}
    ><MediaUploadPicker /></Form>
  );
}
function PostAvatar({ author }: { author?: Entity }) {
  const [failed, setFailed] = useState<string>();
  const src = asset(author?.avatar);
  return <span className="post-avatar"><span aria-hidden="true">{(author?.nickname || "同").slice(0, 1)}</span>{src && src !== failed && <img key={src} src={src} alt="" onError={() => setFailed(src)} />}</span>;
}

function PostTime({ value }: { value: unknown }) {
  const valid = typeof value === "string" && Number.isFinite(Date.parse(value));
  return <time dateTime={valid ? value : undefined} title={time(value)}>{valid ? new Date(value).toLocaleString("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }) : ""}</time>;
}

function PostAuthor({ post }: { post: Entity }) {
  const auth = useAuth(), ui = useUI();
  const [pending, setPending] = useState(false);
  const lock = useRef(false);
  const [followed, setFollowed] = useState(Boolean(post.author?.is_following || post.is_following));
  useEffect(() => setFollowed(Boolean(post.author?.is_following || post.is_following)), [post.id, post.author?.is_following, post.is_following]);
  return (
    <div className="author post-author">
      <PostAvatar author={post.author} />
      <div className="author-meta">
        <div className="author-name-line"><b>{post.author?.nickname || "校园同学"}</b><span className="author-level">Lv.{post.author?.level || post.author_level || 1}</span></div>
        <span><PostTime value={post.created_at} />{post.author?.followers_count != null ? ` · ${post.author.followers_count} 位关注者` : ""}</span>
      </div>
      {auth.user && post.author_id && post.author_id !== auth.user.id && (
        <button className={`author-follow ${followed ? "active" : ""}`} type="button" disabled={pending} aria-pressed={followed} aria-busy={pending} onClick={async () => {
          if (lock.current) return;
          lock.current = true;
          setPending(true);
          try { if (await ui.act(() => write(`/api/user/${post.author_id}/follow`, {}, followed ? "DELETE" : "POST"), followed ? "已取消关注" : "已关注")) setFollowed(!followed); }
          finally { lock.current = false; setPending(false); }
        }}>{followed ? "已关注" : "关注"}</button>
      )}
    </div>
  );
}

export function PostCard({
  post,
  market = false,
}: {
  post: Entity;
  market?: boolean;
}) {
  const auth = useAuth();
  const location=useLocation();
  const back={from:location.pathname+location.search};
  if (market)
    return (
      <Link className="market-card" to={`/post/${post.id}`} state={back}>
        <div className="market-img">
          {post.images?.[0] ? (
            <img
              alt={post.title || "物品图片"}
              src={mediaURL(post.images[0], "thumb") || asset(post.images[0].file?.path || post.images[0].url)}
              loading="lazy"
              decoding="async"
            />
          ) : (
            <Icon name="market" size={40} />
          )}
        </div>
        <div className="market-info">
          <span className="tag">
            {post.status === "sold"
              ? "已售出"
              : post.post_type === "marketplace_buy"
                ? "求购"
                : "出售"}
          </span>
          <h3>{post.title || post.content}</h3>
          <strong className="price">¥ {post.price}</strong>
          <div className="market-meta">
            <span>{post.author?.nickname}</span>
            <span>{time(post.created_at)}</span>
          </div>
        </div>
      </Link>
    );
  return (
    <article className="feed-card">
      <PostAuthor key={`author:${post.id}:${auth.user?.id}`} post={post} />
      <Link to={`/post/${post.id}`} state={back}>
        {post.title && <h3 className="post-title">{post.title}</h3>}
        {post.content && <p className={`post-body ${post.title ? "" : "post-text-only"}`}>{post.content.slice(0, 220)}</p>}
      </Link>
      <MediaGallery items={post.images} title={post.title || "帖子图片"} />
      <PostActions key={`actions:${post.id}:${auth.user?.id}`} post={post} from={back.from} />
    </article>
  );
}
export function Community({ market = false }: { market?: boolean }) {
  const ui = useUI(),
    auth = useAuth();
  const [params, setParams] = useSearchParams();
  const page = Number(params.get("page")) || 1,
    sort = params.get("sort") || "all";
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
    }),
  );
  const posts = rows(q.data, "posts");
  function filter(k: string, v: string) {
    const next = new URLSearchParams(params);
    next.set(k, v);
    next.set("page", "1");
    setParams(next);
  }
  return (
    <div className={market ? undefined : "community-page"}>
      <Head
        title={market ? "二手集市" : "校园社区"}
        description={
          market
            ? "校内闲置、求购与交易状态"
            : "关注、分区、精华、投票与校园日常都在这里"
        }
      >
        <button
          className="btn primary"
          onClick={() =>
            auth.requireUser() &&
            ui.open(
              market ? "发布闲置" : "发布内容",
              <PostForm market={market} />,
            )
          }
        >
          ＋ {market ? "发布闲置" : "发布"}
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
            <select aria-label="闲置分类" value={params.get('type')||''} onChange={(e)=>filter('type',e.target.value)}>
              <option value="">全部类型</option><option value="marketplace_sell">出售</option><option value="marketplace_buy">求购</option>
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
      <QueryState query={q}>
        <div className={market ? "market-grid" : "panel community-feed"}>
          {posts.map((post) => (
            <PostCard key={post.id} post={post} market={market} />
          ))}
        </div>
        {!posts.length && <Empty />}
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
export function PostDetail() {
  const location=useLocation(),navigate=useNavigate();
  const commentRef = useRef<HTMLElement>(null);
  const [commentSort, setCommentSort] = useState("hot");
  const { id } = useParams(),
    ui = useUI(),
    auth = useAuth();
  const q = useApi(`/api/posts/${id}`);
  const comments = useInfiniteQuery({
    queryKey: ["api", "post-replies", id, auth.user?.id, commentSort],
    initialPageParam: "",
    queryFn: ({ pageParam, signal }) => request<Entity>(query(`/api/posts/${id}/replies`, { limit: 30, cursor: pageParam, sort: commentSort }), { signal }),
    getNextPageParam: (lastPage) => lastPage.next_cursor || undefined,
    retry: retryInterruptedRead,
  });
  const p = entity(q.data, "post");
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
  return (
    <div className="post-detail-page">
      <header className="page-head post-detail-head">
        <div className="page-title post-detail-heading">
          <Link to={p.board_id === 2 ? "/market" : "/community"}><Icon name={p.board_id === 2 ? "market" : "community"} size={17} /><span>{p.board_id === 2 ? "二手集市" : "校园社区"}</span></Link>
          <span aria-hidden="true" className="post-detail-separator">/</span>
          <h1>帖子详情</h1>
        </div>
        <button className="btn post-back" onClick={()=>location.state?.from?navigate(-1):navigate(p.board_id===2?'/market':'/community')}><Icon name="arrow" size={17} />返回列表</button>
      </header>
      <QueryState query={q}>
        <div className="post-detail-layout">
        <div className="post-detail-main">
        <article className="panel post-full">
          <PostAuthor key={`author:${p.id}:${auth.user?.id}`} post={p} />
          {p.title && <h1>{p.title}</h1>}
          <div className="post-body details-text">{p.content}</div>
          <MediaGallery items={p.images} title={p.title || "帖子图片"} className="post-detail-gallery" maxVisible={9} />
          {p.board_id === 2 && (
            <div className="info-box">
              <b>
                ¥ {p.price} · {p.status === "sold" ? "已售出" : "交易中"}
              </b>
              <p>
                {p.contact_type}：{p.contact || "请通过评论联系"}
              </p>
            </div>
          )}
          <PostActions key={`actions:${p.id}:${auth.user?.id}`} post={p} onComment={focusComments} more={<PostMore>
            {p.images?.[0] && (
              <button type="button" onClick={async () => { if (!auth.requireUser()) return; const path = mediaURL(p.images[0], "origin"); if (!path) return; await ui.act(() => favoritePublicImage(path), "图片已收藏为表情"); }}>
                收藏首图为表情
              </button>
            )}
            <button
              type="button"
              onClick={() =>
                auth.requireUser() && ui.open(
                  "举报内容",
                  <Form
                    fields={[
                      {
                        name: "reason",
                        label: "举报原因",
                        type: "textarea",
                        required: true,
                      },
                    ]}
                    onSubmit={async (data) => {
                      await write("/api/reports", {
                        ...data,
                        target_type: "post",
                        target_id: Number(id),
                      });
                      ui.close();
                      ui.notify("举报已提交");
                    }}
                  />,
                )
              }
            >
              举报
            </button>
            {p.viewer_permissions?.can_edit && (
              <button
                type="button"
                onClick={() =>
                  ui.open(
                    "编辑内容",
                    <PostForm market={p.board_id === 2} post={p} />,
                  )
                }
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
          </PostMore>} />
        </article>
        <section className="panel post-comments section" id="post-comments" ref={commentRef} tabIndex={-1} aria-label="评论区">
          <div className="post-comments-head"><h2>全部评论 <span>{comments.data?.pages[0]?.total ?? p.reply_count ?? 0}</span></h2><select aria-label="评论排序" value={commentSort} onChange={(event) => setCommentSort(event.target.value)}><option value="hot">热门</option><option value="latest">最新</option></select></div>
          <div className="post-comment-prompt"><PostAvatar author={auth.user || undefined} /><button type="button" className="post-comment-start" onClick={() => replyTo()}><span>{auth.user ? "说说你的想法，一起聊聊…" : "登录后参与讨论…"}</span><Icon name="community" size={19} /></button></div>
          <QueryState query={{ ...comments, error: comments.data ? null : comments.error }}>
            {!replies.length && <Empty title="还没有评论" description="分享你的想法，开启这段讨论。" />}
            {roots.map((reply) => <CommentThread key={`${reply.id}:${auth.user?.id}`} postId={Number(id)} reply={reply} preview={replies.filter((child) => Number(child.parent_reply_id) === Number(reply.id))} onReply={replyTo} />)}
            {comments.data && comments.error && <div className="post-comments-error" role="alert"><span>{comments.error.message}</span><button type="button" className="btn" disabled={comments.isFetching} onClick={() => comments.isFetchNextPageError ? comments.fetchNextPage() : comments.refetch()}>重试</button></div>}
            {comments.hasNextPage && <button type="button" className="btn post-load-more" disabled={comments.isFetchingNextPage} onClick={() => comments.fetchNextPage()}>{comments.isFetchingNextPage ? "正在加载…" : "加载更多评论"}</button>}
          </QueryState>
        </section>
        </div>
        <PostDetailRail post={p} replyCount={comments.data?.pages[0]?.total ?? p.reply_count ?? 0} onComment={focusComments} />
        </div>
      </QueryState>
    </div>
  );
}

function PostDetailRail({ post, replyCount, onComment }: { post: Entity; replyCount: number; onComment: () => void }) {
  const auth = useAuth(), location = useLocation();
  const market = post.board_id === 2;
  const more = useQuery({
    queryKey: ["api", "post-detail-more", market, auth.user?.id],
    queryFn: ({ signal }) => request<Entity>(query("/api/posts", { board: market ? 2 : 1, sort: "time", limit: 5, status: market ? "normal" : undefined }), { signal }),
    retry: retryInterruptedRead,
  });
  const posts = rows(more.data, "posts").filter((item) => Number(item.id) > 0 && Number(item.id) !== Number(post.id)).slice(0, 3);
  const browse = market ? "/market?sort=time" : "/community?sort=time";
  return <aside className="post-detail-rail" aria-label="帖子相关信息">
    <section className="rail-card post-context-author">
      <h2>关于作者</h2>
      <div className="post-context-person"><PostAvatar author={post.author} /><div><b>{post.author?.nickname || "校园同学"}</b><span>Lv.{post.author?.level || post.author_level || 1}{post.author?.followers_count != null ? ` · ${post.author.followers_count} 位关注者` : ""}</span></div></div>
      <p className="post-context-time">发布于 <PostTime value={post.created_at} /></p>
      <dl className="post-context-stats"><div><dt>本帖点赞</dt><dd>{post.like_count || 0}</dd></div><div><dt>本帖评论</dt><dd>{replyCount}</dd></div></dl>
      <button type="button" className="btn full-width post-context-comment" onClick={onComment}><Icon name="community" size={17} />查看评论</button>
    </section>
    <section className="rail-card post-context-more" aria-labelledby="post-context-more-title">
      <div className="post-context-title"><h2 id="post-context-more-title">{market ? "最新闲置" : "最新校园讨论"}</h2><Link to={browse}>全部</Link></div>
      {more.isPending ? <p className="post-context-state" role="status">正在加载更多帖子…</p> : more.error ? <div className="post-context-state" role="alert"><p>暂时无法加载更多帖子</p><button type="button" className="btn" disabled={more.isFetching} onClick={() => more.refetch()}>{more.isFetching ? "正在重试…" : "重试"}</button></div> : posts.length ? <div className="post-context-list">{posts.map((item) => <Link key={item.id} className="post-context-item" to={`/post/${item.id}`} state={{ from: location.pathname + location.search }}>
        <b>{item.title || item.content?.slice(0, 80) || (market ? "校园闲置" : "校园讨论")}</b>
        {item.title && item.content && <p>{item.content.slice(0, 100)}</p>}
        <span>{market && item.price != null ? <strong>¥ {item.price}</strong> : <span>{item.author?.nickname || "校园同学"}</span>}<span><Icon name="community" size={13} />{item.reply_count || 0}</span></span>
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

function CommentRow({ reply, onReply }: { reply: Entity; onReply: (reply: Entity) => void }) {
  const auth = useAuth(), ui = useUI();
  const [pending, setPending] = useState(false);
  const locked = useRef(false);
  const deleted = reply.status === "deleted";
  return <article className="post-comment" aria-label={`${reply.author?.nickname || "校园同学"}的评论`}>
    <PostAvatar author={reply.author || reply.user} />
    <div className="post-comment-main">
      <div className="post-comment-author"><b>{reply.author?.nickname || reply.user?.nickname || "校园同学"}</b></div>
      {deleted ? <p className="post-comment-deleted">该评论已删除</p> : <>
        {reply.content && reply.content !== "[表情]" && <p className="details-text">{reply.content}</p>}
        {reply.sticker_id && <StickerRenderer stickerId={reply.sticker_id} assetKey={reply.asset_key} packId={reply.pack_id} />}
        {(reply.images || reply.attachments)?.length > 0 && <MediaGallery items={reply.images || reply.attachments} title="评论图片" maxVisible={4} />}
      </>}
      <div className="post-comment-footer"><PostTime value={reply.created_at} />{!deleted && <div className="post-comment-actions">
        <button type="button" aria-label={`${reply.is_liked ? "取消点赞" : "点赞"}${reply.author?.nickname || "校园同学"}的评论，${reply.like_count || 0}赞`} aria-pressed={!!reply.is_liked} aria-busy={pending} disabled={pending || auth.loading} onClick={async () => {
          if (locked.current || !auth.requireUser()) return;
          locked.current = true; setPending(true);
          try { await ui.act(() => write(`/api/replies/${reply.id}/like`, {}, reply.is_liked ? "DELETE" : "POST"), reply.is_liked ? "已取消点赞" : "已点赞"); }
          finally { locked.current = false; setPending(false); }
        }}><Icon name="heart" size={16} /><span>{reply.like_count || "赞"}</span></button>
        <button type="button" onClick={() => onReply(reply)}><Icon name="community" size={16} />回复</button>
      </div>}</div>
    </div>
  </article>;
}

function CommentThread({ postId, reply, preview, onReply }: { postId: number; reply: Entity; preview: Entity[]; onReply: (reply: Entity) => void }) {
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
    <CommentRow reply={reply} onReply={onReply} />
    {!!visible.length && <div className="post-comment-children">{visible.map((child) => <CommentRow key={`${child.id}:${auth.user?.id}`} reply={child} onReply={onReply} />)}</div>}
    {!expanded && remaining > 0 && <button type="button" className="post-thread-toggle" onClick={() => setExpanded(true)}>展开其余 {remaining} 条回复<Icon name="chevron" size={14} /></button>}
    {expanded && <div className="post-thread-controls"><QueryState query={children}>{children.hasNextPage && <button type="button" className="post-thread-toggle" disabled={children.isFetchingNextPage} onClick={() => children.fetchNextPage()}>{children.isFetchingNextPage ? "正在加载…" : "加载更多回复"}</button>}</QueryState><button type="button" className="post-thread-toggle" onClick={() => setExpanded(false)}>收起回复</button></div>}
  </div>;
}

function ReplyComposer({ postId, parentReplyId, replyToReplyId, replyToUserId, onSent }: { postId: number; parentReplyId?: number; replyToReplyId?: number; replyToUserId?: number; onSent: () => unknown }) {
  const ui = useUI(), auth = useAuth(), qc = useQueryClient();
  const [sticker, setSticker] = useState<StickerPayload | null>(null);
  const [showStickers, setShowStickers] = useState(false);
  return <Form fields={[{ name: "content", label: "写下你的回复", type: "textarea" }]} submit="发布评论" onSubmit={async (_, fd) => {
    if (!auth.requireUser()) return;
    const content = String(fd.get("content") || "").trim();
    if (!content && !sticker && !fd.getAll("images").some((item) => item instanceof File && item.size > 0)) throw new Error("请输入内容、选择图片或表情");
    const hasImages = fd.getAll("images").some((item) => item instanceof File && item.size > 0);
    if (sticker && hasImages) throw new Error("图片和表情不能同时发送");
    const ids = await uploadIDs(fd); fd.delete("images"); if (ids.length) fd.set("file_ids", JSON.stringify(ids));
    if (sticker) { fd.set("sticker_id", sticker.sticker_id); fd.set("asset_key", sticker.asset_key); fd.set("pack_id", sticker.pack_id); if (!content) fd.set("content", "[表情]"); }
    if (parentReplyId) fd.set("parent_reply_id", String(parentReplyId));
    if (replyToReplyId) fd.set("reply_to_reply_id", String(replyToReplyId));
    if (replyToUserId) fd.set("reply_to_user_id", String(replyToUserId));
    await write(`/api/posts/${postId}/replies`, fd); setSticker(null); setShowStickers(false); await qc.invalidateQueries({ queryKey: ["api"] }); await onSent(); ui.notify("回复已发布");
  }}><MediaUploadPicker maxCount={4} /><div className="reply-emoji-row"><button type="button" className="btn" onClick={() => setShowStickers((value) => !value)}>☺ {showStickers ? "收起表情" : "添加表情"}</button>{sticker && <span className="sticker-inline"><StickerRenderer stickerId={sticker.sticker_id} assetKey={sticker.asset_key} packId={sticker.pack_id} label={sticker.label} /><button type="button" className="link-btn" onClick={() => setSticker(null)}>移除</button></span>}</div>{showStickers && <StickerPicker compact onSelect={(value) => { setSticker(value); setShowStickers(false); }} />}</Form>;
}

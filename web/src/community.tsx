import { useState } from "react";
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
export async function uploadIDs(form: FormData) {
  const ids: number[] = [];
  for (const file of form.getAll("images")) {
    if (!(file instanceof File) || !file.size) continue;
    const body = new FormData();
    body.append("file", file);
    const result = await write("/api/upload", body);
    if (!Number.isInteger(result.file_id))
      throw new Error("上传没有返回文件编号");
    ids.push(result.file_id);
  }
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
        {
          name: "images",
          label: "图片（jpg/png/gif，最多 9 张）",
          type: "file",
          multiple: true,
        },
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
    />
  );
}
export function PostCard({
  post,
  market = false,
}: {
  post: Entity;
  market?: boolean;
}) {
  const ui = useUI();
  const location=useLocation();
  const back={from:location.pathname+location.search};
  if (market)
    return (
      <Link className="market-card" to={`/post/${post.id}`} state={back}>
        <div className="market-img">
          {post.images?.[0] ? (
            <img
              alt={post.title || "物品图片"}
              src={asset(post.images[0].file?.path || post.images[0].url)}
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
      <div className="author">
        <div className="author-avatar">
          {post.author?.nickname?.slice(0, 1) || "同"}
        </div>
        <div className="author-meta">
          <b>{post.author?.nickname || "校园同学"}</b>
          <span>{time(post.created_at)}</span>
        </div>
      </div>
      <Link to={`/post/${post.id}`} state={back}>
        <h3 className="post-title">
          {post.title || post.content?.slice(0, 50)}
        </h3>
        <p className="post-body">{post.content?.slice(0, 220)}</p>
      </Link>
      {post.images?.length > 0 && (
        <div className="post-media">
          {post.images.slice(0, 3).map((img: Entity, i: number) => (
            <img
              key={img.id || i}
              alt="帖子图片"
              src={asset(img.file?.path || img.url)}
            />
          ))}
        </div>
      )}
      <div className="post-actions">
        <button
          className={`post-action ${post.is_liked ? "liked" : ""}`}
          onClick={() =>
            ui.act(() =>
              write(
                `/api/posts/${post.id}/like`,
                {},
                post.is_liked ? "DELETE" : "POST",
              ),
            )
          }
        >
          <Icon name="heart" size={16} />
          {post.like_count || 0}
        </button>
        <Link className="post-action" to={`/post/${post.id}`}>
          <Icon name="community" size={16} />
          {post.reply_count || 0}
        </Link>
        <button
          className="post-action"
          onClick={() =>
            ui.act(
              () =>
                navigator.clipboard.writeText(
                  `${window.location.origin}/web/post/${post.id}`,
                ),
              "链接已复制",
            )
          }
        >
          分享
        </button>
      </div>
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
    <>
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
        <div className={market ? "market-grid" : "panel"}>
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
    </>
  );
}
export function PostDetail() {
  const location=useLocation(),navigate=useNavigate();
  const [cursor,setCursor]=useState('');
  const [previousReplies,setPreviousReplies]=useState<Entity[]>([]);
  const { id } = useParams(),
    ui = useUI(),
    auth = useAuth();
  const q = useApi(`/api/posts/${id}`),
    comments = useApi(query(`/api/posts/${id}/replies`,{limit:30,cursor})),
    bookmarks = useApi(auth.user ? "/api/user/bookmarks" : null);
  const p = entity(q.data, "post");
  const [saved, setSaved] = useState<boolean | undefined>();
  const bookmarked = saved ?? rows(bookmarks.data).some((x) => x.id === p.id);
  return (
    <>
      <Head title="帖子详情">
        <button className="btn" onClick={()=>location.state?.from?navigate(-1):navigate(p.board_id===2?'/market':'/community')}>返回列表</button>
      </Head>
      <QueryState query={q}>
        <article className="panel post-full">
          <div className="author-meta">
            <b>{p.author?.nickname}</b>
            <span>{time(p.created_at)}</span>
          </div>
          <h1>{p.title}</h1>
          <div className="post-body details-text">{p.content}</div>
          <div className="post-media">
            {(p.images || []).map((img: Entity) => (
              <a
                key={img.id}
                href={asset(img.file?.path || img.url)}
                target="_blank"
                rel="noreferrer"
              >
                <img alt="帖子图片" src={asset(img.file?.path || img.url)} />
              </a>
            ))}
          </div>
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
          <div className="inline-actions">
            <button
              className="btn"
              onClick={() =>
                ui.act(() =>
                  write(
                    `/api/posts/${id}/like`,
                    {},
                    p.is_liked ? "DELETE" : "POST",
                  ),
                )
              }
            >
              {p.is_liked ? "取消点赞" : "点赞"} {p.like_count || 0}
            </button>
            <button
              className="btn"
              onClick={async () => {
                if (
                  await ui.act(() =>
                    write(
                      `/api/posts/${id}/bookmark`,
                      {},
                      bookmarked ? "DELETE" : "PUT",
                    ),
                  )
                )
                  setSaved(!bookmarked);
              }}
            >
              {bookmarked ? "取消收藏" : "收藏"}
            </button>
            <button
              className="btn"
              onClick={() =>
                ui.open(
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
                className="btn"
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
                className="btn"
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
                className="btn"
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
          </div>
        </article>
        <div className="panel panel-pad section">
          <h2>评论</h2>
          <QueryState query={comments}>
            {[...previousReplies,...rows(comments.data, "replies")].map((r) => (
              <div className="comment-row" key={r.id}>
                <b>{r.author?.nickname || r.user?.nickname}</b>
                <p className="details-text">{r.content}</p>
                <small>{time(r.created_at)}</small>
                <button
                  className="link-btn"
                  onClick={() =>
                    ui.open(
                      "回复评论",
                      <Form
                        fields={[
                          {
                            name: "content",
                            label: "回复内容",
                            type: "textarea",
                            required: true,
                          },
                        ]}
                        onSubmit={async (_, fd) => {
                          fd.set("parent_reply_id", String(r.id));
                          await write(`/api/posts/${id}/replies`, fd);
                          comments.refetch();
                          ui.close();
                        }}
                      />,
                    )
                  }
                >
                  回复
                </button>
              </div>
            ))}
            {comments.data?.next_cursor&&<button className="btn" onClick={()=>{setPreviousReplies(current=>[...current,...rows(comments.data,'replies')]);setCursor(comments.data!.next_cursor)}}>加载更多评论</button>}
          </QueryState>
          <Form
            fields={[
              {
                name: "content",
                label: "写下你的回复",
                type: "textarea",
                required: true,
              },
            ]}
            submit="发布评论"
            onSubmit={async (_, fd) => {
              await write(`/api/posts/${id}/replies`, fd);
              await comments.refetch();
              ui.notify("回复已发布");
            }}
          />
        </div>
      </QueryState>
    </>
  );
}

import { formatScore } from './canteen/canteen-data';
import { CanteenDetailPage } from './canteen/canteen-detail';
import { Link, useParams, useSearchParams } from "react-router-dom";
import { entity, query, rows, useApi, write, asset } from "./api";
import { Empty, Form, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
import { useMobile } from "./mobile";
const detailPaths = {
  campus: "/api/campus/articles",
  competition: "/api/competitions/events",
  canteen: "/api/canteens",
  ratings: "/api/teachers",
} as const;
export type CatalogKind = keyof typeof detailPaths;

export function RatingsList() {
  const title = "教师 · 专业评价";
  const [params, setParams] = useSearchParams();
  const majors = params.get("tab") === "majors";
  const path = majors ? "/api/majors" : detailPaths.ratings;
  const page = Number(params.get("page")) || 1;
  const q = useApi(
    query(path, {
      page,
      limit: 20,
      q: params.get("q"),
      search: params.get("q"),
    }),
  );
  const data = rows(q.data, majors ? "majors" : "teachers");
  return (
    <>
      <Head title={title} description="查询教师和专业，分享学习体验" />
      <Tabs
        tabs={[
          ["teachers", "教师评价"],
          ["majors", "专业评价"],
        ]}
        value={majors ? "majors" : "teachers"}
        onChange={(tab) => setParams({ tab })}
      />
      <form
        className="filter-row catalog-search"
        onSubmit={(e) => {
          e.preventDefault();
          const next = new URLSearchParams(params);
          next.set("q", String(new FormData(e.currentTarget).get("q") || ""));
          next.set("page", "1");
          setParams(next);
        }}
      >
        <input
          name="q"
          defaultValue={params.get("q") || ""}
          placeholder="输入关键词搜索"
          aria-label="搜索"
        />
        <button className="btn">搜索</button>
      </form>
      <QueryState query={q}>
        <div className="panel">
          {data.map((x) => (
            <Link
              className="list-row"
              key={x.id}
              to={`/ratings/${x.id}${majors ? "?tab=majors" : ""}`}
            >
              <div className="author-avatar">
                {(x.name || x.title || title).slice(0, 2)}
              </div>
              <div className="list-main">
                <b>{x.name || x.title}</b>
                <p>
                  {x.course ||
                    x.description ||
                    x.summary ||
                    x.author_department ||
                    ""}
                </p>
              </div>
              <span className="tag">
                {x.average_star
                  ? `${Number(x.average_star).toFixed(1)} 分`
                  : x.level || x.category || "详情"}
              </span>
            </Link>
          ))}
        </div>
        {!data.length && <Empty />}
        <Pagination
          page={page}
          hasMore={data.length === 20}
          onChange={(page) => {
            const next = new URLSearchParams(params);
            next.set("page", String(page));
            setParams(next);
          }}
        />
      </QueryState>
    </>
  );
}

export function CatalogDetail({ kind }: { kind: CatalogKind }) {
  return kind === 'canteen' ? <CanteenDetailPage /> : <CatalogRecordDetail kind={kind} />;
}
function CatalogRecordDetail({ kind }: { kind: Exclude<CatalogKind, "canteen"> }) {
  const { id } = useParams(),
    [params] = useSearchParams(),
    ui = useUI(),
    auth = useAuth(),
    mobile = useMobile();
  const majors = kind === "ratings" && params.get("tab") === "majors";
  const base = majors ? "/api/majors" : detailPaths[kind];
  const q = useApi(`${base}/${id}`);
  const d = entity(
    q.data,
    majors
      ? "major"
      : kind === "ratings"
        ? "teacher"
        : kind === "competition"
          ? "event"
          : "article",
    ...(kind === "campus" ? ["item"] : []),
    "data",
  );
  // 保留通用详情原有的禁用查询订阅及缓存生命周期。
  useApi(null);
  const subtitle = [
    d.course || d.category || d.location || [d.location_area, d.location_floor].filter(Boolean).join(" · ") || d.author_department,
    typeof d.publish_date === "string" && d.publish_date.slice(0, 10),
  ].filter(Boolean).join(" · ");
  return (
    <>
      <Head title={d.title || d.name || "详情"} description={subtitle || undefined}>
        <Link className="btn" to={`/${kind}`}>
          返回列表
        </Link>
        {kind === "competition" && (
          <button
            className="btn primary"
            onClick={() =>
              ui.act(
                () =>
                  write(
                    `/api/user/competition-calendar/items/copy-from-official/${id}`,
                  ),
                "已加入个人计划",
              )
            }
          >
            加入计划
          </button>
        )}
        {kind === "ratings" && (
          <button
            className="btn primary"
            onClick={() =>
              auth.requireUser() &&
              ui.open(
                "发表评价",
                <Form
                  fields={[
                    {
                      name: "star",
                      label: "评分（1–5）",
                      type: "number",
                      min: 1,
                      max: 5,
                      required: true,
                    },
                    {
                      name: "comment",
                      label: "具体体验",
                      type: "textarea",
                      required: true,
                    },
                  ]}
                  onSubmit={async (data) => {
                    await write(`${base}/${id}/rate`, {
                      star: Number(data.star),
                      comment: data.comment,
                    });
                    await q.refetch();
                    ui.close();
                    ui.notify("评价已提交，审核状态以服务器为准");
                  }}
                />,
              )
            }
          >
            发表评价
          </button>
        )}
      </Head>
      <QueryState query={q}>
        <div className="panel panel-pad catalog-detail-body">
          {mobile && subtitle && <p className="muted catalog-detail-meta">{subtitle}</p>}
          <p className="details-text">
            {d.content_text || d.description || d.summary || ""}
          </p>
          {d.source_url && (
            <div className="catalog-detail-actions">
              <a
                className="btn"
                href={asset(d.source_url)}
                target="_blank"
                rel="noreferrer"
              >
                查看官方来源
              </a>
            </div>
          )}
          {rows(q.data, "ratings", "reviews").map((r) => (
            <div className="comment-row" key={r.id}>
              <b>{r.user_name || r.user?.nickname || "同学"}</b>
              <span> · {formatScore(r.star || r.overall_score)} 分</span>
              <p className="details-text">{r.comment}</p>
              {r.is_own && (
                <button
                  className="link-btn"
                  onClick={() =>
                    ui.open(
                      "删除评价",
                      <>
                        <p>删除自己的这条评价？</p>
                        <button
                          className="btn"
                          onClick={async () => {
                            if (
                              await ui.act(() =>
                                write(`${base}/rating/${r.id}`, {}, "DELETE"),
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
                  删除我的评价
                </button>
              )}
            </div>
          ))}
        </div>
      </QueryState>
    </>
  );
}


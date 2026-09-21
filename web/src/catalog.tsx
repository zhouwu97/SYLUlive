import { CompetitionPersonal } from "./competition-personal";
import {CampusMap} from './campus-map';
import {CanteenReviewForm,CanteenReviews,CanteenContributions,DishDetail} from './canteen';
import { Link, useParams, useSearchParams } from "react-router-dom";
import { entity, query, rows, time, useApi, write, asset } from "./api";
import { Empty, Form, Head, Pagination, QueryState, Tabs, useUI } from "./ui";
import { useAuth } from "./auth";
const sources = {
  campus: ["校园服务", "/api/campus/articles", "articles"],
  competition: ["竞赛中心", "/api/competitions/events", "events"],
  canteen: ["食堂与菜品", "/api/canteens", "canteens"],
  ratings: ["教师 · 专业评价", "/api/teachers", "teachers"],
} as const;
export type CatalogKind = keyof typeof sources;
export function Catalog({ kind }: { kind: CatalogKind }) {
  const [params, setParams] = useSearchParams(),
    ui = useUI();
  const [title, base, key] = sources[kind];
  const majors = kind === "ratings" && params.get("tab") === "majors";
  const path = majors ? "/api/majors" : base;
  const page = Number(params.get("page")) || 1;
  const q = useApi(
    query(path, {
      page,
      limit: 20,
      q: params.get("q"),
      search: params.get("q"),
    }),
  );
  const data = rows(q.data, majors ? "majors" : key);
  return (
    <>
      <Head
        title={title}
        description={
          kind === "campus"
            ? "学校公告、校历与服务信息"
            : kind === "competition"
              ? "竞赛目录与个人参赛计划"
              : kind === "canteen"
                ? "发现食堂，分享真实的就餐体验"
                : "查询教师和专业，分享学习体验"
        }
      >
        {kind === 'canteen' && <button className="btn" onClick={()=>ui.open('我的食堂贡献',<CanteenContributions/>)}>我的贡献</button>}
        {kind === "competition" && (
          <button
            className="btn"
            onClick={() => ui.open("我的竞赛计划", <CompetitionPersonal />)}
          >
            我的计划
          </button>
        )}
        {kind === "campus" && (
          <button className="btn" onClick={()=>ui.open('校园地图',<CampusMap/>)}>校园地图</button>
        )}
        {kind === "campus" && (
          <button
            className="btn"
            onClick={() => ui.open("学校校历", <Calendar />)}
          >
            查看校历
          </button>
        )}
      </Head>
      {kind === "ratings" && (
        <Tabs
          tabs={[
            ["teachers", "教师评价"],
            ["majors", "专业评价"],
          ]}
          value={majors ? "majors" : "teachers"}
          onChange={(tab) => setParams({ tab })}
        />
      )}
      <form
        className="filter-row"
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
        <div className={kind === "canteen" ? "dish-list" : "panel"}>
          {data.map((x) => (
            <Link
              className={
                kind === "competition"
                  ? "comp-row"
                  : kind === "canteen"
                    ? "dish"
                    : "list-row"
              }
              key={x.id}
              to={`/${kind}/${x.id}${majors ? "?tab=majors" : ""}`}
            >
              <div
                className={
                  kind === "competition" ? "comp-logo" : "author-avatar"
                }
              >
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
function Calendar() {
  const q = useApi("/api/campus-calendars/current");
  const d = entity(q.data, "calendar", "data");
  return (
    <QueryState query={q}>
      <h3>{d.academic_year || "当前校历"}</h3>
      <p>{d.term_start || d.start_date || d.description}</p>
      {(d.image_url || d.url) && (
        <a href={asset(d.image_url || d.url)} target="_blank" rel="noreferrer">
          打开学校校历
        </a>
      )}
      <p>{d.updated_at ? `更新时间：${time(d.updated_at)}` : ""}</p>
    </QueryState>
  );
}
function Plans() {
  const q = useApi("/api/user/competition-calendar");
  return (
    <QueryState query={q}>
      {rows(q.data, "items").map((x) => (
        <div className="list-row" key={x.id}>
          <b>{x.title || x.name}</b>
          <p>{x.start_date || x.status}</p>
        </div>
      ))}
      {!rows(q.data, "items").length && <Empty title="暂无个人计划" />}
    </QueryState>
  );
}
export function CatalogDetail({ kind }: { kind: CatalogKind }) {
  const { id } = useParams(),
    [params] = useSearchParams(),
    ui = useUI(),
    auth = useAuth();
  const majors = kind === "ratings" && params.get("tab") === "majors";
  const base = majors ? "/api/majors" : sources[kind][1];
  const q = useApi(`${base}/${id}`);
  const d = entity(
    q.data,
    majors
      ? "major"
      : kind === "ratings"
        ? "teacher"
        : kind === "canteen"
          ? "canteen"
          : kind === "competition"
            ? "event"
            : "article",
    "data",
  );
  const dishes = useApi(
    kind === "canteen" ? `/api/canteens/${id}/dishes` : null,
  );
  return (
    <>
      <Head title={d.title || d.name || "详情"}>
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
        {(kind === "ratings" || kind === "canteen") && (
          <button
            className="btn primary"
            onClick={() =>
              auth.requireUser() &&
              ui.open(
                "发表评价",
                kind === 'canteen' ? <CanteenReviewForm id={id!}/> : <Form
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
        <div className="panel panel-pad">
          <h2>{d.title || d.name}</h2>
          <p className="muted">
            {d.course || d.category || d.location || d.author_department}
          </p>
          <p className="details-text">
            {d.content_text || d.description || d.summary || ""}
          </p>
          {d.source_url && (
            <a
              className="btn"
              href={asset(d.source_url)}
              target="_blank"
              rel="noreferrer"
            >
              查看官方来源
            </a>
          )}
          {rows(q.data, "ratings", "reviews").map((r) => (
            <div className="comment-row" key={r.id}>
              <b>{r.user_name || r.user?.nickname || "同学"}</b>
              <span> · {r.star || r.overall_score} 分</span>
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
        {kind === "canteen" && (
          <div className="section">
            <h2>就餐评价</h2><CanteenReviews id={id!}/>
            <h2>菜品</h2>
            <QueryState query={dishes}>
              <div className="dish-list">
                {rows(dishes.data, "dishes").map((dish) => (
                  <div className="dish" key={dish.id}>
                    <h3>{dish.name}</h3>
                    <p>{dish.description}</p>
                    <span>{dish.average_star || "暂无评分"}</span>
                    <button className="btn" onClick={()=>ui.open(dish.name,<DishDetail canteenId={id!} id={dish.id}/>)}>查看菜品</button>
                  </div>
                ))}
              </div>
            </QueryState>
          </div>
        )}
      </QueryState>
    </>
  );
}


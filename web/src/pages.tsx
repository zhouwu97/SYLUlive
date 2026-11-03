import { useAcademic } from "./academic";
import { PublicPosts, isPublicPost } from "./campus-chrome";
import { ServerAvatar } from "./server-avatar";
import { useMobile } from "./mobile";
import { MobileHome } from "./mobile-home";
import { useDesktopHomeFeed } from "./desktop-home-feed";
import { PaperLibrary } from './papers';
import { teachingWeek, mergeCourses } from "@sylulive/academic-contracts";
import {
  PostCard as CommunityPostCard,
  PostForm as CommunityPostForm,
} from "./community";
import { useEffect, useMemo, useRef, useState } from "react";
import { Link, useParams, useNavigate, useSearchParams } from "react-router-dom";
import {
  useApi,
  rows,
  entity,
  query,
  write,
  time,
  asset,
  downloadJSON,
  errorText,
  ApiError,
  type Entity,
} from "./api";
import { useAuth } from "./auth";
import { bridge } from "./bridge";
import {
  Empty,
  Form,
  Head,
  Icon,
  Pagination,
  QueryState,
  Stats,
  Tabs,
  useUI,
} from "./ui";
import {
  gradeStats,
  parseBackup,
  type AcademicBackup,
  type AcademicProvider,
  type AcademicTerm,
  type Course,
  type Grade,
} from "@sylulive/academic-contracts";

function Card({
  children,
  className = "",
}: {
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <section className={`panel panel-pad ${className}`}>{children}</section>
  );
}
function List({
  items,
  empty = "暂无数据",
  render,
}: {
  items: Entity[];
  empty?: string;
  render: (item: Entity, index: number) => React.ReactNode;
}) {
  return items.length ? (
    <div className="data-list">{items.map(render)}</div>
  ) : (
    <Empty text={empty} />
  );
}
function useRows(path: string | null, ...keys: string[]) {
  const q = useApi<Entity>(path);
  return { ...q, items: rows(q.data, ...keys) };
}
export function Dashboard() {
  return useMobile() ? <MobileHome /> : <DesktopDashboard />;
}
function DesktopDashboard() {
  const nav = useNavigate(), ui = useUI(), auth = useAuth();
  const [params, setParams] = useSearchParams();
  const sort = params.get("sort") || "all";
  const posts = useDesktopHomeFeed(sort);
  const loadMore = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const target = loadMore.current;
    if (!target || !posts.hasNextPage || posts.isFetching || posts.error) return;
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) void posts.fetchNextPage();
    }, { rootMargin: "0px 0px 320px 0px" });
    observer.observe(target);
    return () => observer.disconnect();
  }, [posts.hasNextPage, posts.isFetching, posts.error, posts.fetchNextPage]);
  const articles = useApi("/api/campus/articles?page=1&page_size=4");
  const hour = new Date().getHours();
  const greeting = hour < 6 ? "夜深了" : hour < 12 ? "早上好" : hour < 18 ? "下午好" : "晚上好";
  const pages = posts.data?.pages || [];
  const items = [...new Map(pages.flatMap(page => rows(page, "posts")).map(post => [post.id, post])).values()];
  const publicPosts = rows(pages[0], "pinned_posts").filter(isPublicPost);
  const pinned = [...new Map([...publicPosts, ...items.filter(isPublicPost)].map(post => [post.id, post])).values()];
  const feed = items.filter(post => !pinned.some(item => item.id === post.id));
  const expired = posts.error instanceof ApiError && posts.error.code === "feed_session_expired";
  const publish = () => auth.requireUser() && ui.open("发布内容", <CommunityPostForm />);
  return <div className="campus-home">
    <header className="feed-masthead">
      <div><h1>{greeting}，{auth.user?.nickname || "同学"}。</h1><p>看看同学们的新鲜事，也分享你的校园日常。</p></div>
      <Link className="calendar-link" to="/campus"><Icon name="schedule" size={14} />校园日历</Link>
    </header>
    <section className="campus-brief" aria-label="校园速报">
      <div className="brief-lead"><span>今天</span><b>校园速报</b></div>
      {articles.isPending ? <p className="brief-status" role="status">正在读取校园资讯…</p> : articles.error ? <div className="brief-status"><span>校园资讯暂不可用</span><button className="link-btn" onClick={() => articles.refetch()}>重试</button></div> : rows(articles.data).length ? rows(articles.data).slice(0, 3).map(article => <Link key={article.id} to={`/campus/${article.id}`} className="brief-item"><span>{article.publish_date?.slice(5, 10).replace("-", ".") || "校园"}</span><span><b>{article.title}</b><small>{article.author_department || "校园公开信息"}</small></span></Link>) : <p className="brief-status">今天还没有新的校园资讯。<Link to="/campus">去校园服务看看 →</Link></p>}
    </section>
    <section className="campus-composer" aria-label="分享校园日常">
      <div className="composer-row"><span className="composer-avatar"><ServerAvatar key={auth.user?.id} src={auth.user?.avatar} name={auth.user?.nickname || "沈理校园"} /></span><button className="composer-trigger" aria-label="分享校园日常" onClick={publish}><span>今天在校园里遇见什么？</span><span className="composer-prompt-action" aria-hidden="true"><Icon name="plus" size={16} /></span></button></div>
      <div className="composer-bottom"><div className="composer-tools"><button onClick={publish}><span className="composer-tool-icon"><Icon name="file" size={17} /></span>图文</button><button onClick={() => nav("/community")}><span className="composer-tool-icon"><Icon name="community" size={17} /></span>逛校园圈</button><button onClick={() => nav("/polls")}><span className="composer-tool-icon"><Icon name="polls" size={17} /></span>投票 · 组队</button></div><Link to="/feedback">共建友好校园</Link></div>
    </section>
    <div className="home-feed-heading"><h2>校园动态</h2><Link className="home-feed-more" to="/community">全部动态 <span aria-hidden="true">→</span></Link></div>
    <div className="home-feed-toolbar"><Tabs tabs={[["all", "推荐"], ["time", "最新"], ["following", "关注"], ["hot", "热门"]]} value={sort} onChange={value => setParams({ sort: value })} /></div>
    <div className="dashboard-feed">
      {sort === "following" && !auth.loading && !auth.user ? <Empty title="登录后查看关注动态" description="关注同学，看看他们的校园日常。"><button className="btn primary" onClick={auth.login}>登录</button></Empty> : <QueryState query={{ isPending: posts.isPending, error: posts.data ? null : posts.error, refetch: posts.refetch }}>
        <PublicPosts posts={pinned} />
        {feed.map(post => <CommunityPostCard post={post} key={post.id} />)}
        {!feed.length && <Empty title="暂时没有新的校园动态" description="分享一段校园日常，开启讨论。" />}
      </QueryState>}
    </div>
    <div ref={loadMore} className="dashboard-feed-end">
      {posts.data && (posts.isFetchNextPageError ? <><p role="alert">{expired ? "信息流已更新，请刷新后继续浏览。" : "后续内容加载失败，已读帖子已保留。"}</p><button className="btn" onClick={() => expired ? posts.refetch() : posts.fetchNextPage()}>{expired ? "刷新动态" : "重试加载"}</button></>
        : posts.isRefetchError ? <><p role="alert">刷新未完成，已读帖子已保留。</p><button className="btn" onClick={() => posts.refetch()}>重新刷新</button></>
          : posts.hasNextPage ? <button className="btn" disabled={posts.isFetching} onClick={() => posts.fetchNextPage()}>{posts.isFetching ? "正在加载…" : "加载更多"}</button>
            : feed.length > 0 && <span>已经看完啦</span>)}
    </div>
    <Link className="browse-community" to="/community">继续逛逛校园圈 <span aria-hidden="true">→</span></Link>
  </div>;
}

export function Exams() {
  const ui = useUI(),
    { data, setData } = useAcademic();
  const [params,setParams]=useSearchParams();
  const tab=params.get('tab')||'schedule';
  function edit(exam?: Entity) {
    ui.open(
      exam ? "编辑考试" : "录入考试",
      <Form
        fields={[
          {
            name: "name",
            label: "考试名称",
            required: true,
            value: exam?.name,
          },
          {
            name: "startTime",
            label: "开始时间",
            type: "datetime-local",
            required: true,
            value: exam?.startTime,
          },
          {
            name: "endTime",
            label: "结束时间",
            type: "datetime-local",
            required: true,
            value: exam?.endTime,
          },
          { name: "room", label: "地点", value: exam?.room },
        ]}
        onSubmit={async (values) => {
          if (Date.parse(values.endTime) <= Date.parse(values.startTime))
            throw new Error("结束时间必须晚于开始时间");
          const next = {
            id: exam?.id || crypto.randomUUID(),
            name: String(values.name),
            startTime: String(values.startTime),
            endTime: String(values.endTime),
            room: String(values.room),
            semester: data.term.year + "-" + data.term.semester,
          };
          setData((s) => ({
            ...s,
            exams: [...s.exams.filter((e) => e.id !== next.id), next],
          }));
          ui.close();
        }}
      >
        {exam && (
          <button
            className="btn"
            type="button"
            onClick={() => {
              setData((s) => ({
                ...s,
                exams: s.exams.filter((e) => e.id !== exam.id),
              }));
              ui.close();
            }}
          >
            删除考试
          </button>
        )}
      </Form>,
    );
  }
  return (
    <>
      <Head
        title="考试与试卷库"
        description="考试安排、倒计时、历史试卷与资料共享"
      >
        <button
          className="btn"
          onClick={() =>
            downloadJSON("sylulive-exams.json", {
              version: 1,
              semester: data.term.year + '-' + data.term.semester,
              export_time: new Date().toISOString(),
              exams: data.exams.map(e=>({...e,location:e.room})),
            })
          }
        >
          导出考试
        </button>
        <button className="btn primary" onClick={() => edit()}>
          录入考试
        </button>
      </Head>
      <Tabs tabs={[["schedule","考试安排"],["papers","试卷库"],["mine","我的提交"]]} value={tab} onChange={value=>setParams(value==='mine'?{tab:value,papers:'mine'}:{tab:value})}/>
      {tab!=='schedule'?<PaperLibrary/>:<>
      <div className="filter-row">
        <label className="file-upload-control">
          <span>导入考试 JSON</span>
          <b>选择存档</b>
          <input
            className="file-upload-input"
            type="file"
            accept="application/json,.json"
            onChange={async (e) => {
              const file = e.target.files?.[0];
              if (!file) return;
              try {
                const value = JSON.parse(await file.text());
                if(value.version !== 1 || !Array.isArray(value.exams))throw new Error('不支持的考试存档格式');
                const parsed = parseBackup(
                  JSON.stringify({
                    ...data,
                    termStart: data.termStart || "2000-01-01",
                    exams: value.exams.map((e:Entity)=>({...e,id:e.id||crypto.randomUUID(),room:e.room??e.location??'',semester:e.semester||value.semester||''})),
                  }),
                );
                setData((s) => ({ ...s, exams: parsed.exams }));
                ui.notify("考试导入成功");
              } catch (error) {
                ui.notify(errorText(error));
              }
            }}
          />
          <small>仅支持 JSON 格式</small>
        </label>
      </div>
      <div className="panel">
        {[...data.exams]
          .sort((a, b) => Date.parse(a.startTime) - Date.parse(b.startTime))
          .map((exam) => (
            <div className="list-row" key={exam.id}>
              <div className="author-avatar">
                {Math.max(
                  0,
                  Math.ceil(
                    (Date.parse(exam.startTime) - Date.now()) / 86400000,
                  ),
                )}
                d
              </div>
              <div className="list-main">
                <b>{exam.name}</b>
                <p>
                  {new Date(exam.startTime).toLocaleString("zh-CN")} ·{" "}
                  {exam.room || "地点待定"}
                </p>
              </div>
              <button className="btn" onClick={() => edit(exam)}>
                编辑
              </button>
            </div>
          ))}
        {!data.exams.length && <Empty text="还没有考试安排" />}
      </div>
      </>}
    </>
  );
}

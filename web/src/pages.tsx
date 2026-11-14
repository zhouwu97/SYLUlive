import { useAcademic } from "./academic";
import { PublicPosts, isPublicPost } from "./campus-chrome";
import { ServerAvatar } from "./server-avatar";
import { useMobile } from "./mobile";
import { MobileHome } from "./mobile-home";
import { useDesktopHomeFeed } from "./desktop-home-feed";
import { feedSourceOf } from "./feed-feedback";
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
// 首页常用入口：与侧栏、顶栏互补的六个高频功能。
const HOME_QUICK = [["schedule", "课表"], ["grades", "成绩"], ["exams", "考试"], ["canteen", "食堂"], ["competition", "竞赛"], ["toolbox", "工具箱"]] as const;
function dayLabel(termStart?: string) {
  const now = new Date(), weekday = `周${"日一二三四五六"[now.getDay()]}`;
  const week = termStart ? teachingWeek(termStart, now) : 0;
  return week > 0 && week <= 30 ? `第 ${week} 周 · ${weekday}` : `${now.getMonth() + 1}月${now.getDate()}日 · ${weekday}`;
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
  const academic = useAcademic();
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
    <section className="home-hero" aria-label="今日">
      <div className="home-hero-top">
        <div><h1>{greeting}，{auth.user?.nickname || "同学"}。</h1><p>看看同学们的新鲜事，也分享你的校园日常。</p></div>
        <Link className="home-week" to="/campus" aria-label={`${dayLabel(academic.data.termStart)}，打开校园日历`}><Icon name="schedule" size={14} />{dayLabel(academic.data.termStart)}</Link>
      </div>
      <nav className="home-quick" aria-label="常用入口">
        {HOME_QUICK.map(([id, label]) => <Link key={id} to={`/${id}`}><span className={`home-quick-icon tone-${id}`}><Icon name={id} size={20} /></span>{label}</Link>)}
      </nav>
    </section>
    <section className="campus-composer" aria-label="分享校园日常">
      <div className="composer-row"><span className="composer-avatar"><ServerAvatar key={auth.user?.id} src={auth.user?.avatar} name={auth.user?.nickname || "沈理校园"} /></span><button className="composer-trigger" aria-label="分享校园日常" onClick={publish}><span>今天在校园里遇见了什么？</span></button>
        <div className="composer-tools"><button onClick={publish}><Icon name="file" size={17} />图文</button><button onClick={() => nav("/polls")}><Icon name="polls" size={17} />投票</button><button onClick={() => nav("/polls?tab=team")}><Icon name="community" size={17} />组队</button></div></div>
    </section>
    <div className="home-feed-heading"><h2>校园动态</h2><Tabs tabs={[["all", "推荐"], ["time", "最新"], ["following", "关注"], ["hot", "热门"]]} value={sort} onChange={value => setParams({ sort: value })} /><Link className="home-feed-more" to="/community">全部动态 <span aria-hidden="true">→</span></Link></div>
    <div className="dashboard-feed">
      {sort === "following" && !auth.loading && !auth.user ? <Empty icon="lock" title="登录后查看关注动态" description="关注同学，看看他们的校园日常。"><button className="btn primary" onClick={auth.login}>登录</button></Empty> : <QueryState skeleton="feed" query={{ isPending: posts.isPending, error: posts.data ? null : posts.error, refetch: posts.refetch }}>
        {pinned.length > 0 && <PublicPosts posts={pinned} />}
        {feed.map(post => <CommunityPostCard post={post} key={post.id} feedSource={feedSourceOf(sort)} />)}
        {!feed.length && <Empty title="暂时没有新的校园动态" description="分享一段校园日常，开启讨论。" />}
      </QueryState>}
    </div>
    <div ref={loadMore} className="dashboard-feed-end">
      {posts.data && (posts.isFetchNextPageError ? <><p role="alert">{expired ? "信息流已更新，请刷新后继续浏览。" : "后续内容加载失败，已读帖子已保留。"}</p><button className="btn" onClick={() => expired ? posts.refetch() : posts.fetchNextPage()}>{expired ? "刷新动态" : "重试加载"}</button></>
        : posts.isRefetchError ? <><p role="alert">刷新未完成，已读帖子已保留。</p><button className="btn" onClick={() => posts.refetch()}>重新刷新</button></>
          : posts.hasNextPage ? <button className="btn" disabled={posts.isFetching} onClick={() => posts.fetchNextPage()}>{posts.isFetching ? "正在加载…" : "加载更多"}</button>
            : feed.length > 0 && <span>已经看完啦</span>)}
    </div>
    <Link className="browse-community" to="/community">查看全部动态 <span aria-hidden="true">→</span></Link>
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
        {!data.exams.length && <Empty icon="exams" text="还没有考试安排" description="录入考试或导入 JSON 后，这里会显示倒计时。" />}
      </div>
      </>}
    </>
  );
}

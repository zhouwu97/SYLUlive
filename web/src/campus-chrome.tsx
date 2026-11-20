import { useEffect, useRef } from "react";
import { Link } from "react-router-dom";
import { mergeCourses, teachingWeek } from "@sylulive/academic-contracts";
import { useAcademic } from "./academic";
import { asset, entity, rows, useApi, type Entity } from "./api";
import { useAuth } from "./auth";
import { Icon } from "./ui";
import { ServerAvatar } from "./server-avatar";
import { displayName, userLevel } from "./user-level";
import { LevelBadge } from "./level-badge";

export function ProfileSummary() {
  const auth = useAuth();
  const profile = useApi(auth.user ? "/api/user/profile" : null);
  const person = entity(profile.data, "user", "data");
  const name = displayName(person.nickname || auth.user?.nickname);
  return <section className="profile-rail-card" aria-label="校园个人资料">
    {/* 侧栏只保留品牌渐变装饰，个人封面只在个人主页展示 */}
    <div className="profile-rail-cover" aria-hidden="true" />
    {auth.user ? <Link className="profile-rail-head" to="/profile" title="我的主页">
      <div className="profile-rail-avatar"><ServerAvatar src={person.avatar || auth.user?.avatar} name={name} /></div>
      <div><b>{name}</b><p><LevelBadge className="profile-level" level={userLevel(person)} /></p></div>
      <span className="profile-rail-go" aria-hidden="true"><Icon name="chevron" size={15} /></span>
    </Link> : <div className="profile-rail-head">
      <div className="profile-rail-avatar"><ServerAvatar src={undefined} name="沈理校园" /></div>
      <div><b>{auth.loading ? "正在读取账号…" : "欢迎来到沈理校园"}</b><p>登录后管理收藏、课表与互动</p></div>
    </div>}
    {/* 只展示用户自己写的简介；没写就不显示，不用占位文案冒充 */}
    {auth.user && person.bio && <p className="profile-bio">{person.bio}</p>}
    {auth.user && <div className="profile-rail-stats">
      <Link to="/profile" title="查看我的主页"><b>{person.total_likes_received ?? person.like_count ?? 0}</b><small>获赞</small></Link>
      <Link to="/profile?view=followers" title="查看我的粉丝"><b>{person.followers_count ?? person.follower_count ?? 0}</b><small>粉丝</small></Link>
      <Link to="/profile?view=following" title="查看我的关注"><b>{person.following_count ?? person.following ?? 0}</b><small>关注</small></Link>
    </div>}
    {!auth.user && <button className="btn primary full-width" disabled={auth.loading} onClick={auth.login}>登录并参与讨论</button>}
  </section>;
}

export function SidebarBoards() {
  const boards = useApi("/api/water/sections");
  return <section className="sidebar-boards" aria-label="校园板块">
    <div className="rail-title"><b>校园板块</b><Link to="/community">全部</Link></div>
    {boards.isPending ? <p className="rail-status" role="status">正在加载板块…</p> : boards.error ? <div className="rail-status"><p>暂时无法读取板块</p><button className="link-btn" onClick={() => boards.refetch()}>重试</button></div> : rows(boards.data, "sections").length ? rows(boards.data, "sections").slice(0, 5).map(board => <Link className="sidebar-board" key={board.id || board.slug} to={`/community?type=${encodeURIComponent(board.slug)}`}><span className="board-avatar"><ServerAvatar src={board.avatar_url} name={board.title || board.name || "校园板块"} fallback={board.icon_key ? <Icon name={({ school: "schedule", menu_book: "file", emoji_events: "competition", local_florist: "campus", mood: "community", lightbulb: "ai", warning: "info" } as Record<string, string>)[board.icon_key] || board.icon_key} size={17} /> : undefined} /></span><span>{board.title || board.name}</span>{board.post_count != null && <small>{board.post_count}</small>}</Link>) : <p className="rail-status">暂时没有校园板块</p>}
  </section>;
}

// 与 App 课表页一致的大节作息（每两小节合并）。
const PERIODS = [["1–2", "08:00", "09:40"], ["3–4", "10:00", "11:40"], ["5–6", "13:00", "14:40"], ["7–8", "14:50", "16:30"], ["9–10", "16:40", "18:20"], ["11–12", "19:30", "21:10"]] as const;
const minutes = (value: string) => { const [h, m] = value.split(":").map(Number); return h * 60 + m; };
const periodRangeLabel = (periods: number[]) => {
  if (!periods.length) return "";
  const sorted = [...periods].sort((a, b) => a - b);
  return sorted.length === 1 ? `第${sorted[0]}节` : `${sorted[0]}–${sorted[sorted.length - 1]}节`;
};

export function TodaySchedule() {
  const academic = useAcademic();
  const hasSchedule = !!academic.updated || academic.data.courses.length > 0 || Object.values(academic.data.overrides).some(Boolean);
  const week = academic.data.termStart ? teachingWeek(academic.data.termStart) : null;
  const today = mergeCourses(academic.data.courses, academic.data.overrides)
    .filter(course => course.day === (new Date().getDay() || 7) && (!week || course.weeks.includes(week)))
    .sort((a, b) => Math.min(...a.periods) - Math.min(...b.periods));
  const now = new Date().getHours() * 60 + new Date().getMinutes();
  const upcoming = Math.min(Math.max(PERIODS.findIndex(([, , end]) => minutes(end) > now), 0), PERIODS.length - 2);
  return <section className="rail-card today-card" aria-label="今日课表">
    <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="schedule" size={16} /></span>{week ? `今日课表 · 第 ${week} 周` : "今日课表"}</b><Link to="/schedule">完整课表</Link></div>
    {hasSchedule ? (
      today.length ? (
        <>
          <div className="today-summary">
            <div className="today-copy">
              <h2>{today[0].name}</h2>
            </div>
            <div className="today-side">
              <span className="today-time">{today.length}</span>
              <span>今日课程</span>
            </div>
          </div>
          <ol className="today-courses" aria-label="今日排课">
            {today.slice(0, 3).map(course => (
              <li key={course.id}>
                <span className="today-course-slot">{periodRangeLabel(course.periods)}</span>
                <span className="today-course-main">
                  <b>{course.name}</b>
                  <small>{[course.room && `@${course.room}`, course.teacher].filter(Boolean).join(" · ") || "已排课"}</small>
                </span>
              </li>
            ))}
          </ol>
        </>
      ) : (
        <div className="today-copy is-compact">
          <h2>今天没有课程</h2>
          <p>今日无排课安排，可查看完整周课表。</p>
        </div>
      )
    ) : (
      <>
        <div className="today-copy is-compact">
          <h2>课表尚未连接</h2>
          <p>连接教务或手机扫码后显示今日课程与教室。</p>
        </div>
        <ol className="today-slots" aria-label="接下来的上课时间">{PERIODS.slice(upcoming, upcoming + 2).map(([name, start, end]) => <li key={name} className={now >= minutes(start) && now < minutes(end) ? "is-now" : ""}><b>{name} 节</b><span>{start} – {end}</span></li>)}</ol>
      </>
    )}
    <Link className="btn" to="/schedule">{hasSchedule ? `查看今日课表${today.length ? `（共 ${today.length} 门）` : ""}` : "连接教务助手"}</Link>
  </section>;
}

// 本周日历：用校园公开通知的发布日期标出本周有新通知的日子。
export function WeekCalendar() {
  const articles = useApi("/api/campus/articles?page=1&page_size=20");
  const now = new Date(), today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const monday = new Date(today); monday.setDate(today.getDate() - ((today.getDay() + 6) % 7));
  const days = Array.from({ length: 7 }, (_, index) => { const day = new Date(monday); day.setDate(monday.getDate() + index); return day; });
  const key = (day: Date) => `${day.getFullYear()}-${String(day.getMonth() + 1).padStart(2, "0")}-${String(day.getDate()).padStart(2, "0")}`;
  const counts = new Map<string, number>();
  for (const article of rows(articles.data)) { const date = String(article.publish_date || "").slice(0, 10); counts.set(date, (counts.get(date) || 0) + 1); }
  const total = days.reduce((sum, day) => sum + (counts.get(key(day)) || 0), 0);
  return <section className="rail-card week-calendar-card" aria-label="通知日历">
    <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="schedule" size={16} /></span>通知日历</b><Link to="/campus" aria-label="查看校园通知">{now.getMonth() + 1} 月</Link></div>
    <div className="week-calendar">
      {["一", "二", "三", "四", "五", "六", "日"].map(label => <span key={label} className="week-calendar-label" aria-hidden="true">{label}</span>)}
      {days.map(day => { const count = counts.get(key(day)) || 0, isToday = key(day) === key(today); return <span key={key(day)} className={`week-calendar-day ${isToday ? "is-today" : ""} ${count ? "has-notice" : ""}`} aria-label={`${day.getMonth() + 1}月${day.getDate()}日${isToday ? "，今天" : ""}${count ? `，${count} 条通知` : ""}`}>{day.getDate()}</span>; })}
    </div>
    <p className="week-calendar-note">{articles.isPending ? "正在读取本周通知…" : articles.error ? <>本周通知暂不可用 <button className="link-btn" onClick={() => articles.refetch()}>重试</button></> : total ? <><i aria-hidden="true" />本周已收录 {total} 条通知，<Link to="/campus">去看看</Link></> : "已收录的信息中暂无本周通知"}</p>
  </section>;
}

function formatMarketRailLabel(post: Entity): { text: string; isNote?: boolean } {
  const numeric = post.price == null || post.price === "" ? NaN : Number(post.price);
  if (Number.isFinite(numeric) && numeric > 0) return { text: `¥${post.price}` };
  const kind = String(post.post_type || post.type || "");
  if (kind === "found") return { text: "招领 · 待认领", isNote: true };
  if (kind === "lost") return { text: "寻物 · 寻找中", isNote: true };
  if (kind === "proxy") return { text: "办事 · 待议", isNote: true };
  if (kind === "buy" || kind === "marketplace_buy") return { text: "求购 · 待议", isNote: true };
  return numeric === 0 ? { text: "免费送" } : { text: "价格待议", isNote: true };
}

// 集市新上架：只取带图片的公开条目，非标价类条目显示对应分类状态。
export function MarketRail() {
  const market = useApi("/api/posts?board=2&sort=time&limit=6&status=normal");
  const items = rows(market.data, "posts").filter(post => Array.isArray(post.images) && post.images.length).slice(0, 2);
  return <section className="rail-card market-rail-card" aria-label="集市新上架">
    <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="market" size={16} /></span>集市新上架</b><Link to="/market">去逛逛</Link></div>
    <RailStatus pending={market.isPending} error={!!market.error} empty={!items.length} retry={() => market.refetch()} />
    {!market.error && items.length > 0 && <div className="market-rail">{items.map(post => { const image = post.images[0]; const tag = formatMarketRailLabel(post); return <Link key={post.id} to={`/post/${post.id}`} className="market-rail-item"><span className="market-rail-thumb"><img src={asset(image.medium_url || image.viewer_url || image.file?.path)} alt="" loading="lazy" /></span><span className="market-rail-copy"><b>{post.title || post.content || "闲置物品"}</b><span className={`market-rail-price${tag.isNote ? " is-note" : ""}`}>{tag.text}</span></span></Link>; })}</div>}
  </section>;
}

function RailStatus({ pending, error, empty, retry }: { pending: boolean; error: boolean; empty: boolean; retry: () => void }) {
  if (pending) return <p className="rail-status" role="status">正在加载…</p>;
  if (error) return <div className="rail-status" role="alert"><p>暂时无法加载</p><button className="link-btn" onClick={retry}>重试</button></div>;
  return empty ? <p className="rail-status">暂时没有新内容</p> : null;
}

function CampusNewsItem({ article }: { article: Entity }) {
  const published = typeof article.publish_date === "string" ? /^(\d{4})-(\d{2})-(\d{2})(?:$|T| )/.exec(article.publish_date) : null;
  const date = published && Number(published[2]) >= 1 && Number(published[2]) <= 12 && Number(published[3]) >= 1 && Number(published[3]) <= 31 ? published : null;
  const isToday = !!date && date[0].slice(0, 10) === new Date().toLocaleDateString("sv-SE");
  return <Link to={`/campus/${article.id}`} className={`campus-event${isToday ? " is-today" : ""}`} title={article.title}>
    {date ? <time className="event-date" dateTime={date[0].slice(0, 10)} aria-label={`${date[1]}年${date[2]}月${date[3]}日`}><span className="event-month">{Number(date[2])}月</span><span className="event-day">{date[3]}</span></time> : <span className="event-date event-date-unknown">校园</span>}
    <span className="event-copy"><b>{article.title}</b><small className="event-source"><Icon name="campus" size={12} /><span title={article.author_department || "校园公开信息"}>{article.author_department || "校园公开信息"}</span>{isToday && <em className="event-new">今日</em>}</small></span>
  </Link>;
}

function useStickyRail() {
  const ref = useRef<HTMLElement>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const TOP = 83;
    const BOTTOM = 16;
    let lastY = window.scrollY;
    let top = TOP;
    const sync = () => {
      if (window.innerWidth < 1080) {
        el.style.top = "";
        return;
      }
      const minTop = window.innerHeight - el.offsetHeight - BOTTOM;
      if (minTop >= TOP || window.scrollY <= 0) {
        top = TOP;
      } else {
        const dy = window.scrollY - lastY;
        top = Math.max(minTop, Math.min(TOP, top - dy));
      }
      lastY = window.scrollY;
      el.style.top = `${Math.round(top)}px`;
    };
    sync();
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    window.addEventListener("scroll", sync, { passive: true });
    window.addEventListener("resize", sync, { passive: true });
    return () => {
      ro.disconnect();
      window.removeEventListener("scroll", sync);
      window.removeEventListener("resize", sync);
    };
  }, []);
  return ref;
}

export function CampusRail() {
  const railRef = useStickyRail();
  const articles = useApi("/api/campus/articles?page=1&page_size=4");
  const hot = useApi("/api/posts?board=1&page=1&limit=5&sort=hot");
  return <aside ref={railRef} className="right-rail" aria-label="校园速览">
    <TodaySchedule />
    <WeekCalendar />
    <section className="rail-card campus-events-card" data-state={articles.isPending ? 'loading' : articles.error ? 'error' : rows(articles.data).length ? 'ready' : 'empty'}>
      <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="bell" size={16} /></span>校园正在发生</b><Link to="/campus">全部</Link></div>
      <RailStatus pending={articles.isPending} error={!!articles.error} empty={!rows(articles.data).length} retry={() => articles.refetch()} />
      {!articles.error && <div className="campus-events">{rows(articles.data).slice(0, 4).map(article => <CampusNewsItem key={article.id} article={article} />)}</div>}
    </section>
    <section className="rail-card campus-hot-card" data-state={hot.isPending ? 'loading' : hot.error ? 'error' : rows(hot.data, 'posts').length ? 'ready' : 'empty'}>
      <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="trending" size={16} /></span>校园热榜</b><Link to="/community?sort=hot">全部</Link></div>
      <RailStatus pending={hot.isPending} error={!!hot.error} empty={!rows(hot.data, "posts").length} retry={() => hot.refetch()} />
      {!hot.error && <div className="campus-hot-list">{rows(hot.data, "posts").slice(0, 5).map((post, index) => <Link key={post.id} to={`/post/${post.id}`} className="campus-hot-item"><span className="hot-rank">{String(index + 1).padStart(2, "0")}</span><span>{post.title || post.content}</span><small>{post.reply_count ?? 0} 讨论</small></Link>)}</div>}
    </section>
    <MarketRail />
    <p className="rail-footer"><Link to="/feedback">我的工单</Link><span> · </span><Link to="/toolbox">校园工具箱</Link><span> · </span><Link to="/campus">校园服务</Link><br />© 沈理校园 · 连接校园日常</p>
  </aside>;
}

// 公共帖子沿用服务端置顶的展示范围；过期置顶仍作为普通帖子显示。
export function isPublicPost(post: Entity) {
  return Boolean((post.is_pinned && (!post.pinned_until || Date.parse(post.pinned_until) > Date.now())) || post.water_section_pinned);
}

export function PublicPosts({ posts }: { posts: Entity[] }) {
  return <section className="public-posts" aria-label="公共帖子">
    <span className="public-posts-icon"><Icon name="bookmark" size={17} /></span>
    <div className="public-posts-copy"><h2>公共帖子</h2>{posts.length ? posts.map(post => <Link key={post.id} to={`/post/${post.id}`} className="public-post-link"><span><b>{post.title || "校园公共帖子"}</b>{post.content && <small>{post.content.slice(0, 100)}</small>}</span><span className="public-post-detail">看详情</span></Link>) : <p>暂时没有公共帖子，先看看同学们的校园日常。</p>}</div>
  </section>;
}

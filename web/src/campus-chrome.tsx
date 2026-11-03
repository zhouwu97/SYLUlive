import { Link } from "react-router-dom";
import { mergeCourses, teachingWeek } from "@sylulive/academic-contracts";
import { useAcademic } from "./academic";
import { entity, rows, useApi, type Entity } from "./api";
import { useAuth } from "./auth";
import { Icon } from "./ui";
import { ServerAvatar } from "./server-avatar";
import { userLevel } from "./user-level";

export function ProfileSummary() {
  const auth = useAuth();
  const profile = useApi(auth.user ? "/api/user/profile" : null);
  const person = entity(profile.data, "user", "data");
  const name = person.nickname || auth.user?.nickname || "校园同学";
  return <section className="profile-rail-card" aria-label="校园个人资料">
    <div className="profile-rail-head">
      <div className="profile-rail-avatar"><ServerAvatar src={person.avatar || auth.user?.avatar} name={auth.user ? name : "沈理校园"} /></div>
      <div><b>{auth.loading ? "正在读取账号…" : auth.user ? name : "欢迎来到沈理校园"}</b><p>{auth.user ? <><span className="profile-level">Lv.{userLevel(person)}</span><span className="profile-meta-separator"> · </span><span className="profile-role">校园观察员</span></> : "连接校园里的每一天"}</p></div>
    </div>
    <p className="profile-bio">{person.bio || (auth.user ? "把普通日子记得认真一点。" : "分享日常，发现同频的校园生活。")}</p>
    {auth.user && <div className="profile-rail-stats">
      <span><b>{person.total_likes_received ?? person.like_count ?? 0}</b><small>获赞</small></span>
      <span><b>{person.followers_count ?? person.follower_count ?? 0}</b><small>关注者</small></span>
      <span><b>{person.following_count ?? person.following ?? 0}</b><small>关注</small></span>
    </div>}
    {auth.user ? <Link className="profile-home" to="/profile">进入我的主页 <Icon name="arrow" size={14} /></Link> : <button className="btn primary full-width" disabled={auth.loading} onClick={auth.login}>登录并参与讨论</button>}
  </section>;
}

export function SidebarBoards() {
  const boards = useApi("/api/water/sections");
  return <section className="sidebar-boards" aria-label="校园板块">
    <div className="rail-title"><b>校园板块</b><Link to="/community">全部</Link></div>
    {boards.isPending ? <p className="rail-status" role="status">正在加载板块…</p> : boards.error ? <div className="rail-status"><p>暂时无法读取板块</p><button className="link-btn" onClick={() => boards.refetch()}>重试</button></div> : rows(boards.data, "sections").length ? rows(boards.data, "sections").slice(0, 5).map(board => <Link className="sidebar-board" key={board.id || board.slug} to={`/community?type=${encodeURIComponent(board.slug)}`}><span className="board-avatar"><ServerAvatar src={board.avatar_url} name={board.title || board.name || "校园板块"} fallback={board.icon_key ? <Icon name={({ school: "schedule", menu_book: "file", emoji_events: "competition", local_florist: "campus", mood: "community", lightbulb: "ai", warning: "info" } as Record<string, string>)[board.icon_key] || board.icon_key} size={17} /> : undefined} /></span><span>{board.title || board.name}</span>{board.post_count != null && <small>{board.post_count}</small>}</Link>) : <p className="rail-status">暂时没有校园板块</p>}
  </section>;
}

export function TodaySchedule() {
  const academic = useAcademic();
  const hasSchedule = !!academic.updated || academic.data.courses.length > 0;
  const week = academic.data.termStart ? teachingWeek(academic.data.termStart) : null;
  const today = mergeCourses(academic.data.courses, academic.data.overrides).filter(course => course.day === (new Date().getDay() || 7) && (!week || course.weeks.includes(week)));
  return <section className="rail-card today-card" aria-label="今日课表">
    <div className="today-copy">
      <span className="today-label"><Icon name="schedule" size={16} />{week ? `今日课表 · 第 ${week} 周` : "今日课表"}</span>
      <h2>{today[0]?.name || (hasSchedule ? "今天没有课程" : "课表尚未连接")}</h2>
      <p>{today[0] ? `${today[0].room} · ${today[0].teacher} · 第 ${today[0].periods.join("、")} 节` : hasSchedule ? "留点时间，发现校园里的小美好。" : "连接教务助手，随时查看今天的安排。"}</p>
    </div>
    {hasSchedule && <div className="today-side"><div className="today-time">{today.length}</div><span>今日课程</span></div>}
    <Link className="btn" to="/schedule">{hasSchedule ? "查看今日课表" : "连接教务助手"}<span aria-hidden="true">→</span></Link>
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
  return <Link to={`/campus/${article.id}`} className="campus-event" title={article.title}>
    {date ? <time className="event-date" dateTime={date[0].slice(0, 10)} aria-label={`${date[1]}年${date[2]}月${date[3]}日`}><span className="event-month">{Number(date[2])}月</span><span className="event-day">{date[3]}</span></time> : <span className="event-date event-date-unknown">校园</span>}
    <span className="event-copy"><b>{article.title}</b><small className="event-source"><Icon name="campus" size={12} /><span title={article.author_department || "校园公开信息"}>{article.author_department || "校园公开信息"}</span></small></span>
  </Link>;
}

export function CampusRail() {
  const articles = useApi("/api/campus/articles?page=1&page_size=4");
  const hot = useApi("/api/posts?board=1&page=1&limit=5&sort=hot");
  return <aside className="right-rail" aria-label="校园速览">
    <TodaySchedule />
    <section className="rail-card campus-events-card">
      <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="bell" size={16} /></span>校园正在发生</b><Link to="/campus">全部 <span aria-hidden="true">→</span></Link></div>
      <RailStatus pending={articles.isPending} error={!!articles.error} empty={!rows(articles.data).length} retry={() => articles.refetch()} />
      {!articles.error && <div className="campus-events">{rows(articles.data).slice(0, 4).map(article => <CampusNewsItem key={article.id} article={article} />)}</div>}
    </section>
    <section className="rail-card campus-hot-card">
      <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="trending" size={16} /></span>校园热榜</b><Link to="/community?sort=hot">全部 <span aria-hidden="true">→</span></Link></div>
      <RailStatus pending={hot.isPending} error={!!hot.error} empty={!rows(hot.data, "posts").length} retry={() => hot.refetch()} />
      {!hot.error && <div className="campus-hot-list">{rows(hot.data, "posts").slice(0, 5).map((post, index) => <Link key={post.id} to={`/post/${post.id}`} className="campus-hot-item"><span className="hot-rank">{String(index + 1).padStart(2, "0")}</span><span>{post.title || post.content}</span><small>{post.reply_count ?? 0} 讨论</small></Link>)}</div>}
    </section>
    <section className="rail-card">
      <div className="rail-title"><b><span className="rail-heading-icon"><Icon name="toolbox" size={16} /></span>校园服务</b><Link to="/toolbox">全部 <span aria-hidden="true">→</span></Link></div>
      <div className="rail-services">{[["schedule", "我的课表", "课程安排"], ["grades", "成绩查询", "学期成绩"], ["campus", "校园公告", "校内资讯"], ["canteen", "食堂指南", "用餐参考"]].map(([id, title, description]) => <Link key={id} to={`/${id}`}><span className="rail-service-icon"><Icon name={id} size={18} /></span><span className="rail-service-copy"><b>{title}</b><small>{description}</small></span></Link>)}</div>
    </section>
    <p className="rail-footer">沈理校园 · 连接校园日常<br /><Link to="/feedback">意见反馈</Link><span> · </span><Link to="/toolbox">更多校园工具</Link></p>
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

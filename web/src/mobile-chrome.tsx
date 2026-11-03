import { Link, NavLink, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "./auth";
import { PostForm } from "./community";
import { Icon, Tabs, useUI } from "./ui";

const destinations = [
  ["/", "首页", "home"],
  ["/market", "集市", "market"],
  ["/schedule", "课表", "schedule"],
  ["/campus", "校园", "campus"],
  ["/profile", "我", "profile"],
];

function MobileNavIcon({ name }: { name: string }) {
  const paths: Record<string, string> = {
    home: "M12 2 1 11h3v10h6v-6h4v6h6V11h3L12 2Z",
    market: "M4 2h16l3 6a4 4 0 0 1-7 2 4 4 0 0 1-8 0 4 4 0 0 1-7-2l3-6Zm0 10v10h16V12a6 6 0 0 1-4-1 6 6 0 0 1-8 0 6 6 0 0 1-4 1ZM6 4 5 8h2l1-4H6Zm5 0v4h2V4h-2Zm5 0 1 4h2l-1-4h-2Z",
    schedule: "M6 1h2v3h8V1h2v3h2a2 2 0 0 1 2 2v15a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2V1ZM4 9v12h16V9H4Zm3 2h2v2H7v-2Zm4 0h2v2h-2v-2Zm4 0h2v2h-2v-2Zm-8 5h2v2H7v-2Zm4 0h2v2h-2v-2Zm4 0h2v2h-2v-2Z",
    campus: "M8 2h8v5h5v15h-8v-5h-2v5H3V7h5V2Zm2 2v2h4V4h-4Zm0 4v2h4V8h-4Zm-5 2v2h2v-2H5Zm12 0v2h2v-2h-2Zm-7 2v2h4v-2h-4Zm-5 3v2h2v-2H5Zm12 0v2h2v-2h-2Zm-12 4v2h2v-2H5Zm12 0v2h2v-2h-2Z",
    profile: "M12 2a5 5 0 1 1 0 10 5 5 0 0 1 0-10Zm0 12c5 0 9 3 9 6v2H3v-2c0-3 4-6 9-6Z",
  };
  return <svg width="24" height="24" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d={paths[name]} fillRule="evenodd" /></svg>;
}

export function MobileHeader({ menu, onMenu }: { menu: boolean; onMenu: () => void }) {
  const location = useLocation(), navigate = useNavigate();
  const auth = useAuth();
  const [params, setParams] = useSearchParams();
  const home = location.pathname === "/";
  if (location.pathname.startsWith("/post/") || /^\/polls\/\d+/.test(location.pathname) || !home && destinations.some(([path]) => path === location.pathname)) return null;
  const titles: Record<string, string> = { community: "校园社区", messages: "消息", grades: "教务中心", exams: "考试与试卷库", campus: "校园资讯", canteen: "食堂", competition: "竞赛中心", ratings: "校园榜单", polls: "校园投票", ai: "校园 Agent", toolbox: "工具箱", feedback: "意见反馈", notifications: "通知", "connected-apps": "已授权助手", admin: "管理中心" };
  return <header className={`mobile-header ${home ? "mobile-home-header" : ""}`}>
    <button className="mobile-icon-button" aria-label={home ? "打开导航" : "返回上一页"} aria-expanded={home ? menu : undefined} onClick={home ? onMenu : () => window.history.state?.idx ? navigate(-1) : navigate("/")}><Icon name={home ? "menu" : "arrow"} /></button>
    {home ? <Tabs tabs={[["time", "最新"], ["all", "综合"], ["featured", "精华"], ["following", "关注"]]} value={params.get("sort") || "all"} onChange={sort => {
      if (sort === "following" && !auth.requireUser()) return;
      setParams({ sort });
    }} /> : <b className="mobile-header-title" role="heading" aria-level={1}>{titles[location.pathname.split("/")[1]] || "沈理校园"}</b>}
    {!home && !auth.user ? <button className="mobile-icon-button" onClick={auth.login}>登录</button> : <Link className="mobile-icon-button" to="/messages" aria-label="私信消息"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M4 4h16v13H8l-4 4V4Z" /></svg></Link>}
  </header>;
}

export function MobileNavigation() {
  const location = useLocation(), auth = useAuth(), ui = useUI();
  if (!destinations.some(([path]) => path === location.pathname)) return null;
  const market = location.pathname === "/market";
  return <>
    {["/", "/market"].includes(location.pathname) && <button className={`mobile-publish ${market ? "mobile-market-publish" : ""}`} aria-label={market ? "发布闲置" : "发布校园内容"} onClick={() => auth.requireUser() && ui.open(market ? "发布闲置" : "发布内容", <PostForm market={market} />)}>{market ? <Icon name="plus" size={23} /> : <svg width="23" height="23" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="m16 3 5 5-12 12H4v-5L16 3Zm2-2a2 2 0 0 1 3 0l2 2a2 2 0 0 1 0 3l-1 1-5-5 1-1Z" /></svg>}{market && <span>发布</span>}</button>}
    <nav className="mobile-bottom-nav" aria-label="底部导航">
      {destinations.map(([path, label, icon]) => <NavLink key={path} to={path} end><MobileNavIcon name={icon} /><span>{label}</span></NavLink>)}
    </nav>
  </>;
}

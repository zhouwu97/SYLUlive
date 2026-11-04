import { StrictMode, useEffect, useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BrowserRouter,
  Link,
  NavLink,
  Route,
  Routes,
  useLocation,
  useNavigate,
} from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AuthProvider, useAuth } from "./auth";
import { Empty, Icon, UIProvider, useUI, DialogOutlet } from "./ui";
import { useApi } from "./api";
import { CampusRail, ProfileSummary, SidebarBoards } from "./campus-chrome";
import { ServerAvatar } from "./server-avatar";
import {
  Dashboard,
  Exams,
} from "./pages";
import {Toolbox} from './toolbox';
import {Profile} from './profile';
import "./styles.css";
import "./social-shell.css";
import "./web-polish.css";
import { useWorkspaceMotion } from "./shell-motion";
import {Admin} from "./admin";
import { Polls } from "./polls";
import {Competition} from './competition';
import {CanteenPage} from './canteen-page';
import {Campus} from './campus';
import { Catalog, CatalogDetail, type CatalogKind } from "./catalog";
import { AiPage } from "./ai";
import { Feedback, TicketDetail, Notifications } from "./feedback";
import { Community, PostDetail, PostForm } from "./community";
import { AcademicProvider, Schedule, Grades } from "./academic";
import { ConnectedApps, ConnectedAction } from "./connected-apps";
import { Messages } from "./messages";
import "./commons.css";
import { useMobile } from "./mobile";
import { MobileHeader, MobileNavigation } from "./mobile-chrome";
import "./mobile-app.css";
import "./auth.css";
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 15000, refetchOnWindowFocus: false },
  },
});
const scrollPositions = new Map<string,number>();
export const navigation = [
  ["dashboard", "校园首页"],
  ["community", "校园社区"],
  ["messages", "私信"],
  ["market", "二手集市"],
  ["schedule", "课表"],
  ["grades", "成绩与学业"],
  ["exams", "考试 · 试卷库"],
  ["campus", "校园服务"],
  ["canteen", "食堂与菜品"],
  ["competition", "竞赛中心"],
  ["ratings", "教师 · 专业评价"],
  ["polls", "投票 · 组队"],
  ["ai", "AI 校园助手"],
  ["toolbox", "工具箱"],
  ["feedback", "反馈与工单"],
  ["profile", "我的主页"],
  ["admin", "管理中心"],
];
function Search() {
  const [value, setValue] = useState("");
  const navigate = useNavigate();
  const ui = useUI();
  const matches = navigation.filter(([, name]) => name.toLowerCase().includes(value.trim().toLowerCase()));
  return (
    <>
      <input
        className="full-width"
        autoFocus
        aria-label="搜索功能"
        placeholder="搜索功能，例如课表、工单、竞赛…"
        value={value}
        onChange={(e) => setValue(e.target.value)}
      />
      <div className="palette-results">
        {matches.map(([id, name]) => (
            <button
              className="palette-result"
              key={id}
              onClick={() => {
                navigate(id === "dashboard" ? "/" : `/${id}`);
                ui.close();
              }}
            >
              <Icon name={id} />
              <b>{name}</b>
            </button>
          ))}
      </div>
      {!matches.length && <div role="status"><Empty title="没有找到相关功能" description="试试课表、集市或校园，也可以清空搜索查看全部入口。"><button className="btn" onClick={() => setValue("")}>清空搜索</button></Empty></div>}
    </>
  );
}
function Shell() {
  const [menu, setMenu] = useState(false);
  const [navigationMotion, setNavigationMotion] = useState(true);
  const [dark, setDark] = useState(
    () => localStorage.getItem("sylulive-theme") === "dark",
  );
  const ui = useUI(),
    auth = useAuth(),
    location = useLocation(),
    navigate = useNavigate();
  const active = location.pathname.split("/")[1] || "dashboard";
  const mobile = useMobile();
  const workspace = useWorkspaceMotion(location.pathname, navigationMotion);
  const unread = useApi(auth.user ? '/api/user/notifications/unread-count' : null);
  const messageUnread = useApi(auth.user ? '/api/messages/unread_count' : null);
  useEffect(() => {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    localStorage.setItem("sylulive-theme", dark ? "dark" : "light");
  }, [dark]);
  useEffect(() => {
    setMenu(false);
  }, [location.pathname]);
  useLayoutEffect(()=>{
    const position=scrollPositions.get(location.key)||0;
    const saveScroll=()=>scrollPositions.set(location.key,window.scrollY);
    window.addEventListener('scroll',saveScroll,{passive:true});
    const frame=requestAnimationFrame(()=>{
      window.scrollTo(0,position);
    });
    return ()=>{
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll',saveScroll);
    };
  },[location.key,mobile]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        ui.open("搜索功能", <Search />);
      }
      if (e.key === "Escape") setMenu(false);
    };
    window.addEventListener("keydown", key);
    return () => window.removeEventListener("keydown", key);
  }, [ui]);
  useEffect(() => {
    const hash = location.hash.slice(1);
    if (navigation.some(([id]) => id === hash))
      navigate(hash === "dashboard" ? "/" : `/${hash}`, { replace: true });
  }, []);
  const link = ([id, label]: string[]) => (
    <NavLink
      key={id}
      title={label}
      aria-label={label}
      onClick={(event) => setNavigationMotion(event.detail !== 0)}
      to={id === "dashboard" ? "/" : `/${id}`}
      end
      className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`}
    >
      <span className="nav-icon">
        <Icon name={id} />
      </span>
      <span className="nav-text">{label}</span>
      {id === "messages" && Number(messageUnread.data?.unread_count || messageUnread.data?.count) > 0 && <span className="nav-unread">{messageUnread.data?.unread_count || messageUnread.data?.count}</span>}
    </NavLink>
  );
  return (
    <div data-mobile-page={active} className={`app-shell social-shell ${active === "market" ? "market-shell" : ""} ${navigationMotion ? "" : "navigation-instant"}`}>
      <a className="skip-link" href="#mainContent">
        跳到主要内容
      </a>
      <header className="topbar">
        <div className="topbar-inner">
          <button
            className="icon-btn menu-toggle"
            aria-label="打开导航"
            aria-expanded={menu}
            onClick={() => setMenu(!menu)}
          >
            <Icon name="menu" />
          </button>
          <div className="brand">
            <div className="brand-mark"><ServerAvatar src="/web/assets/app-icon.png" name="沈理校园" /></div>
            <div className="brand-copy">
              <b>沈理校园</b>
              <small>SYLUlive · 连接校园日常</small>
            </div>
          </div>
          <nav className="desktop-top-nav" aria-label="快捷导航">
            {[["/", "首页"], ["/community", "校园圈"], ["/market", "集市"], ["/schedule", "学习"], ["/campus", "发现"]].map(([to, label]) => <NavLink key={to} to={to} end={to === "/"}>{label}</NavLink>)}
          </nav>
          <div className="crumb">
            <span>校园</span>
            <span>›</span>
            <b>{navigation.find(([id]) => id === active)?.[1] || "详情"}</b>
          </div>
          <button
            className="search-trigger"
            aria-label="搜索功能"
            onClick={() => ui.open("搜索功能", <Search />)}
          >
            <span>
              <Icon name="search" />
            </span>
            <span className="search-label">搜索校园功能</span>
            <kbd>Ctrl K</kbd>
          </button>
          <div className="top-actions">
            <button
              className="icon-btn"
              aria-label="切换主题"
              onClick={() => setDark(!dark)}
            >
              <Icon name={dark ? "sun" : "moon"} />
            </button>
            <button
              className="icon-btn"
              aria-label="通知中心"
              onClick={() => navigate("/notifications")}
            >
              <Icon name="bell" />
              {Number(unread.data?.unread_count||unread.data?.count)>0&&<span className="notification-count">{unread.data?.unread_count||unread.data?.count}</span>}
            </button>
            <button className="icon-btn header-messages" aria-label="私信消息" onClick={() => navigate("/messages")}>
              <Icon name="messages" />
              {Number(messageUnread.data?.unread_count || messageUnread.data?.count) > 0 && <span className="notification-count">{messageUnread.data?.unread_count || messageUnread.data?.count}</span>}
            </button>
            <button className="btn primary header-publish" aria-label="发布校园内容" onClick={() => auth.requireUser() && ui.open("发布内容", <PostForm />)}><Icon name="plus" size={16} />发布</button>
            <button
              className={auth.user ? 'avatar' : 'btn primary login-button'}
              aria-label={auth.user ? "我的账号" : "登录"}
              onClick={() => (auth.user ? navigate("/profile") : auth.login())}
            >
              {auth.user ? <ServerAvatar key={auth.user.id} src={auth.user.avatar} name={auth.user.nickname || "校园同学"} /> : "登录"}
            </button>
          </div>
        </div>
      </header>
      {mobile && <MobileHeader menu={menu} onMenu={() => setMenu(!menu)} />}
      <div className="frame">
        <button
          className="nav-mask"
          hidden={!menu}
          aria-label="收起导航"
          onClick={() => setMenu(false)}
        />
        <aside className={`sidebar ${menu ? "open" : ""}`} aria-label="主导航">
          <div className="sidebar-scroll">
            {mobile && <div className="mobile-drawer-title"><b>校园服务</b><button className="mobile-icon-button" aria-label="切换主题" onClick={() => setDark(!dark)}><Icon name={dark ? "sun" : "moon"} /></button></div>}
            <ProfileSummary />
            {mobile && !auth.user && <button className="btn primary mobile-drawer-login" onClick={auth.login}>登录</button>}
            {[
              { label: "社区", ids: ["dashboard", "community", "market", "schedule", "polls"] },
              { label: "我的", ids: ["messages"] },
            ].map(({label, ids}) => (
              <div className="nav-section" key={label}>
                <div className="nav-label">{label}</div>
                {ids.map(id => navigation.find(item => item[0] === id)!).map(link)}
              </div>
            ))}
            <div className="personal-feed-links">
              <Link className={`nav-item ${active === "community" && location.search.includes("sort=bookmarks") ? "active" : ""}`} to="/community?sort=bookmarks"><span className="nav-icon"><Icon name="bookmark" /></span><span className="nav-text">我的收藏</span></Link>
              <Link className={`nav-item ${active === "community" && location.search.includes("sort=mine") ? "active" : ""}`} to="/community?sort=mine"><span className="nav-icon"><Icon name="file" /></span><span className="nav-text">我的帖子</span></Link>
            </div>
            <SidebarBoards />
            <details className="sidebar-more">
              <summary>学习与校园服务 <Icon name="chevron" size={14} /></summary>
              {["grades", "exams", "competition", "ratings", "campus", "canteen", "ai"].map(id => navigation.find(item => item[0] === id)!).map(link)}
            </details>
          <div className="nav-section sidebar-account">
            {navigation
              .slice(13)
              .filter(
                ([id]) =>
                  id !== "admin" ||
                  ["admin", "super_admin"].includes(auth.user?.role || ""),
              )
              .map(link)}
          </div>
          </div>
          <div className="sidebar-footer">沈理校园 · Web</div>
        </aside>
        <main className="workspace" id="mainContent" ref={workspace}>
          <div className={`workspace-grid ${["dashboard","community","polls"].includes(active)?"":"no-rail"}`}>
            <div className="main-pane">
              {/* 授权成功清理一次性连接码时保留管理草稿；账号切换由页面账号 key 隔离。 */}
              <section key={location.pathname === "/connected-apps" ? location.pathname : `${location.pathname}${location.search}`} className="page active">
                <Routes>
                  <Route path="/" element={<Dashboard />} />
                  <Route path="/community" element={<Community />} />
                  <Route path="/market" element={<Community market />} />
                  <Route path="/messages" element={<Messages />} />
                  <Route path="/post/:id" element={<PostDetail />} />
                  <Route path="/polls/:id" element={<PostDetail poll />} />
                  <Route path="/schedule" element={<Schedule />} />
                  <Route path="/grades" element={<Grades />} />
                  <Route path="/exams" element={<Exams />} />
                  <Route path="/competition" element={<Competition/>}/>
                  <Route path="/canteen" element={<CanteenPage/>}/>
                  <Route path="/campus" element={<Campus/>}/>
                  {(
                    [
                      "ratings",
                    ] as CatalogKind[]
                  ).map((kind) => (
                    <Route
                      key={kind}
                      path={`/${kind}`}
                      element={<Catalog kind={kind} />}
                    />
                  ))}
                  {(
                    [
                      "campus",
                      "canteen",
                      "competition",
                      "ratings",
                    ] as CatalogKind[]
                  ).map((kind) => (
                    <Route
                      key={kind}
                      path={`/${kind}/:id`}
                      element={<CatalogDetail kind={kind} />}
                    />
                  ))}
                  <Route path="/polls" element={<Polls />} />
                  <Route path="/feedback" element={<Feedback />} />
                  <Route path="/feedback/:id" element={<TicketDetail />} />
                  <Route path="/notifications" element={<Notifications />} />
                  <Route
                    path="/admin/feedback/:id"
                    element={<TicketDetail admin />}
                  />
                  <Route path="/ai" element={<AiPage />} />
                  <Route path="/toolbox" element={<Toolbox />} />
                  <Route path="/profile" element={<Profile />} />
                  <Route path="/connected-apps" element={<ConnectedApps />} />
                  <Route path="/connected-apps/actions/:id" element={<ConnectedAction />} />
                  <Route path="/admin" element={<Admin />} />
                  <Route path="*" element={<Dashboard />} />
                </Routes>
              </section>
            </div>
            {["dashboard", "community", "polls"].includes(
              active,
            ) && <CampusRail />}
          </div>
        </main>
      </div>
      {mobile && <MobileNavigation />}
    </div>
  );
}
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <UIProvider>
        <AuthProvider>
          <AcademicProvider>
            <BrowserRouter basename="/web/">
              <Shell />
              <DialogOutlet />
            </BrowserRouter>
          </AcademicProvider>
        </AuthProvider>
      </UIProvider>
    </QueryClientProvider>
  </StrictMode>,
);

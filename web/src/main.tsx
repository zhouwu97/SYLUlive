import { StrictMode, useEffect, useLayoutEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BrowserRouter,
  NavLink,
  Route,
  Routes,
  useLocation,
  useNavigate,
} from "react-router-dom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AuthProvider, useAuth } from "./auth";
import { Icon, UIProvider, useUI, DialogOutlet } from "./ui";
import { useApi, rows } from "./api";
import {
  Dashboard,
  Exams,
} from "./pages";
import {Toolbox} from './toolbox';
import {Profile, UserProfile} from './profile';
import {Avatar} from './post-media';
import "./styles.css";
import {Admin} from "./admin";
import { Polls } from "./polls";
import {Competition} from './competition';
import {CanteenPage} from './canteen-page';
import {Campus} from './campus';
import { Catalog, CatalogDetail, type CatalogKind } from "./catalog";
import { AiPage } from "./ai";
import { Feedback, TicketDetail, Notifications } from "./feedback";
import { Community, PostDetail } from "./community";
import { AcademicProvider, Schedule, Grades } from "./academic";
const queryClient = new QueryClient({
  defaultOptions: {
    queries: { staleTime: 15000, refetchOnWindowFocus: false },
  },
});
const scrollPositions = new Map<string,number>();
export const navigation = [
  ["dashboard", "校园工作台"],
  ["community", "校园社区"],
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
        {navigation
          .filter(([, name]) => name.includes(value))
          .map(([id, name]) => (
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
    </>
  );
}
function Rail() {
  const boards = useApi("/api/water/sections");
  return (
    <aside className="right-rail">
      <div className="rail-card">
        <div className="rail-title">
          <b>考试安排</b>
        </div>
        <div className="rail-body">
          <p className="tiny muted">查看本机录入和导入的考试</p>
          <NavLink className="btn full-width" to="/exams">
            查看考试安排
          </NavLink>
        </div>
      </div>
      <div className="rail-card">
        <div className="rail-title">
          <b>社区分区</b>
          <NavLink className="tiny" to="/community">
            全部
          </NavLink>
        </div>
        <div className="rail-body rail-list">
          {rows(boards.data, "sections")
            .slice(0, 4)
            .map((b, i) => (
              <NavLink
                to={`/community?type=${b.slug}`}
                className="rail-item"
                key={b.id}
              >
                <div className="rail-index">
                  {String(i + 1).padStart(2, "0")}
                </div>
                <div>
                  <b>{b.title || b.name}</b>
                  <p>{b.description || "进入分区"}</p>
                </div>
              </NavLink>
            ))}
          {boards.error && <p className="tiny muted">暂时无法读取分区</p>}
        </div>
      </div>
      <div className="rail-card">
        <div className="rail-title">
          <b>校园服务</b>
        </div>
        <div className="rail-body">
          <NavLink to="/campus">查看学校公告与服务</NavLink>
        </div>
      </div>
    </aside>
  );
}
function Shell() {
  const [menu, setMenu] = useState(false);
  const [mobile, setMobile] = useState(() => matchMedia('(max-width: 760px)').matches);
  const menuButton = useRef<HTMLButtonElement>(null);
  const drawer = useRef<HTMLElement>(null);
  const [dark, setDark] = useState(
    () => localStorage.getItem("sylulive-theme") === "dark",
  );
  const ui = useUI(),
    auth = useAuth(),
    location = useLocation(),
    navigate = useNavigate();
  const active = location.pathname.split("/")[1] || "dashboard";
  const unread = useApi(auth.user ? '/api/user/notifications/unread-count' : null);
  useEffect(() => {
    document.documentElement.dataset.theme = dark ? "dark" : "light";
    localStorage.setItem("sylulive-theme", dark ? "dark" : "light");
  }, [dark]);
  useEffect(() => {
    setMenu(false);
  }, [location.pathname]);
  useEffect(() => {
    const media = matchMedia('(max-width: 760px)');
    const change = () => {setMobile(media.matches); if (!media.matches) setMenu(false);};
    media.addEventListener('change', change);
    return () => media.removeEventListener('change', change);
  }, []);
  useEffect(() => {
    if (!menu) return;
    const nav = drawer.current;
    nav?.querySelector<HTMLElement>('.nav-item')?.focus();
    const trap = (event: KeyboardEvent) => {
      if (event.key !== 'Tab' || !nav) return;
      const items = [...nav.querySelectorAll<HTMLElement>('a[href],button:not(:disabled)')].filter(item => item.getClientRects().length);
      const first = items[0], last = items[items.length - 1];
      if (!first) return;
      if (!nav.contains(document.activeElement) || (!event.shiftKey && document.activeElement === last)) {event.preventDefault(); first.focus();}
      else if (event.shiftKey && document.activeElement === first) {event.preventDefault(); last.focus();}
    };
    document.addEventListener('keydown', trap);
    return () => {
      document.removeEventListener('keydown', trap);
      if (menuButton.current?.getClientRects().length) menuButton.current.focus();
    };
  }, [menu]);
  useLayoutEffect(()=>{
    const main=document.getElementById('mainContent');
    const frame=requestAnimationFrame(()=>main?.scrollTo(0,scrollPositions.get(location.key)||0));
    return ()=>{cancelAnimationFrame(frame);if(main)scrollPositions.set(location.key,main.scrollTop)};
  },[location.key]);
  useEffect(() => {
    const key = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setMenu(false);
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
      to={id === "dashboard" ? "/" : `/${id}`}
      end
      className={({ isActive }) => `nav-item ${isActive ? "active" : ""}`}
    >
      <span className="nav-icon">
        <Icon name={id} />
      </span>
      <span className="nav-text">{label}</span>
    </NavLink>
  );
  return (
    <div className="app-shell">
      <a className="skip-link" href="#mainContent">
        跳到主要内容
      </a>
      <header className="topbar" inert={mobile && menu}>
        <div className="topbar-inner">
          <button
            ref={menuButton}
            className="icon-btn menu-toggle"
            aria-label="打开导航"
            aria-expanded={menu}
            aria-controls="primaryNavigation"
            onClick={() => setMenu(!menu)}
          >
            <Icon name="menu" />
          </button>
          <div className="brand">
            <div className="brand-mark"><img src="/web/assets/app-icon.png" alt="沈理校园" /></div>
            <div className="brand-copy">
              <b>沈理校园</b>
              <small>SYLUlive · 校园工作台</small>
            </div>
          </div>
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
            <span className="search-label">搜索功能…</span>
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
            <button
              className={auth.user ? 'avatar' : 'btn primary login-button'}
              aria-label={auth.user ? "我的账号" : "登录"}
              onClick={() => (auth.user ? navigate("/profile") : auth.login())}
            >
              {auth.user ? <Avatar user={auth.user}/> : "登录"}
            </button>
          </div>
        </div>
      </header>
      <div className="frame">
        <button
          className="nav-mask"
          tabIndex={-1}
          hidden={!menu}
          aria-label="收起导航"
          onClick={() => setMenu(false)}
        />
        <aside ref={drawer} id="primaryNavigation" className={`sidebar ${menu ? "open" : ""}`} aria-label="主导航" inert={mobile && !menu} aria-hidden={mobile && !menu ? true : undefined} role={mobile && menu ? 'dialog' : undefined} aria-modal={mobile && menu ? true : undefined}>
          <div className="drawer-head"><b>校园导航</b><button className="icon-btn" aria-label="关闭导航" onClick={() => setMenu(false)}>×</button></div>
          <div className="sidebar-scroll">
            {[
              [0, 3, "常用"],
              [3, 8, "学业与校园"],
              [8, 13, "探索与工具"],
            ].map(([start, end, label]) => (
              <div className="nav-section" key={label}>
                <div className="nav-label">{label}</div>
                {navigation.slice(Number(start), Number(end)).map(link)}
              </div>
            ))}
          </div>
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
          <div className="sidebar-footer">沈理校园 · Web</div>
        </aside>
        <main className="workspace" id="mainContent" inert={mobile && menu}>
          <div className={`workspace-grid ${["dashboard","community"].includes(active)?"":"no-rail"}`}>
            <div className="main-pane">
              <section className="page active">
                <Routes>
                  <Route path="/" element={<Dashboard />} />
                  <Route path="/community" element={<Community />} />
                  <Route path="/market" element={<Community market />} />
                  <Route path="/post/:id" element={<PostDetail key={location.pathname}/>} />
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
                  <Route path="/user/:id" element={<UserProfile key={location.pathname}/>} />
                  <Route path="/admin" element={<Admin />} />
                  <Route path="*" element={<Dashboard />} />
                </Routes>
              </section>
            </div>
            {["dashboard", "community"].includes(
              active,
            ) && <Rail />}
          </div>
        </main>
      </div>
    </div>
  );
}
createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <UIProvider>
        <AuthProvider>
          <AcademicProvider>
            <BrowserRouter basename="/web">
              <Shell />
              <DialogOutlet />
            </BrowserRouter>
          </AcademicProvider>
        </AuthProvider>
      </UIProvider>
    </QueryClientProvider>
  </StrictMode>,
);

import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useParams } from "react-router-dom";
import { Empty, Head, Icon } from "./ui";
import {
  applyMobileThemeFromCatalog,
  restoreDefaultMobileTheme,
  retryMobileThemeResources,
  useMobileThemeRuntime,
  type CatalogThemeItem,
} from "./mobile-theme";

const ALLOWED_TAGS = [
  "浅色",
  "深色",
  "明暗自适应",
  "简约",
  "清新",
  "可爱",
  "动漫",
  "风景",
  "校园",
  "节日",
  "纯色",
  "高对比",
  "复古",
  "科技",
];

async function fetchJson<T>(url: string, signal?: AbortSignal): Promise<T> {
  const resp = await fetch(url, {
    signal,
    credentials: "same-origin",
    headers: { Accept: "application/json", "X-Requested-With": "SYLUlive-Web" },
  });
  if (!resp.ok) {
    let message = `请求失败 (${resp.status})`;
    let code = "";
    try {
      const data = await resp.json();
      message = String(data.error || data.message || message);
      code = String(data.code || "");
    } catch {
      // 非 JSON 错误体
    }
    const err = new Error(message) as Error & { status?: number; code?: string };
    err.status = resp.status;
    err.code = code;
    throw err;
  }
  return (await resp.json()) as T;
}

export function MobileThemeBackdrop() {
  const runtime = useMobileThemeRuntime();
  if (!runtime.wallpaper) return null;
  const { objectUrl, fit, focalX, focalY, scrim, cssFilter } = runtime.wallpaper;
  return (
    <div className="mobile-theme-wallpaper" aria-hidden="true" data-testid="mobile-theme-wallpaper">
      <img
        src={objectUrl}
        alt=""
        style={{
          objectFit: fit,
          objectPosition: `${(focalX * 100).toFixed(1)}% ${(focalY * 100).toFixed(1)}%`,
          filter: cssFilter,
        }}
      />
      {scrim > 0 && <div className="mobile-theme-wallpaper-scrim" style={{ opacity: scrim }} />}
    </div>
  );
}

export function MobileThemesPage() {
  const runtime = useMobileThemeRuntime();
  const [sort, setSort] = useState<"latest" | "popular">("latest");
  const [selectedTag, setSelectedTag] = useState<string>("");
  const [searchInput, setSearchInput] = useState("");
  const [appliedQuery, setAppliedQuery] = useState("");
  const [items, setItems] = useState<CatalogThemeItem[]>([]);
  const [nextCursor, setNextCursor] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [loadMoreError, setLoadMoreError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const loadMoreControllerRef = useRef<AbortController | null>(null);

  useEffect(() => {
    loadMoreControllerRef.current?.abort();
    loadMoreControllerRef.current = null;
    const controller = new AbortController();
    setLoading(true);
    setLoadingMore(false);
    setError(null);
    setLoadMoreError(null);
    setNextCursor(null);
    const params = new URLSearchParams({ sort });
    if (selectedTag) params.set("tag", selectedTag);
    if (appliedQuery) params.set("q", appliedQuery);
    fetchJson<{ items: CatalogThemeItem[]; nextCursor?: string }>(
      `/api/themes?${params.toString()}`,
      controller.signal,
    )
      .then((data) => {
        if (!controller.signal.aborted) {
          setItems(Array.isArray(data.items) ? data.items : []);
          setNextCursor(typeof data.nextCursor === "string" && data.nextCursor ? data.nextCursor : null);
          setLoading(false);
        }
      })
      .catch((err) => {
        if (!controller.signal.aborted) {
          setError(err instanceof Error ? err.message : "加载主题商城失败");
          setLoading(false);
        }
      });
    return () => {
      controller.abort();
      loadMoreControllerRef.current?.abort();
      loadMoreControllerRef.current = null;
    };
  }, [sort, selectedTag, appliedQuery, reloadTick]);

  const handleLoadMore = () => {
    if (!nextCursor || loading || loadingMore) return;
    loadMoreControllerRef.current?.abort();
    const controller = new AbortController();
    loadMoreControllerRef.current = controller;
    setLoadingMore(true);
    setLoadMoreError(null);
    const params = new URLSearchParams({ sort, cursor: nextCursor });
    if (selectedTag) params.set("tag", selectedTag);
    if (appliedQuery) params.set("q", appliedQuery);
    fetchJson<{ items: CatalogThemeItem[]; nextCursor?: string }>(
      `/api/themes?${params.toString()}`,
      controller.signal,
    )
      .then((data) => {
        if (!controller.signal.aborted && loadMoreControllerRef.current === controller) {
          const incoming = Array.isArray(data.items) ? data.items : [];
          setItems((prev) => {
            const seen = new Set(prev.map((x) => x.familyId));
            return [...prev, ...incoming.filter((x) => !seen.has(x.familyId))];
          });
          setNextCursor(typeof data.nextCursor === "string" && data.nextCursor ? data.nextCursor : null);
          setLoadingMore(false);
        }
      })
      .catch((err) => {
        if (!controller.signal.aborted && loadMoreControllerRef.current === controller) {
          setLoadMoreError(err instanceof Error ? err.message : "加载更多主题失败");
          setLoadingMore(false);
        }
      });
  };

  const onSearchSubmit = (e: FormEvent) => {
    e.preventDefault();
    setAppliedQuery(searchInput.trim());
  };

  return (
    <div className="mobile-themes-page">
      <Head title="外观与主题" description="浏览并应用移动网页主题配色、壁纸与字体" />
      <section className="panel" style={{ padding: 14, marginBottom: 12 }}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 10 }}>
          <div>
            <b>当前移动网页主题</b>
            <p style={{ margin: "4px 0 0", fontSize: 13, color: "var(--text-2)" }}>
              {runtime.saved
                ? `${runtime.saved.name} · v${runtime.saved.version}`
                : "默认外观（沈理青）"}
            </p>
          </div>
          {runtime.saved && (
            <button
              type="button"
              className="btn"
              onClick={() => restoreDefaultMobileTheme()}
            >
              恢复默认
            </button>
          )}
        </div>
        {runtime.storageWarning && (
          <p role="alert" style={{ margin: "8px 0 0", fontSize: 12, color: "var(--danger)" }}>
            {runtime.storageWarning}
          </p>
        )}
        {runtime.resourceError && (
          <div role="status" style={{ marginTop: 8, display: "flex", alignItems: "center", gap: 8, fontSize: 12 }}>
            <span>{runtime.resourceError}</span>
            <button type="button" className="btn" onClick={() => retryMobileThemeResources()}>
              重试资源
            </button>
          </div>
        )}
      </section>

      <form onSubmit={onSearchSubmit} className="mobile-feed-search" style={{ marginInline: 0 }}>
        <Icon name="search" size={18} />
        <input
          aria-label="搜索主题"
          placeholder="搜索主题名称或描述…"
          value={searchInput}
          onChange={(e) => setSearchInput(e.target.value)}
        />
        {appliedQuery && (
          <button
            type="button"
            className="btn"
            onClick={() => {
              setSearchInput("");
              setAppliedQuery("");
            }}
          >
            清除
          </button>
        )}
      </form>

      <div role="tablist" aria-label="主题排序" style={{ display: "flex", gap: 8, margin: "8px 0" }}>
        {([
          ["latest", "最新"],
          ["popular", "热门"],
        ] as const).map(([key, label]) => (
          <button
            key={key}
            type="button"
            role="tab"
            aria-selected={sort === key}
            className={`btn ${sort === key ? "primary" : ""}`}
            onClick={() => setSort(key)}
          >
            {label}
          </button>
        ))}
      </div>

      <div style={{ display: "flex", gap: 6, overflowX: "auto", paddingBottom: 6 }}>
        <button
          type="button"
          className={`btn ${selectedTag === "" ? "primary" : ""}`}
          onClick={() => setSelectedTag("")}
        >
          全部
        </button>
        {ALLOWED_TAGS.map((tag) => (
          <button
            key={tag}
            type="button"
            className={`btn ${selectedTag === tag ? "primary" : ""}`}
            onClick={() => setSelectedTag(selectedTag === tag ? "" : tag)}
          >
            {tag}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="loading-state" role="status">正在加载主题列表…</div>
      ) : error ? (
        <Empty title="无法加载主题商城" description={error}>
          <button type="button" className="btn primary" onClick={() => setReloadTick((v) => v + 1)}>
            重试
          </button>
        </Empty>
      ) : items.length === 0 ? (
        <Empty title="暂无符合条件的主题" description="可切换分类或清空搜索词后查看。" />
      ) : (
        <>
          <div className="mobile-theme-grid">
            {items.map((item) => {
              const isCurrent =
                runtime.saved?.familyId === item.familyId &&
                runtime.saved?.version === item.version;
              return (
                <Link
                  key={item.familyId}
                  to={`/theme/${item.familyId}`}
                  className="mobile-theme-card"
                >
                  <div className="mobile-theme-card-cover">
                    {item.previewLight ? (
                      <img src={item.previewLight} alt={`${item.name} 预览`} loading="lazy" />
                    ) : null}
                    {isCurrent ? (
                      <span className="mobile-theme-badge">使用中</span>
                    ) : item.source === "official" ? (
                      <span className="mobile-theme-badge">官方</span>
                    ) : null}
                  </div>
                  <div className="mobile-theme-card-body">
                    <b>{item.name}</b>
                    <small>{item.author?.nickname || "创作者"} · v{item.version}</small>
                  </div>
                </Link>
              );
            })}
          </div>
          {(nextCursor || loadMoreError) && (
            <div className="mobile-feed-end" style={{ marginTop: 12, textAlign: "center" }}>
              {loadMoreError && (
                <p role="alert" style={{ margin: "0 0 8px", fontSize: 13, color: "var(--danger)" }}>
                  {loadMoreError}
                </p>
              )}
              <button
                type="button"
                className="btn"
                disabled={loadingMore}
                onClick={handleLoadMore}
              >
                {loadingMore ? "正在加载…" : loadMoreError ? "重试加载更多" : "加载更多"}
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

interface BoundThemeDetailState {
  boundId: string;
  item: CatalogThemeItem | null;
  loading: boolean;
  notFound: boolean;
  error: string | null;
}

export function ThemeLandingPage() {
  const { id = "" } = useParams();
  const runtime = useMobileThemeRuntime();
  const [detailState, setDetailState] = useState<BoundThemeDetailState>({
    boundId: id,
    item: null,
    loading: Boolean(id),
    notFound: !id,
    error: null,
  });
  const [applyError, setApplyError] = useState<{ boundId: string; message: string } | null>(null);
  const [reloadTick, setReloadTick] = useState(0);

  useEffect(() => {
    const requestedId = id;
    if (!requestedId) {
      setDetailState({ boundId: "", item: null, loading: false, notFound: true, error: null });
      return;
    }
    const controller = new AbortController();
    setDetailState({ boundId: requestedId, item: null, loading: true, notFound: false, error: null });
    fetchJson<CatalogThemeItem>(`/api/themes/${encodeURIComponent(requestedId)}`, controller.signal)
      .then((detail) => {
        if (
          !controller.signal.aborted &&
          String(detail.familyId || "").toLowerCase() === requestedId.toLowerCase()
        ) {
          setDetailState({
            boundId: requestedId,
            item: detail,
            loading: false,
            notFound: false,
            error: null,
          });
        }
      })
      .catch((err: Error & { status?: number }) => {
        if (!controller.signal.aborted) {
          setDetailState({
            boundId: requestedId,
            item: null,
            loading: false,
            notFound: err.status === 404,
            error: err.status === 404 ? null : err.message || "加载主题详情失败",
          });
        }
      });
    return () => controller.abort();
  }, [id, reloadTick]);

  const item = detailState.boundId === id ? detailState.item : null;
  const loading = Boolean(id) && (detailState.boundId !== id || detailState.loading);
  const notFound = !id || (detailState.boundId === id && detailState.notFound);
  const error = detailState.boundId === id ? detailState.error : null;
  const currentApplyError = applyError?.boundId === id ? applyError.message : null;

  if (loading) {
    return <div className="loading-state" role="status">正在加载主题详情…</div>;
  }
  if (notFound || !item) {
    return (
      <Empty
        title={notFound ? "主题不存在或已下架" : "加载主题详情失败"}
        description={notFound ? "该分享链接对应的主题已被作者撤回或下架。" : error || "请检查网络后重试"}
      >
        {!notFound && (
          <button type="button" className="btn primary" onClick={() => setReloadTick((v) => v + 1)}>
            重试
          </button>
        )}
        <Link className="btn" to="/themes">浏览主题商城</Link>
      </Empty>
    );
  }

  const isApplied =
    runtime.saved?.familyId === item.familyId &&
    runtime.saved?.version === item.version;
  const isApplyingThis = runtime.applyingFamilyId === item.familyId;

  const handleApplyOnWeb = async () => {
    const targetId = item.familyId;
    setApplyError(null);
    try {
      await applyMobileThemeFromCatalog(item);
    } catch (err) {
      setApplyError({
        boundId: targetId,
        message: err instanceof Error ? err.message : "应用主题失败，请重试",
      });
    }
  };

  return (
    <div className="theme-landing-page">
      <Head title={`${item.name} · 主题详情`} description={item.description || "沈理校园主题包"} />
      <div className="panel" style={{ padding: 16 }}>
        <div className="theme-landing-previews">
          <div className="theme-landing-preview-box">
            {item.previewLight && <img src={item.previewLight} alt={`${item.name} 浅色预览`} />}
          </div>
          <div className="theme-landing-preview-box">
            {item.previewDark && <img src={item.previewDark} alt={`${item.name} 深色预览`} />}
          </div>
        </div>

        <h1 style={{ margin: "14px 0 6px", fontSize: 22 }}>{item.name}</h1>
        <p style={{ margin: 0, fontSize: 13, color: "var(--text-2)" }}>
          作者：{item.author?.nickname || "创作者"} · 版本 v{item.version} · 许可 {item.license} · 下载 {item.downloads}
        </p>

        {item.tags?.length > 0 && (
          <div className="theme-landing-tags">
            {item.tags.map((tag) => (
              <span key={tag}>{tag}</span>
            ))}
          </div>
        )}

        {item.description && (
          <p style={{ margin: "12px 0 0", fontSize: 14, lineHeight: 1.6 }}>{item.description}</p>
        )}

        {currentApplyError && (
          <p role="alert" style={{ margin: "10px 0 0", color: "var(--danger)", fontSize: 13 }}>
            {currentApplyError}
          </p>
        )}
        {runtime.storageWarning && (
          <p role="alert" style={{ margin: "10px 0 0", color: "var(--danger)", fontSize: 13 }}>
            {runtime.storageWarning}
          </p>
        )}
        {runtime.resourceError && (
          <div role="status" style={{ marginTop: 10, display: "flex", alignItems: "center", gap: 8, fontSize: 13 }}>
            <span>{runtime.resourceError}</span>
            <button type="button" className="btn" onClick={() => retryMobileThemeResources()}>
              重试资源
            </button>
          </div>
        )}

        <div className="theme-landing-actions">
          <a
            className="btn"
            href={`sylulive://theme/${encodeURIComponent(item.familyId)}`}
          >
            在 App 中打开
          </a>
          <button
            type="button"
            className="btn primary"
            disabled={isApplyingThis}
            onClick={() => void handleApplyOnWeb()}
          >
            {isApplyingThis ? "正在应用…" : isApplied ? "已在网页上应用" : "在网页上应用"}
          </button>
          {isApplied && (
            <button
              type="button"
              className="btn"
              onClick={() => restoreDefaultMobileTheme()}
            >
              恢复默认
            </button>
          )}
        </div>
      </div>
    </div>
  );
}

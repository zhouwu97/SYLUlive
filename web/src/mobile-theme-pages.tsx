import { useEffect, useRef, useState, type FormEvent } from "react";
import { Link, useParams } from "react-router-dom";
import { Empty, Icon } from "./ui";
import { useMobile } from "./mobile";
import {
  applyMobileThemeFromCatalog,
  restoreDefaultMobileTheme,
  retryMobileThemeResources,
  useMobileThemeRuntime,
  type CatalogThemeItem,
} from "./mobile-theme";
import "./theme-gallery.css";

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

function ThemeArtwork({ src, alt }: { src?: string; alt: string }) {
  const [failed, setFailed] = useState<string>();
  return (
    <div className="theme-artwork">
      <Icon name="palette" size={28} />
      {src && src !== failed && (
        <img src={src} alt={alt} loading="lazy" onError={() => setFailed(src)} />
      )}
    </div>
  );
}

function ThemeResourceNotice({
  storageWarning,
  resourceError,
}: {
  storageWarning: string | null;
  resourceError: string | null;
}) {
  return (
    <>
      {storageWarning && <p className="theme-notice theme-notice-error" role="alert">{storageWarning}</p>}
      {resourceError && (
        <div className="theme-notice" role="status">
          <span>{resourceError}</span>
          <button type="button" className="btn" onClick={retryMobileThemeResources}>重试资源</button>
        </div>
      )}
    </>
  );
}

export function MobileThemesPage({ dark }: { dark: boolean }) {
  const runtime = useMobileThemeRuntime();
  const mobile = useMobile();
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

  const clearSearch = () => {
    setSearchInput("");
    setAppliedQuery("");
  };

  return (
    <div className="mobile-themes-page">
      <header className="theme-gallery-heading">
        <h1>主题商城</h1>
        {mobile && (
          <div className="theme-current">
            <span className="theme-current-icon"><Icon name="palette" size={20} /></span>
            <div>
              <span>当前外观</span>
              <strong>{runtime.saved?.name || "沈理青"}</strong>
            </div>
            {runtime.saved && (
              <button type="button" className="btn" disabled={runtime.loading} onClick={restoreDefaultMobileTheme}>恢复默认</button>
            )}
          </div>
        )}
      </header>
      {mobile && (
        <ThemeResourceNotice
          storageWarning={runtime.storageWarning}
          resourceError={runtime.saved ? runtime.resourceError : null}
        />
      )}

      <div className="theme-catalog-toolbar">
        <form onSubmit={onSearchSubmit} className="theme-search" role="search">
          <Icon name="search" size={18} />
          <input
            aria-label="搜索主题"
            placeholder="搜索主题…"
            enterKeyHint="search"
            value={searchInput}
            onChange={(e) => setSearchInput(e.target.value)}
          />
          {appliedQuery && (
            <button type="button" className="theme-search-action" aria-label="清除搜索" onClick={clearSearch}>
              <Icon name="close" size={15} />
            </button>
          )}
          <button type="submit" className="theme-search-action">搜索</button>
        </form>
        <div className="theme-sort" role="tablist" aria-label="主题排序">
          {([
            ["latest", "最新"],
            ["popular", "热门"],
          ] as const).map(([key, label]) => (
            <button
              key={key}
              type="button"
              role="tab"
              aria-selected={sort === key}
              onClick={() => setSort(key)}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      <div className="theme-filters" role="group" aria-label="主题标签">
        <button
          type="button"
          aria-pressed={selectedTag === ""}
          onClick={() => setSelectedTag("")}
        >
          全部
        </button>
        {ALLOWED_TAGS.map((tag) => (
          <button
            key={tag}
            type="button"
            aria-pressed={selectedTag === tag}
            onClick={() => setSelectedTag(selectedTag === tag ? "" : tag)}
          >
            {tag}
          </button>
        ))}
      </div>

      {loading ? (
        <div className="theme-catalog-loading" role="status">
          <span>正在加载主题列表…</span>
          <div className="mobile-theme-grid" aria-hidden="true">
            {[0, 1, 2].map((index) => <div key={index} className="theme-card-placeholder" />)}
          </div>
        </div>
      ) : error ? (
        <Empty title="无法加载主题商城" description={error}>
          <button type="button" className="btn primary" onClick={() => setReloadTick((v) => v + 1)}>
            重试
          </button>
        </Empty>
      ) : items.length === 0 ? (
        <Empty icon="palette" title="暂无符合条件的主题">
          {(appliedQuery || selectedTag) && (
            <button type="button" className="btn" onClick={() => {
              clearSearch();
              setSelectedTag("");
            }}>清除筛选</button>
          )}
        </Empty>
      ) : (
        <>
          <div className="mobile-theme-grid">
            {items.map((item) => {
              const isCurrent =
                mobile && runtime.saved?.familyId === item.familyId &&
                runtime.saved?.version === item.version;
              return (
                <Link
                  key={item.familyId}
                  to={`/theme/${item.familyId}`}
                  className="mobile-theme-card"
                >
                  <div className="mobile-theme-card-cover">
                    <ThemeArtwork
                      src={dark ? item.previewDark || item.previewLight : item.previewLight || item.previewDark}
                      alt=""
                    />
                    {isCurrent ? (
                      <span className="mobile-theme-badge">使用中</span>
                    ) : item.source === "official" ? (
                      <span className="mobile-theme-badge">官方</span>
                    ) : null}
                  </div>
                  <div className="mobile-theme-card-body">
                    <b>{item.name}</b>
                    <small>{item.author?.nickname || "创作者"} · v{item.version}</small>
                    <span className="theme-card-arrow"><Icon name="chevron" size={16} /></span>
                  </div>
                </Link>
              );
            })}
          </div>
          {(nextCursor || loadMoreError) && (
            <div className="theme-catalog-more">
              {loadMoreError && (
                <p role="alert" className="theme-notice-error">
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
  const mobile = useMobile();
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
      <Link className="theme-back-link" to="/themes"><Icon name="arrow" size={16} />主题商城</Link>
      <section className="panel theme-landing-layout">
        <header className="theme-detail-intro">
          <h1>{item.name}</h1>
          <p>{item.author?.nickname || "创作者"} <span>·</span> v{item.version}</p>
        </header>

        <div className="theme-landing-previews">
          <figure className="theme-landing-preview-box">
            <ThemeArtwork src={item.previewLight} alt={`${item.name} 浅色预览`} />
            <figcaption><Icon name="sun" size={15} />浅色</figcaption>
          </figure>
          <figure className="theme-landing-preview-box">
            <ThemeArtwork src={item.previewDark} alt={`${item.name} 深色预览`} />
            <figcaption><Icon name="moon" size={15} />深色</figcaption>
          </figure>
        </div>

        <div className="theme-detail-info">
          {item.tags?.length > 0 && (
            <div className="theme-landing-tags">
              {item.tags.map((tag) => <span key={tag}>{tag}</span>)}
            </div>
          )}
          {item.description && <p className="theme-detail-description">{item.description}</p>}
          <dl className="theme-detail-facts">
            <div><dt>下载次数</dt><dd>{item.downloads}</dd></div>
            <div><dt>许可</dt><dd>{item.license}</dd></div>
          </dl>
        </div>

        <div className="theme-landing-actions">
          {currentApplyError && (
            <p role="alert" className="theme-notice theme-notice-error">{currentApplyError}</p>
          )}
          {mobile && (
            <ThemeResourceNotice
              storageWarning={runtime.storageWarning}
              resourceError={runtime.saved && runtime.resourceError !== currentApplyError ? runtime.resourceError : null}
            />
          )}
          <div className="theme-detail-buttons">
            {mobile && (
              <button
                type="button"
                className="btn primary"
                disabled={isApplyingThis || isApplied}
                onClick={() => void handleApplyOnWeb()}
              >
                {isApplied && <Icon name="check" size={16} />}
                {isApplyingThis ? "正在应用…" : isApplied ? "已在网页上应用" : "在网页上应用"}
              </button>
            )}
            <a
              className={`btn${mobile ? "" : " primary"}`}
              href={`sylulive://theme/${encodeURIComponent(item.familyId)}`}
            >
              在 App 中打开
            </a>
            {mobile && isApplied && (
              <button type="button" className="btn" disabled={runtime.loading} onClick={restoreDefaultMobileTheme}>
                恢复默认
              </button>
            )}
          </div>
          {!mobile && <p className="theme-device-hint">用手机浏览器打开此页，即可应用到移动网页。</p>}
        </div>
      </section>
    </div>
  );
}

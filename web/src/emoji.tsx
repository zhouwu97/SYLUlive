import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { captureAuthSession, errorText, rows, useApi, write, type Entity } from "./api";
import { useAuth } from "./auth";
import { uploadImageFiles } from "./media";
import { Icon } from "./ui";
import { emojiBytes, favoriteCreateFields, favoriteSelection, packAssetUrl, stickerUrl, type StickerPayload } from "./emoji-selection";
import "./emoji.css";

export type { StickerPayload } from "./emoji-selection";
type Pack = { id: string; name: string; asset_count?: number; total_size?: number; version?: number };
type ManifestAsset = { id: string; name?: string; animated?: boolean; is_animated?: boolean };
type Manifest = { assets?: ManifestAsset[] };
type View = "picker" | "manage" | "pack" | "preview";

function EmojiImage({ src, label, className = "", retry = false }: { src: string; label: string; className?: string; retry?: boolean }) {
  const [failed, setFailed] = useState(false), [attempt, setAttempt] = useState(0);
  useEffect(() => { setFailed(false); setAttempt(0); }, [src]);
  if (failed) return <span className="emoji-image-error"><Icon name="file" /><span>图片暂不可用</span>{retry && <button type="button" className="link-btn" onClick={() => { setFailed(false); setAttempt((n) => n + 1); }}>重试图片</button>}</span>;
  return <img key={attempt} className={className} src={src} alt={label} loading="lazy" decoding="async" onError={() => setFailed(true)} />;
}

export function StickerRenderer({ stickerId, assetKey, packId, label = "表情" }: { stickerId?: string; assetKey?: string; packId?: string; label?: string }) {
  const id = stickerId || assetKey?.split(":").pop();
  return id ? <EmojiImage src={stickerUrl(id, assetKey, packId)} label={label} className="sticker-render" retry /> : null;
}

export function EmojiSelectionPreview({ selection }: { selection: StickerPayload }) {
  const auth = useAuth();
  const src = selection.kind === "image" ? `${selection.url}?account=${auth.user?.id || 0}` : selection.url;
  return <EmojiImage src={src} label={selection.label || "已选表情"} className="sticker-render" retry />;
}

function PackCover({ pack }: { pack: Pack }) {
  const manifest = useApi<Manifest>(`/api/emoji/packs/${encodeURIComponent(pack.id)}/manifest${pack.version ? `?version=${pack.version}` : ""}`);
  const first = manifest.data?.assets?.[0];
  return <span className="emoji-pack-cover">{first ? <EmojiImage src={packAssetUrl(pack.id, first.id, pack.version)} label={`${pack.name}封面`} /> : <Icon name="file" />}</span>;
}

export function StickerPicker(props: { onSelect: (payload: StickerPayload) => void; compact?: boolean; disabled?: boolean }) {
  const auth = useAuth();
  // 切号会销毁旧账号的局部选择、预览和撤销状态。
  return <StickerPickerContent key={auth.user?.id ?? "guest"} {...props} />;
}

function StickerPickerContent({ onSelect, compact = false, disabled = false }: { onSelect: (payload: StickerPayload) => void; compact?: boolean; disabled?: boolean }) {
  const auth = useAuth(), qc = useQueryClient();
  const packs = useApi<Pack[]>("/api/emoji/packs");
  const favorites = useApi(auth.user ? "/api/emoji/favorites" : null);
  const available = rows(packs.data, "packs") as Pack[];
  const [active, setActive] = useState("favorites"), [keyword, setKeyword] = useState("");
  const [view, setView] = useState<View>("picker"), [section, setSection] = useState("favorites");
  const [selecting, setSelecting] = useState(false), [selected, setSelected] = useState<Set<number>>(new Set());
  const [removed, setRemoved] = useState<Set<number>>(new Set()), [undoItems, setUndoItems] = useState<Entity[]>([]);
  const [busy, setBusy] = useState(false), [notice, setNotice] = useState("");
  const [preview, setPreview] = useState<StickerPayload | null>(null);
  const previousView = useRef<View>("manage"), focusStack = useRef<string[]>([]), pendingFocus = useRef<string | null>(null);
  const bodyRef = useRef<HTMLDivElement>(null), inputRef = useRef<HTMLInputElement>(null), alive = useRef(true), lock = useRef(false);
  useEffect(() => { alive.current = true; return () => { alive.current = false; }; }, []);
  useLayoutEffect(() => {
    if (pendingFocus.current !== null) {
      const target = Array.from(bodyRef.current?.querySelectorAll<HTMLButtonElement>("button") || []).find((button) => button.dataset.emojiFocus === pendingFocus.current);
      pendingFocus.current = null;
      (target || bodyRef.current?.querySelector<HTMLElement>("button"))?.focus();
    } else if (view !== "picker") bodyRef.current?.querySelector<HTMLElement>("button")?.focus();
  }, [view]);
  const currentPack = available.find((pack) => pack.id === active);
  const manifest = useApi<Manifest>(active === "favorites" ? null : `/api/emoji/packs/${encodeURIComponent(active)}/manifest${currentPack?.version ? `?version=${currentPack.version}` : ""}`);
  const assets = useMemo(() => (manifest.data?.assets || []).filter((item) => !keyword || `${item.name || ""}${item.id}`.toLowerCase().includes(keyword.toLowerCase())), [manifest.data, keyword]);
  const allFavorites = rows(favorites.data, "items").filter((item) => !removed.has(Number(item.favorite_id || item.id)));
  const favoriteItems = allFavorites.filter((item) => !keyword || `${item.name || "收藏图片"}${item.sticker_id || ""}`.toLowerCase().includes(keyword.toLowerCase()));
  const inactive = disabled || busy;
  function choose(selection: StickerPayload) { if (!inactive) onSelect(selection); }
  function back() {
    pendingFocus.current = focusStack.current.pop() ?? "";
    setView(view === "preview" ? previousView.current : view === "pack" ? "manage" : "picker"); setPreview(null);
  }
  function navigate(next: View, source: HTMLElement) {
    pendingFocus.current = null;
    focusStack.current.push(source.dataset.emojiFocus || ""); setView(next);
  }
  function showPreview(selection: StickerPayload, source: HTMLElement) {
    previousView.current = view; setPreview(selection); navigate("preview", source);
  }
  function toggle(id: number) { setSelected((old) => { const next = new Set(old); next.has(id) ? next.delete(id) : next.add(id); return next; }); }
  function checkpoint() { const session = captureAuthSession(); return () => alive.current && session(); }
  async function refreshFavorites() { await qc.invalidateQueries({ queryKey: ["api", "/api/emoji/favorites"] }); }
  async function removeSelected() {
    if (inactive || lock.current || !selected.size) return;
    lock.current = true; setBusy(true); setNotice("");
    const isCurrent = checkpoint(), done: Entity[] = [], failed: number[] = [];
    try {
      for (const item of allFavorites.filter((item) => selected.has(Number(item.favorite_id || item.id)))) {
        if (!isCurrent()) return;
        const id = Number(item.favorite_id || item.id);
        try { await deleteFavorite(id); if (!isCurrent()) return; done.push(item); }
        catch { if (!isCurrent()) return; failed.push(id); }
      }
      if (!isCurrent()) return;
      setRemoved((old) => new Set([...old, ...done.map((item) => Number(item.favorite_id || item.id))]));
      setUndoItems(done); setSelected(new Set(failed));
      setNotice(failed.length ? `已移除 ${done.length} 个，${failed.length} 个未完成，可重试` : `已从收藏移除 ${done.length} 个`);
      await refreshFavorites();
    } finally { lock.current = false; if (isCurrent()) setBusy(false); }
  }
  async function undoRemoval() {
    if (inactive || lock.current || !undoItems.length) return;
    lock.current = true; setBusy(true);
    const isCurrent = checkpoint(), failed: Entity[] = []; let restored = 0;
    try {
      for (const item of undoItems) {
        if (!isCurrent()) return;
        const selection = favoriteSelection(item);
        try {
          if (!selection) throw new Error("收藏来源不可用");
          await write("/api/emoji/favorites", favoriteCreateFields(selection));
          if (!isCurrent()) return; restored++;
        } catch { if (!isCurrent()) return; failed.push(item); }
      }
      if (!isCurrent()) return;
      setUndoItems(failed); setNotice(failed.length ? `已恢复 ${restored} 个；其余来源不可用或配额不足，可重试` : `已恢复 ${restored} 个收藏`);
      await refreshFavorites();
    } finally { lock.current = false; if (isCurrent()) setBusy(false); }
  }
  async function addImage(file?: File) {
    if (!file || inactive || lock.current || !auth.user) return;
    const isCurrent = checkpoint(); lock.current = true; setBusy(true); setNotice("正在添加图片…");
    try {
      const [id] = await uploadImageFiles([file]); if (!isCurrent()) return;
      await write("/api/emoji/favorites", { kind: "custom", file_id: id }); if (!isCurrent()) return;
      setNotice("图片已添加到收藏"); await refreshFavorites();
    } catch (error) { if (isCurrent()) setNotice(errorText(error)); }
    finally { lock.current = false; if (isCurrent()) setBusy(false); }
  }
  function tabs(items: [string, string][], value: string, change: (value: string) => void) {
    return <div className="emoji-tabs" role="tablist" aria-label={view === "manage" ? "管理栏目" : "表情分类"}>
      {items.map(([id, title]) => <button type="button" role="tab" key={id} aria-selected={id === value} tabIndex={id === value ? 0 : -1} disabled={inactive} onClick={() => change(id)} onKeyDown={(event) => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
        event.preventDefault(); const i = items.findIndex(([key]) => key === id);
        const next = event.key === "Home" ? 0 : event.key === "End" ? items.length - 1 : (i + (event.key === "ArrowLeft" ? -1 : 1) + items.length) % items.length;
        change(items[next][0]); (event.currentTarget.parentElement?.children[next] as HTMLElement)?.focus();
      }}>{title}</button>)}
    </div>;
  }
  function queryState(query: { isPending: boolean; error: Error | null; refetch: () => unknown }, empty: boolean, content: ReactNode, emptyTitle: string) {
    if (query.isPending && !query.error) return <div className="emoji-state" role="status">正在加载表情…</div>;
    if (query.error && empty) return <div className="emoji-state" role="alert"><Icon name="file" /><b>加载未完成</b><span>{query.error.message}</span><button type="button" className="btn" onClick={() => query.refetch()}>重试</button></div>;
    if (empty) return <div className="emoji-state"><Icon name="heart" /><b>{keyword ? "没有找到匹配的表情" : emptyTitle}</b><span>{keyword ? "试试其他名称" : "收藏常用图片，下次可以直接选择"}</span></div>;
    return content;
  }
  const favoriteGrid = <div className="sticker-picker-grid emoji-grid">{favoriteItems.map((item) => {
    const selection = favoriteSelection(item), id = Number(item.favorite_id || item.id);
    const src = selection?.kind === "image" ? `/api/emoji/favorites/${id}/thumbnail?account=${auth.user?.id || 0}` : selection?.url;
    return <button type="button" key={id} data-emoji-focus={`favorite-${id}`} className={`sticker-option emoji-option ${selected.has(id) ? "selected" : ""}`} disabled={inactive || (!selection && !(selecting && view === "manage"))} aria-label={`${selecting && view === "manage" ? "选择" : ""}${selection?.label || "收藏来源不可用"} ${id}`} aria-pressed={selecting && view === "manage" ? selected.has(id) : undefined} onClick={(event) => {
      if (selecting && view === "manage") toggle(id);
      else if (selection && view === "manage") showPreview(selection, event.currentTarget);
      else if (selection) choose(selection);
    }}>{src ? <EmojiImage src={src} label={selection?.label || "收藏表情"} /> : <span className="emoji-image-error">来源不可用</span>}{selection?.animated && <small className="emoji-animation">动图</small>}{selecting && view === "manage" && <span className="emoji-check" aria-hidden="true">{selected.has(id) ? "✓" : "○"}</span>}</button>;
  })}</div>;
  const assetGrid = <div className="sticker-picker-grid emoji-grid">{assets.map((item) => {
    const selection: StickerPayload = { kind: "sticker", sticker_id: item.id, asset_key: `official:${active}:${item.id}`, pack_id: active, version: currentPack?.version, label: item.name, animated: item.animated || item.is_animated, url: packAssetUrl(active, item.id, currentPack?.version) };
    return <button type="button" key={item.id} data-emoji-focus={`asset-${active}-${item.id}`} className="sticker-option emoji-option" title={item.name || "表情"} disabled={inactive} onClick={(event) => view === "pack" ? showPreview(selection, event.currentTarget) : choose(selection)}><EmojiImage src={selection.url} label={item.name || "表情"} />{selection.animated && <small className="emoji-animation">动图</small>}<span className="emoji-option-name">{item.name || "表情"}</span></button>;
  })}</div>;
  return <div ref={bodyRef} className={`sticker-picker emoji-picker ${compact ? "compact" : ""}`}>
    <div className="sticker-picker-head emoji-head"><b>{view === "preview" ? "表情预览" : view === "manage" ? "表情管理" : view === "pack" ? currentPack?.name || "表情包" : "选择表情"}</b>{view === "picker" ? <button type="button" data-emoji-focus="manage" className="link-btn" disabled={inactive} onClick={(event) => navigate("manage", event.currentTarget)}>管理</button> : <button type="button" className="link-btn" disabled={busy} onClick={back}>返回{view === "manage" ? "选择" : ""}</button>}</div>
    {view !== "preview" && <input className="emoji-search" aria-label="搜索表情" placeholder="搜索表情名称" value={keyword} disabled={inactive} onChange={(event) => setKeyword(event.target.value)} />}
    {packs.error && <div className="emoji-inline-error" role="alert"><span>官方表情包加载未完成，收藏仍可使用</span><button type="button" className="link-btn" onClick={() => packs.refetch()}>重试官方表情包</button></div>}
    {view === "picker" && tabs([["favorites", "我的收藏"], ...available.map((pack) => [pack.id, pack.name] as [string, string])], active, setActive)}
    {view === "manage" && tabs([["favorites", "我的收藏"], ["catalog", "官方表情包"]], section, setSection)}
    {view === "preview" && preview ? <div className="emoji-preview"><div className="emoji-preview-stage"><EmojiSelectionPreview selection={preview} /></div><b>{preview.label || "表情"}</b>{preview.animated && <span>动图</span>}<button type="button" className="btn primary" disabled={inactive} onClick={() => { choose(preview); back(); }}>选择这个表情</button></div> : view === "manage" && section === "catalog" ? queryState(packs, !available.length, <div className="emoji-pack-list">{available.filter((pack) => !keyword || pack.name.toLowerCase().includes(keyword.toLowerCase())).map((pack) => <div className="emoji-pack-row" key={pack.id}><PackCover pack={pack} /><div className="emoji-pack-copy"><b>{pack.name}</b><span>{pack.asset_count ?? "—"} 个{pack.total_size ? ` · ${emojiBytes(pack.total_size)}` : ""}</span><small>官方表情包 · 可直接选择</small></div><button type="button" data-emoji-focus={`pack-${pack.id}`} className="btn" disabled={inactive} onClick={(event) => { setActive(pack.id); setKeyword(""); navigate("pack", event.currentTarget); }}>预览</button></div>)}</div>, "暂无官方表情包") : (view === "manage" || active === "favorites") && view !== "pack" ? <>
      <div className="emoji-group-heading"><span>我的收藏 · {allFavorites.length} 个</span>{view === "manage" && !!allFavorites.length && <button type="button" className="link-btn" disabled={inactive} onClick={() => { setSelecting(!selecting); setSelected(new Set()); }}>{selecting ? "完成选择" : "批量整理"}</button>}</div>
      {!auth.user ? <div className="emoji-state"><b>登录后查看收藏</b><button type="button" className="btn" onClick={auth.login}>登录</button></div> : queryState(favorites, !favoriteItems.length, favoriteGrid, "还没有收藏表情")}
    </> : <><div className="emoji-group-heading"><span>{currentPack?.name || "表情包"} · {assets.length} 个</span><small>点击{view === "pack" ? "预览" : "选择"}</small></div>{queryState(manifest, !assets.length, assetGrid, "表情包暂无内容")}</>}
    {favorites.error && allFavorites.length > 0 && <div className="emoji-inline-error" role="alert"><span>收藏同步未完成，已保留原有内容</span><button type="button" className="link-btn" onClick={() => favorites.refetch()}>重试收藏</button></div>}
    {notice && <div className="emoji-notice" role="status"><span>{notice}</span>{undoItems.length > 0 && <button type="button" className="link-btn" disabled={inactive} onClick={undoRemoval}>撤销移除</button>}</div>}
    <div className="sticker-picker-foot emoji-foot"><span>{typeof favorites.data?.quota_used === "number" ? `收藏占用 ${emojiBytes(favorites.data.quota_used)}${typeof favorites.data?.quota_limit === "number" ? ` / ${emojiBytes(favorites.data.quota_limit)}` : ""}` : "官方表情包可直接选择"}</span>{view === "manage" && section === "favorites" && auth.user && <>{selecting ? <button type="button" className="btn" disabled={inactive || !selected.size} onClick={removeSelected}>{busy ? "正在整理…" : `移除所选${selected.size ? `（${selected.size}）` : ""}`}</button> : <button type="button" className="btn" disabled={inactive} onClick={() => inputRef.current?.click()}>添加图片</button>}<input ref={inputRef} type="file" accept="image/jpeg,image/png,image/gif" aria-label="添加收藏图片" hidden onChange={(event) => { const file = event.target.files?.[0]; event.target.value = ""; void addImage(file); }} /></>}</div>
  </div>;
}

export async function favoritePublicImage(path: string) {
  return write("/api/emoji/favorites/from-public-image", { image_url: path });
}
export async function deleteFavorite(id: number) {
  return write(`/api/emoji/favorites/${id}`, {}, "DELETE");
}

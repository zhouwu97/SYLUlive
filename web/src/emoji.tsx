import { useMemo, useState } from "react";
import { asset, rows, useApi, write, type Entity } from "./api";
import { Icon, QueryState, Tabs, useUI } from "./ui";

export type StickerPayload = {
  sticker_id: string;
  asset_key: string;
  pack_id: string;
  label?: string;
  url?: string;
};

type Pack = { id: string; name: string; asset_count?: number; version?: number };
type ManifestAsset = { id: string; name?: string; path?: string; mime_type?: string; animated?: boolean; width?: number; height?: number };

function packAssetUrl(packId: string, assetId: string) {
  return `/api/emoji/packs/${encodeURIComponent(packId)}/assets/${encodeURIComponent(assetId)}`;
}

function favoriteUrl(item: Entity) {
  return asset(item.thumbnail_url || item.url) || (item.favorite_id ? `/api/emoji/favorites/${item.favorite_id}/thumbnail` : undefined);
}

export function StickerRenderer({ stickerId, assetKey, packId, label = "表情" }: { stickerId?: string; assetKey?: string; packId?: string; label?: string }) {
  const pack = packId || (assetKey?.startsWith("official:") ? assetKey.split(":")[1] : "mingfeng-daily");
  const id = stickerId || assetKey?.split(":").pop();
  if (!id) return null;
  const src = pack ? packAssetUrl(pack, id) : `/stickers/${encodeURIComponent(id)}`;
  return <img className="sticker-render" src={src} alt={label} loading="lazy" decoding="async" />;
}

export function StickerPicker({ onSelect, compact = false }: { onSelect: (payload: StickerPayload) => void; compact?: boolean }) {
  const ui = useUI();
  const packs = useApi<Pack[]>("/api/emoji/packs");
  const favorites = useApi("/api/emoji/favorites");
  const available = rows(packs.data, "packs") as Pack[];
  const [active, setActive] = useState("favorites");
  const [keyword, setKeyword] = useState("");
  const manifest = useApi<{ assets?: ManifestAsset[] }>(active === "favorites" ? null : `/api/emoji/packs/${encodeURIComponent(active)}/manifest`);
  const assets = useMemo(() => (manifest.data?.assets || []).filter((item) => !keyword || `${item.name || ""}${item.id}`.toLowerCase().includes(keyword.toLowerCase())), [manifest.data, keyword]);
  const favoriteItems = useMemo(() => rows(favorites.data, "items").filter((item) => !keyword || `${item.name || ""}${item.sticker_id || ""}`.toLowerCase().includes(keyword.toLowerCase())), [favorites.data, keyword]);
  function choose(payload: StickerPayload) {
    onSelect(payload);
  }
  return <div className={`sticker-picker ${compact ? "compact" : ""}`}>
    <div className="sticker-picker-head">
      <b>选择表情</b>
      <input aria-label="搜索表情" placeholder="搜索" value={keyword} onChange={(event) => setKeyword(event.target.value)} />
    </div>
    <Tabs value={active} onChange={setActive} tabs={[["favorites", "我的收藏"], ...available.map((pack) => [pack.id, pack.name] as [string, string])]} />
    {active === "favorites" ? <QueryState query={favorites} empty={!favoriteItems.length}>
      <div className="sticker-picker-grid">
        {favoriteItems.map((item) => {
          const src = favoriteUrl(item);
          return <button type="button" key={item.favorite_id || item.id} className="sticker-option" title={item.name || "收藏表情"} onClick={() => choose({ sticker_id: String(item.sticker_id || item.asset_id || item.id), asset_key: String(item.asset_key || "private:" + (item.asset_id || item.id)), pack_id: String(item.pack_id || ""), label: item.name, url: src })}>
            {src ? <img src={src} alt={item.name || "收藏表情"} loading="lazy" /> : <Icon name="heart" />}
          </button>;
        })}
      </div>
    </QueryState> : <QueryState query={manifest} empty={!assets.length}>
      <div className="sticker-picker-grid">
        {assets.map((item) => <button type="button" key={item.id} className="sticker-option" title={item.name || item.id} onClick={() => choose({ sticker_id: item.id, asset_key: `official:${active}:${item.id}`, pack_id: active, label: item.name })}>
          <img src={packAssetUrl(active, item.id)} alt={item.name || "表情"} loading="lazy" decoding="async" />
          {item.animated && <small>动图</small>}
        </button>)}
      </div>
    </QueryState>}
    <div className="sticker-picker-foot"><span>{Number(favorites.data?.quota_used || 0) ? `已使用 ${Math.round(Number(favorites.data?.quota_used || 0) / 1024)} KB` : "官方表情包即时加载"}</span><button type="button" className="link-btn" onClick={() => ui.notify("表情包来自服务端官方资源")}>资源说明</button></div>
  </div>;
}

export async function favoritePublicImage(path: string) {
  return write("/api/emoji/favorites/from-public-image", { image_url: path });
}

export async function deleteFavorite(id: number) {
  return write(`/api/emoji/favorites/${id}`, {}, "DELETE");
}

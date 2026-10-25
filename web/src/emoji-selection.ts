export type StickerSelection = {
  kind: "sticker";
  sticker_id: string;
  asset_key?: string;
  pack_id?: string;
  version?: number;
  label?: string;
  animated?: boolean;
  url: string;
};

export type FavoriteImageSelection = {
  kind: "image";
  favorite_id: number;
  file_id: number;
  asset_key?: string;
  label?: string;
  animated?: boolean;
  mime_type?: string;
  url: string;
};

export type StickerPayload = StickerSelection | FavoriteImageSelection;

function positiveId(value: unknown): number | undefined {
  const id = Number(value);
  return Number.isSafeInteger(id) && id > 0 ? id : undefined;
}

export function packAssetUrl(packId: string, assetId: string, version?: number) {
  const path = `/api/emoji/packs/${encodeURIComponent(packId)}/assets/${encodeURIComponent(assetId)}`;
  return version ? `${path}?version=${version}` : path;
}

export function stickerUrl(stickerId: string, assetKey?: string, packId?: string) {
  const pack = packId || (assetKey?.startsWith("official:") ? assetKey.split(":")[1] : undefined);
  return pack ? packAssetUrl(pack, stickerId) : `/stickers/${encodeURIComponent(stickerId)}`;
}

export function favoriteSelection(item: Record<string, unknown>): StickerPayload | null {
  const label = typeof item.name === "string" && item.name ? item.name : "收藏表情";
  // 旧收藏只有贴图 hash，也能通过既有 /stickers 端点读取；不能猜所属包。
  if (typeof item.sticker_id === "string" && /^[a-f0-9]{32}$/i.test(item.sticker_id) && item.kind !== "custom") {
    const pack = typeof item.pack_id === "string" && item.pack_id ? item.pack_id : undefined;
    const key = typeof item.asset_key === "string" && /^(builtin|official):/.test(item.asset_key) ? item.asset_key : undefined;
    return { kind: "sticker", sticker_id: item.sticker_id, ...(key ? { asset_key: key } : {}), ...(pack ? { pack_id: pack } : {}), label, url: stickerUrl(item.sticker_id, key, pack) };
  }
  const favoriteId = positiveId(item.favorite_id || item.id), fileId = positiveId(item.file_id);
  if (!favoriteId || !fileId) return null;
  const assetId = positiveId(item.asset_id);
  return {
    kind: "image", favorite_id: favoriteId, file_id: fileId,
    ...(assetId ? { asset_key: `private:${assetId}` } : {}),
    label: label === "收藏表情" ? "收藏图片" : label,
    animated: item.is_animated === true,
    mime_type: typeof item.mime_type === "string" ? item.mime_type : undefined,
    url: `/api/emoji/favorites/${favoriteId}/file`,
  };
}

export function messageEmojiFields(selection: StickerPayload) {
  if (selection.kind === "image") return { file_id: selection.file_id };
  return { sticker_id: selection.sticker_id,
    ...(selection.asset_key ? { asset_key: selection.asset_key } : {}),
    ...(selection.pack_id ? { pack_id: selection.pack_id } : {}),
  };
}

export function favoriteCreateFields(selection: StickerPayload) {
  return selection.kind === "image"
    ? { kind: "custom", file_id: selection.file_id }
    : { kind: "builtin", sticker_id: selection.sticker_id };
}

export function emojiBytes(bytes: number) {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${Math.max(0, bytes)} B`;
}

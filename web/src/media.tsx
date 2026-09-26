import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
} from "react";
import { asset, errorText, write, type Entity } from "./api";
import { useUI } from "./ui";
import { rejectAttachmentFiles, ticketAttachmentLimits } from "./attachments";
import "./media.css";

export type MediaItem = {
  id?: number;
  file_id?: number;
  thumb_url?: string;
  medium_url?: string;
  viewer_url?: string;
  origin_url?: string;
  url?: string;
  width?: number;
  height?: number;
  mime_type?: string;
  variant_status?: Record<string, string>;
  file?: Entity;
  [key: string]: unknown;
};

export type MediaUploadItem = {
  file: File;
  preview: string;
  status: "ready" | "uploading" | "uploaded" | "failed";
  error?: string;
  fileId?: number;
};

export const mediaLimits = {
  ...ticketAttachmentLimits,
  maxCount: 9,
};

export function mediaURL(item: MediaItem | Entity | undefined, variant: "thumb" | "medium" | "viewer" | "origin" = "origin") {
  if (!item) return undefined;
  const value = item[`${variant}_url`] || (variant === "origin" ? item.url : undefined) || item.file?.path || item.path || item.url;
  return asset(value);
}

export function normalizeMedia(value: unknown): MediaItem {
  const item = (value && typeof value === "object" ? value : {}) as MediaItem;
  return item;
}

export async function uploadImageFiles(files: File[]): Promise<number[]> {
  const valid = files.filter((file) => file.size > 0);
  const rejected = rejectAttachmentFiles(valid, mediaLimits);
  if (rejected.length) {
    throw new Error(`图片未通过检查：${rejected.map((x) => `${x.file}（${x.reason}）`).join("；")}`);
  }
  if (!valid.length) return [];

  const body = new FormData();
  valid.forEach((file) => body.append("files", file));
  try {
    const response = await write<{ results?: Entity[] }>("/api/upload_multiple", body);
    const results = Array.isArray(response.results) ? response.results : [];
    const failed = results.filter((item) => item.error);
    const ids = results.map((item) => Number(item.file_id)).filter((id) => Number.isInteger(id) && id > 0);
    if (failed.length || ids.length !== valid.length) {
      throw new Error(failed.map((item) => String(item.error)).join("；") || "部分图片上传失败，请重试");
    }
    return ids;
  } catch (error) {
    // 旧服务实例没有批量端点时退回单文件上传，保持帖子发布可用。
    if (error instanceof Error && error.message.includes("部分图片上传失败")) throw error;
    const ids: number[] = [];
    for (const file of valid) {
      const result = await write<{ file_id?: number }>("/api/upload", (() => {
        const one = new FormData();
        one.append("file", file);
        return one;
      })());
      const id = Number(result.file_id);
      if (!Number.isInteger(id) || id <= 0) throw new Error("上传没有返回有效的图片编号");
      ids.push(id);
    }
    return ids;
  }
}

function MediaLightbox({ items, initial, close, title }: { items: MediaItem[]; initial: number; close: () => void; title: string }) {
  const [index, setIndex] = useState(initial);
  const item = items[index] || items[0];
  const src = mediaURL(item, "viewer") || mediaURL(item, "origin");
  const previous = useCallback(() => setIndex((value) => (value - 1 + items.length) % items.length), [items.length]);
  const next = useCallback(() => setIndex((value) => (value + 1) % items.length), [items.length]);

  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if (event.key === "ArrowLeft") previous();
      if (event.key === "ArrowRight") next();
      if (event.key === "Escape") close();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [close, next, previous]);

  return (
    <div className="media-lightbox" aria-label={`${title}，第 ${index + 1} 张，共 ${items.length} 张`}>
      <div className="media-lightbox-toolbar">
        <span>{index + 1} / {items.length}</span>
        {src && <a className="link-btn" href={src} target="_blank" rel="noreferrer">打开原图</a>}
      </div>
      <div className="media-lightbox-stage">
        <button type="button" className="media-lightbox-nav prev" onClick={previous} aria-label="上一张">‹</button>
        {src ? <img src={src} alt={`${title}第 ${index + 1} 张`} /> : <span className="media-state">图片暂不可用</span>}
        <button type="button" className="media-lightbox-nav next" onClick={next} aria-label="下一张">›</button>
      </div>
      {items.length > 1 && (
        <div className="media-lightbox-thumbs" role="tablist" aria-label="图片缩略图">
          {items.map((candidate, candidateIndex) => {
            const thumb = mediaURL(candidate, "thumb") || mediaURL(candidate, "origin");
            return <button type="button" key={candidate.id || candidateIndex} className={candidateIndex === index ? "active" : ""} onClick={() => setIndex(candidateIndex)} role="tab" aria-selected={candidateIndex === index}>
              {thumb && <img src={thumb} alt={`${title}第 ${candidateIndex + 1} 张缩略图`} />}
            </button>;
          })}
        </div>
      )}
    </div>
  );
}

export function MediaGallery({ items, title = "图片", className = "", maxVisible = 3 }: { items?: unknown[]; title?: string; className?: string; maxVisible?: number }) {
  const ui = useUI();
  const media = useMemo(() => (items || []).map(normalizeMedia).filter((item) => mediaURL(item, "origin")), [items]);
  const [failed, setFailed] = useState<Record<number, boolean>>({});
  const [retry, setRetry] = useState<Record<number, number>>({});
  if (!media.length) return null;
  const visible = media.slice(0, maxVisible);
  const open = (index: number) => ui.open("图片预览", <MediaLightbox items={media} initial={index} close={ui.close} title={title} />);
  return <div className={`media-gallery media-gallery-${Math.min(visible.length, 3)} ${className}`}>
    {visible.map((item, index) => {
      const src = mediaURL(item, "thumb") || mediaURL(item, "origin");
      const extra = media.length - visible.length;
      return <button type="button" className="media-tile" key={item.id || item.file_id || index} onClick={() => failed[index] ? (setFailed((state) => ({ ...state, [index]: false })), setRetry((state) => ({ ...state, [index]: (state[index] || 0) + 1 }))) : open(index)} aria-label={`${title}第 ${index + 1} 张`}>
        {src && !failed[index] ? <img key={retry[index] || 0} src={src} alt={`${title}第 ${index + 1} 张`} loading="lazy" decoding="async" width={item.width || undefined} height={item.height || undefined} onError={() => setFailed((state) => ({ ...state, [index]: true }))} /> : <span className="media-state">图片加载失败 · 点击重试</span>}
        {extra > 0 && index === visible.length - 1 && <span className="media-more">+{extra}</span>}
      </button>;
    })}
  </div>;
}

export function MediaUploadPicker({ name = "images", onFilesChange, maxCount = mediaLimits.maxCount }: { name?: string; onFilesChange?: (files: File[]) => void; maxCount?: number }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const itemsRef = useRef<MediaUploadItem[]>([]);
  const [items, setItems] = useState<MediaUploadItem[]>([]);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [pickerError, setPickerError] = useState("");

  const syncFiles = useCallback((next: MediaUploadItem[]) => {
    setItems(next);
    itemsRef.current = next;
    onFilesChange?.(next.map((item) => item.file));
    if (inputRef.current) {
      const transfer = new DataTransfer();
      next.forEach((item) => transfer.items.add(item.file));
      inputRef.current.files = transfer.files;
    }
  }, [onFilesChange]);

  const addFiles = (files: File[]) => {
    setPickerError("");
    const nextFiles = files.slice(0, Math.max(0, maxCount - items.length));
    const rejected = rejectAttachmentFiles(nextFiles, { ...mediaLimits, maxCount });
    if (rejected.length) {
      setPickerError(rejected.map((x) => `${x.file}（${x.reason}）`).join("；"));
      return;
    }
    if (files.length > nextFiles.length) setPickerError(`最多选择 ${maxCount} 张图片`);
    const next = [...items, ...nextFiles.map((file) => ({ file, preview: URL.createObjectURL(file), status: "ready" as const }))];
    syncFiles(next);
  };
  const onChange = (event: ChangeEvent<HTMLInputElement>) => addFiles(Array.from(event.target.files || []));
  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault();
    addFiles(Array.from(event.dataTransfer.files || []));
  };
  const remove = (index: number) => {
    const item = items[index];
    if (item) URL.revokeObjectURL(item.preview);
    syncFiles(items.filter((_, candidateIndex) => candidateIndex !== index));
  };
  const move = (from: number, to: number) => {
    if (to < 0 || to >= items.length || from === to) return;
    const next = [...items];
    const [item] = next.splice(from, 1);
    next.splice(to, 0, item);
    syncFiles(next);
  };
  useEffect(() => () => itemsRef.current.forEach((item) => URL.revokeObjectURL(item.preview)), []);

  return <div className="media-upload-picker">
    <div className="media-upload-drop" onDragOver={(event) => event.preventDefault()} onDrop={onDrop}>
      <input className="media-upload-input" ref={inputRef} name={name} type="file" accept="image/jpeg,image/png,image/gif" multiple onChange={onChange} aria-label="选择图片" />
      <span className="media-upload-icon" aria-hidden="true">＋</span>
      <b>拖入图片，或点击选择</b><span>支持 JPG、PNG、GIF · 最多 {maxCount} 张 · 单张不超过 10MB</span>
    </div>
    {pickerError && <p className="media-upload-error" role="alert">{pickerError}</p>}
    {items.length > 0 && <div className="media-upload-grid" aria-live="polite">
      {items.map((item, index) => <div className="media-upload-item" key={`${item.file.name}-${item.file.lastModified}-${index}`} draggable onDragStart={() => setDragIndex(index)} onDragOver={(event) => event.preventDefault()} onDrop={() => { if (dragIndex !== null) move(dragIndex, index); setDragIndex(null); }}>
        <img src={item.preview} alt={`${item.file.name}预览`} />
        <div className="media-upload-meta"><span>{index + 1}</span><button type="button" aria-label={`移除${item.file.name}`} onClick={() => remove(index)}>×</button></div>
        <small>{item.file.name}</small>
      </div>)}
    </div>}
  </div>;
}

export function imageUploadError(error: unknown) {
  return errorText(error) || "图片上传失败，请重试";
}

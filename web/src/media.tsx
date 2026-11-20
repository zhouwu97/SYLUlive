import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
} from "react";
import { ApiError, asset, captureAuthSession, errorText, request, type Entity } from "./api";
import { Icon, useUI } from "./ui";
import { rejectAttachmentFiles, ticketAttachmentLimits } from "./attachments";
import "./media.css";
import {ImageViewer} from "./image-viewer";

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
  const dimension = (input: unknown) => typeof input === "number" && Number.isFinite(input) && input > 0 ? input : undefined;
  // 帖子接口的宽高位于 file；先建立尺寸，避免等图片加载后才撑开外框。
  return { ...item, width: dimension(item.width) ?? dimension(item.file?.width), height: dimension(item.height) ?? dimension(item.file?.height) };
}

type ImageUploadOptions = {signal?: AbortSignal; onUploaded?: (file: File, id: number) => void};
export async function uploadImageFiles(files: File[], options: ImageUploadOptions = {}): Promise<number[]> {
  const isCurrent = captureAuthSession();
  const valid = files.filter((file) => file.size > 0);
  const rejected = rejectAttachmentFiles(valid, mediaLimits);
  if (rejected.length) {
    throw new Error(`图片未通过检查：${rejected.map((x) => `${x.file}（${x.reason}）`).join("；")}`);
  }
  if (!valid.length) return [];

  const body = new FormData();
  valid.forEach((file) => body.append("files", file));
  try {
    const response = await request<{ results?: Entity[] }>("/api/upload_multiple", {method: 'POST', body, signal: options.signal});
    if (!isCurrent()) throw new Error("账号已切换，请重新确认上传");
    const results = Array.isArray(response.results) ? response.results : [];
    results.forEach((item, index) => {
      const id = Number(item.file_id);
      if (valid[index] && !item.error && Number.isInteger(id) && id > 0) options.onUploaded?.(valid[index], id);
    });
    const failed = results.filter((item) => item.error);
    const ids = results.map((item) => Number(item.file_id)).filter((id) => Number.isInteger(id) && id > 0);
    if (failed.length || ids.length !== valid.length) {
      throw new Error(failed.map((item) => String(item.error)).join("；") || "部分图片上传失败，请重试");
    }
    return ids;
  } catch (error) {
    if (!isCurrent() || options.signal?.aborted || (error instanceof DOMException && error.name === "AbortError")) throw error;
    // 旧服务实例没有批量端点时退回单文件上传，保持帖子发布可用。
    if (!(error instanceof ApiError) || ![404, 405, 501].includes(error.status)) throw error;
    const ids: number[] = [];
    for (const file of valid) {
      if (!isCurrent()) throw new Error("账号已切换，请重新确认上传");
      options.signal?.throwIfAborted();
      const result = await request<{ file_id?: number }>("/api/upload", {method: 'POST', signal: options.signal, body: (() => {
        const one = new FormData();
        one.append("file", file);
        return one;
      })()});
      if (!isCurrent()) throw new Error("账号已切换，请重新确认上传");
      const id = Number(result.file_id);
      if (!Number.isInteger(id) || id <= 0) throw new Error("上传没有返回有效的图片编号");
      ids.push(id);
      options.onUploaded?.(file, id);
    }
    return ids;
  }
}

// File 对象仅在当前会话内复用编号；批量部分失败时也保留已经成功的项目。
const uploadedFileIDs = new WeakMap<File, {id: number; isCurrent: () => boolean}>();
export async function uploadIDs(form: FormData, limits = mediaLimits, options: {signal?: AbortSignal; onProgress?: (done: number, total: number) => void} = {}) {
  const isCurrent = captureAuthSession();
  const files = form.getAll('images').filter((item): item is File => item instanceof File && item.size > 0);
  const rejected = rejectAttachmentFiles(files, limits);
  if (rejected.length) throw new Error(`附件未通过检查：${rejected.map(x => `${x.file}（${x.reason}）`).join('；')}`);
  const cachedID = (file: File) => {const cached = uploadedFileIDs.get(file); return cached?.isCurrent() ? cached.id : undefined;};
  const progress = () => options.onProgress?.(files.filter(file => cachedID(file) !== undefined).length, files.length);
  progress();
  const uncached = files.filter(file => cachedID(file) === undefined);
  if (uncached.length) await uploadImageFiles(uncached, {signal: options.signal, onUploaded: (file, id) => {
    if (!isCurrent() || options.signal?.aborted) return;
    uploadedFileIDs.set(file, {id, isCurrent}); progress();
  }});
  options.signal?.throwIfAborted();
  if (!isCurrent()) throw new Error('账号已切换，请重新确认上传');
  return [...new Set(files.map(file => cachedID(file)).filter((id): id is number => typeof id === 'number'))];
}

function MediaTile({ item, src, title, index, extra, onOpen }: { item: MediaItem; src: string; title: string; index: number; extra: number; onOpen: () => void }) {
  const [failed, setFailed] = useState(false);
  const [retry, setRetry] = useState(0);
  const [long, setLong] = useState(Number(item.height) / Number(item.width) > 2.2);
  return <button type="button" className={`media-tile ${long ? "media-tile--long" : ""}`} onClick={() => failed ? (setFailed(false), setRetry(value => value + 1)) : onOpen()} aria-label={`${title}第 ${index + 1} 张`}>
    {!failed ? <img key={retry} src={src} alt={`${title}第 ${index + 1} 张`} loading="lazy" decoding="async" width={item.width || undefined} height={item.height || undefined} onLoad={event => setLong(event.currentTarget.naturalHeight / event.currentTarget.naturalWidth > 2.2)} onError={() => setFailed(true)} /> : <span className="media-state">图片加载失败 · 点击重试</span>}
    {long && !failed && <span className="media-long-label">长图 · 点击查看</span>}
    {extra > 0 && <span className="media-more">+{extra}</span>}
  </button>;
}

export function MediaGallery({ items, title = "图片", className = "", maxVisible = 3, variant = "preview" }: { items?: unknown[]; title?: string; className?: string; maxVisible?: number; variant?: "preview" | "detail" }) {
  const ui = useUI();
  const media = useMemo(() => (items || []).map(normalizeMedia).filter((item) => mediaURL(item, "origin")), [items]);
  if (!media.length) return null;
  const visible = media.slice(0, maxVisible);
  const open = (index: number) => ui.open("图片预览", <ImageViewer images={media.map(item => ({src:mediaURL(item, "viewer") || mediaURL(item, "origin")!, original:mediaURL(item, "origin"), thumb:mediaURL(item, "thumb")}))} initial={index} title={title}/>, "media");
  return <div className={`media-gallery media-gallery-${Math.min(visible.length, 3)} media-gallery-${variant} ${className}`}>
    {visible.map((item, index) => {
      // 缩略图可能已经裁切；阅读区优先使用服务端等比 medium，详情使用 viewer。
      const src = (variant === "detail" ? asset(item.viewer_url) : undefined) || asset(item.medium_url) || mediaURL(item, "origin") || mediaURL(item, "thumb");
      const extra = media.length - visible.length;
      return src ? <MediaTile key={`${item.id || item.file_id || index}:${src}`} item={item} src={src} title={title} index={index} extra={index === visible.length - 1 ? extra : 0} onOpen={() => open(index)} /> : null;
    })}
  </div>;
}

export function MediaUploadPicker({ name = "images", initialFiles = [], onFilesChange, maxCount = mediaLimits.maxCount, disabled = false, compact = false }: { name?: string; initialFiles?: File[]; onFilesChange?: (files: File[]) => void; maxCount?: number; disabled?: boolean; compact?: boolean }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [files, setFiles] = useState(initialFiles);
  const [items, setItems] = useState<MediaUploadItem[]>([]);
  const [dragIndex, setDragIndex] = useState<number | null>(null);
  const [pickerError, setPickerError] = useState("");

  const syncFiles = (next: File[]) => {
    setFiles(next);
    onFilesChange?.(next);
  };
  useEffect(() => {
    const next = files.map(file => ({file, preview: URL.createObjectURL(file), status: 'ready' as const}));
    setItems(next);
    if (inputRef.current) {
      const transfer = new DataTransfer();
      files.forEach(file => transfer.items.add(file));
      inputRef.current.files = transfer.files;
    }
    return () => next.forEach(item => URL.revokeObjectURL(item.preview));
  }, [files]);

  const addFiles = (incoming: File[]) => {
    if (disabled) return;
    const next = [...files], errors: string[] = [];
    for (const file of incoming) {
      const rejected = rejectAttachmentFiles([file], mediaLimits);
      if (rejected.length) {errors.push(...rejected.map(x => `${x.file}（${x.reason}）`)); continue;}
      if (next.some(item => item.name === file.name && item.size === file.size && item.lastModified === file.lastModified)) {errors.push(`已跳过重复图片：${file.name}`); continue;}
      if (next.length >= maxCount) {errors.push('图片数量已达上限，请先移除部分图片'); break;}
      next.push(file);
    }
    setPickerError(errors.join('；'));
    syncFiles(next);
  };
  const addRef = useRef(addFiles); addRef.current = addFiles;
  useEffect(() => {
    const form = inputRef.current?.closest('form');
    const paste = (event: ClipboardEvent) => {
      const incoming = Array.from(event.clipboardData?.files || []);
      if (incoming.length) {event.preventDefault(); addRef.current(incoming);}
    };
    form?.addEventListener('paste', paste);
    return () => form?.removeEventListener('paste', paste);
  }, []);
  const onChange = (event: ChangeEvent<HTMLInputElement>) => addFiles(Array.from(event.target.files || []));
  const onDrop = (event: DragEvent<HTMLLabelElement>) => {
    event.preventDefault();
    addFiles(Array.from(event.dataTransfer.files || []));
  };
  const remove = (index: number) => {
    if (!disabled) syncFiles(files.filter((_, candidateIndex) => candidateIndex !== index));
  };
  const move = (from: number, to: number) => {
    if (disabled || to < 0 || to >= files.length || from === to) return;
    const next = [...files];
    const [item] = next.splice(from, 1);
    next.splice(to, 0, item);
    syncFiles(next);
  };

  return <div className={`media-upload-picker${compact ? ' media-upload-picker-compact' : ''}`} aria-disabled={disabled}>
    <label className="media-upload-drop" onDragOver={(event) => event.preventDefault()} onDrop={onDrop}>
      <input className="media-upload-input sr-only" ref={inputRef} name={name} type="file" accept="image/jpeg,image/png,image/gif" multiple disabled={disabled || files.length >= maxCount} onChange={onChange} aria-label="选择图片" aria-description={compact ? 'JPG、PNG、GIF，单张 10 MB 以内，可拖入或粘贴图片' : undefined} />
      <span className="media-upload-icon" aria-hidden="true">{compact ? <Icon name="image" size={19}/> : '＋'}</span>
      <b>{files.length >= maxCount ? '图片数量已达上限' : compact ? '添加图片' : '选择、拖入或粘贴图片'}</b><span>{compact ? `可拖入或粘贴 · 最多 ${maxCount} 张` : `JPG、PNG、GIF · 最多 ${maxCount} 张 · 单张 10 MB 以内`}</span>
    </label>
    {pickerError && <p className="media-upload-error" role="alert">{pickerError}</p>}
    {items.length > 0 && <div className="media-upload-grid" aria-live="polite">
      {items.map((item, index) => <div className="media-upload-item" key={`${item.file.name}-${item.file.lastModified}-${item.file.size}`} draggable={!disabled} onDragStart={() => setDragIndex(index)} onDragEnd={() => setDragIndex(null)} onDragOver={(event) => event.preventDefault()} onDrop={event => {event.preventDefault(); event.stopPropagation(); if (dragIndex !== null) move(dragIndex, index); setDragIndex(null); }}>
        <img src={item.preview} alt={`${item.file.name}预览`} />
        <div className="media-upload-meta"><span>{index + 1}</span><button type="button" disabled={disabled} aria-label={`移除${item.file.name}`} onClick={() => remove(index)}>×</button></div>
        <small>{item.file.name}</small>
        <div className="media-upload-order"><button type="button" disabled={disabled || index === 0} aria-label={`将${item.file.name}前移`} onClick={() => move(index, index - 1)}>←</button><button type="button" disabled={disabled || index === items.length - 1} aria-label={`将${item.file.name}后移`} onClick={() => move(index, index + 1)}>→</button></div>
      </div>)}
    </div>}
  </div>;
}

export function imageUploadError(error: unknown) {
  return errorText(error) || "图片上传失败，请重试";
}

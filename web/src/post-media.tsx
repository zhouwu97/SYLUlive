import {useEffect, useState, type CSSProperties, type ReactNode} from 'react';
import {asset, type Entity} from './api';
import {Icon, useUI} from './ui';

export function ServerImage({sources, alt, className = '', fallback}: {
  sources: unknown[];
  alt: string;
  className?: string;
  fallback?: ReactNode;
}) {
  const urls = [...new Set(sources.map(asset).filter((url): url is string => !!url))];
  // 地址改变后重新尝试，避免上一张图片的失败状态影响新的服务器数据。
  return <ImageSource key={urls.join('|')} urls={urls} alt={alt} className={className} fallback={fallback}/>;
}

function ImageSource({urls, alt, className, fallback}: {
  urls: string[]; alt: string; className: string; fallback?: ReactNode;
}) {
  const [source, setSource] = useState(0);
  const [loaded, setLoaded] = useState(false);
  const unavailable = source >= urls.length;
  return <span className={`server-image ${loaded ? 'is-loaded' : ''} ${unavailable ? 'is-unavailable' : ''} ${className}`}>
    {unavailable ? (fallback ?? <span className="image-unavailable"><Icon name="image"/><span>图片暂时无法显示</span></span>) :
      <img src={urls[source]} alt={alt} loading="lazy" decoding="async"
        onLoad={() => setLoaded(true)} onError={() => {setLoaded(false); setSource(current => current + 1);}}/>}
  </span>;
}

export function Avatar({user, className = ''}: {user?: Entity; className?: string}) {
  const name: string = typeof user?.nickname === 'string' && user.nickname ? user.nickname : '校园同学';
  return <span className={`author-avatar ${className}`}>
    <ServerImage sources={[user?.avatar_preview_url, user?.avatar]} alt={`${name}的头像`} fallback={<span aria-label={`${name}的头像`}>{Array.from(name)[0]}</span>}/>
  </span>;
}

function imageSources(image: Entity | string, full = false): unknown[] {
  if (typeof image === 'string') return [image];
  return full
    ? [image.viewer_url, image.origin_url, image.file?.path, image.url, image.medium_url]
    : [image.medium_url, image.file?.medium_url, image.file?.path, image.url, image.origin_url];
}

function imageLayout(image: Entity | string): CSSProperties {
  const file = typeof image === 'object' ? image.file || image : {};
  const width = Number(file.width), height = Number(file.height);
  const ratio = width > 0 && height > 0 ? width / height : 4 / 3;
  return {aspectRatio: ratio, '--image-width': `${Math.round(Math.min(540, Math.max(260, 360 * ratio)))}px`} as CSSProperties;
}

export function PostMedia({images = [], detail = false}: {images?: (Entity | string)[]; detail?: boolean}) {
  const ui = useUI();
  if (!images.length) return null;
  const visible = detail ? images : images.slice(0, 6);
  return <div className={`post-media ${images.length === 1 ? 'single-media' : 'multi-media'} ${detail ? 'detail-media' : ''}`} data-count={visible.length}>
    {visible.map((image, index) => <button key={typeof image === 'string' ? image : image.id || index}
      type="button" className="media-tile" style={images.length === 1 ? imageLayout(image) : undefined} aria-label={`查看图片 ${index + 1}，共 ${images.length} 张`}
      onClick={() => ui.open('帖子图片', <PhotoViewer images={images} initial={index}/>)}>
      <ServerImage sources={imageSources(image, detail)} alt={`帖子图片 ${index + 1}`}/>
      {!detail && index === visible.length - 1 && images.length > visible.length && <span className="media-more">+{images.length - visible.length}</span>}
    </button>)}
  </div>;
}

function PhotoViewer({images, initial}: {images: (Entity | string)[]; initial: number}) {
  const [index, setIndex] = useState(initial);
  const [retry, setRetry] = useState(0);
  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if (event.key === 'ArrowLeft') {event.preventDefault(); setIndex(current => Math.max(0, current - 1));}
      if (event.key === 'ArrowRight') {event.preventDefault(); setIndex(current => Math.min(images.length - 1, current + 1));}
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  }, [images.length]);
  const sources = imageSources(images[index], true);
  const original = sources.map(asset).find(Boolean);
  return <div className="photo-viewer">
    <ServerImage key={`${index}-${retry}`} sources={sources} alt={`帖子原图 ${index + 1}`}/>
    <div className="photo-toolbar">
      <button className="btn" disabled={index === 0} onClick={() => setIndex(index - 1)} aria-label="上一张图片">←</button>
      <span>{index + 1} / {images.length}</span>
      <button className="btn" disabled={index === images.length - 1} onClick={() => setIndex(index + 1)} aria-label="下一张图片">→</button>
      <button className="link-btn" onClick={() => setRetry(retry + 1)}>重新加载</button>
      {original && <a className="link-btn" href={original} target="_blank" rel="noreferrer">查看原图 ↗</a>}
    </div>
  </div>;
}

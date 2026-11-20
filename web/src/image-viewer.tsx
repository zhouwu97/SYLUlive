import {useCallback,useEffect,useRef,useState} from 'react';
import {Icon} from './ui';
import './image-viewer.css';

export type ViewerImage = {src: string; original?: string; thumb?: string};

/** 公共图片与鉴权后生成的临时附件地址共用查看器；附件地址仍由原读取方回收。 */
export function ImageViewer({images, initial = 0, title}: {images: ViewerImage[]; initial?: number; title: string}) {
  const [index, setIndex] = useState(initial), [zoom, setZoom] = useState(1);
  const image = images[index] || images[0];
  const change = useCallback((step: number) => {setIndex(value => (value + step + images.length) % images.length); setZoom(1);}, [images.length]);
  const scale = useCallback((value: number) => setZoom(Math.max(1, Math.min(4, value))), []);
  useEffect(() => {
    const handler = (event: KeyboardEvent) => {
      if ((event.target as HTMLElement)?.matches('input,textarea,select')) return;
      if (event.key === 'ArrowLeft' && images.length > 1) {event.preventDefault(); change(-1);}
      if (event.key === 'ArrowRight' && images.length > 1) {event.preventDefault(); change(1);}
      if (event.key === '+' || event.key === '=') {event.preventDefault(); setZoom(value => Math.min(4, value + .5));}
      if (event.key === '-') {event.preventDefault(); setZoom(value => Math.max(1, value - .5));}
      if (event.key === '0') {event.preventDefault(); setZoom(1);}
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [change, images.length]);
  if (!image) return <div className="media-state">图片暂不可用</div>;
  return <div className="media-lightbox" aria-label={`${title}，第 ${index + 1} 张，共 ${images.length} 张`}>
    <div className="media-lightbox-toolbar">
      <span className="media-lightbox-count" aria-live="polite">{index + 1} <span>/ {images.length}</span></span>
      <div className="media-lightbox-zoom" role="group" aria-label="缩放图片">
        <button type="button" aria-label="缩小" disabled={zoom <= 1} onClick={() => scale(zoom - .5)}>−</button>
        <output aria-label="缩放比例">{Math.round(zoom * 100)}%</output>
        <button type="button" aria-label="放大" disabled={zoom >= 4} onClick={() => scale(zoom + .5)}>＋</button>
        <button type="button" className="media-lightbox-fit" onClick={() => setZoom(1)}>适应窗口</button>
      </div>
      {image.original && <a className="media-lightbox-original" href={image.original} target="_blank" rel="noreferrer">打开原图<Icon name="link" size={15}/></a>}
    </div>
    <div className="media-lightbox-stage">
      {images.length > 1 && <button type="button" className="media-lightbox-nav prev" onClick={() => change(-1)} aria-label="上一张"><Icon name="arrow" size={22}/></button>}
      <LightboxImage key={`${index}:${image.src}`} src={image.src} alt={`${title}第 ${index + 1} 张`} zoom={zoom} onZoom={scale}/>
      {images.length > 1 && <button type="button" className="media-lightbox-nav next" onClick={() => change(1)} aria-label="下一张"><Icon name="arrow" size={22}/></button>}
    </div>
    {images.length > 1 && <div className="media-lightbox-thumbs" aria-label="图片缩略图">
      {images.map((candidate, i) => <button type="button" key={i} className={i === index ? 'active' : ''} onClick={() => {setIndex(i); setZoom(1);}} aria-label={`查看第 ${i + 1} 张`} aria-pressed={i === index}>
        <img src={candidate.thumb || candidate.src} alt=""/>
      </button>)}
    </div>}
    <div className="media-lightbox-caption"><span>{title}</span><small>双击缩放 · 放大后拖动查看</small></div>
  </div>;
}

function LightboxImage({src, alt, zoom, onZoom}: {src: string; alt: string; zoom: number; onZoom: (value: number) => void}) {
  const [phase, setPhase] = useState<'loading'|'ready'|'error'>('loading'), [attempt, setAttempt] = useState(0);
  const [offset, setOffset] = useState({x: 0, y: 0});
  const canvas = useRef<HTMLDivElement>(null);
  const points = useRef(new Map<number, {x: number; y: number}>());
  const previous = useRef({x: 0, y: 0, distance: 0});
  const zoomRef = useRef(zoom); zoomRef.current = zoom;
  useEffect(() => {if (zoom === 1) setOffset({x: 0, y: 0});}, [zoom]);
  useEffect(() => {
    const el = canvas.current;
    const wheel = (event: WheelEvent) => {event.preventDefault(); onZoom(zoomRef.current + (event.deltaY < 0 ? .25 : -.25));};
    el?.addEventListener('wheel', wheel, {passive: false});
    return () => el?.removeEventListener('wheel', wheel);
  }, [onZoom]);
  return <div ref={canvas} className={`media-lightbox-canvas${zoom > 1 ? ' is-zoomed' : ''}`} aria-busy={phase === 'loading'}
    onDoubleClick={() => onZoom(zoom === 1 ? 2 : 1)}
    onPointerDown={event => {
      if (phase !== 'ready' || event.button > 0) return;
      points.current.set(event.pointerId, {x:event.clientX, y:event.clientY});
      event.currentTarget.setPointerCapture(event.pointerId);
      previous.current = {x:event.clientX, y:event.clientY, distance:0};
    }}
    onPointerMove={event => {
      if (!points.current.has(event.pointerId)) return;
      points.current.set(event.pointerId, {x:event.clientX, y:event.clientY});
      const fingers = [...points.current.values()];
      if (fingers.length === 2) {
        const distance = Math.hypot(fingers[0].x-fingers[1].x, fingers[0].y-fingers[1].y);
        if (previous.current.distance) onZoom(zoom * distance / previous.current.distance);
        previous.current.distance = distance;
      } else if (zoom > 1) {
        const dx = event.clientX - previous.current.x, dy = event.clientY - previous.current.y;
        const width = event.currentTarget.clientWidth * (zoom - 1) / 2, height = event.currentTarget.clientHeight * (zoom - 1) / 2;
        setOffset(value => ({x:Math.max(-width,Math.min(width,value.x+dx)), y:Math.max(-height,Math.min(height,value.y+dy))}));
      }
      previous.current.x = event.clientX; previous.current.y = event.clientY;
    }}
    onPointerUp={event => {points.current.delete(event.pointerId); previous.current.distance = 0;}}
    onPointerCancel={event => {points.current.delete(event.pointerId); previous.current.distance = 0;}}>
    {phase === 'error' ? <div className="media-state" role="alert"><Icon name="image" size={32}/><b>图片加载失败</b><button type="button" onClick={() => {setPhase('loading'); setAttempt(value => value + 1);}}>重新加载</button></div>
      : <><img key={attempt} src={src} alt={alt} draggable={false} style={{transform:`translate(${offset.x}px, ${offset.y}px) scale(${zoom})`,opacity:phase === 'ready' ? 1 : 0}} onLoad={() => setPhase('ready')} onError={() => setPhase('error')}/>{phase === 'loading' && <div className="media-state" role="status">正在加载图片…</div>}</>}
  </div>;
}


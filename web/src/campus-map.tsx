import {useRef,useState} from 'react';

export function CampusMap(){
  const [zoom,setZoom]=useState(1);
  const [state,setState]=useState<'loading'|'ready'|'error'>('loading');
  const [attempt,setAttempt]=useState(0);
  const viewport=useRef<HTMLDivElement>(null);
  const image=`${import.meta.env.BASE_URL}assets/campus-map.png`;
  function reset(){setZoom(1);viewport.current?.scrollTo({top:0,left:0})}
  return <>
    <div className="filter-row">
      <button className="btn" disabled={state!=='ready'||zoom<=1} onClick={()=>setZoom(z=>Math.max(1,z-.5))}>缩小</button>
      <output aria-live="polite">{Math.round(zoom*100)}%</output>
      <button className="btn" disabled={state!=='ready'||zoom>=5} onClick={()=>setZoom(z=>Math.min(5,z+.5))}>放大</button>
      <button className="btn" onClick={reset}>复位地图</button>
      <a className="btn" href={image} target="_blank" rel="noreferrer">打开原图</a>
    </div>
    <p className="muted">与 App 使用同一份校园地图。放大后可滚动或触屏滑动查看。</p>
    {state==='loading'&&<p role="status">正在加载地图…</p>}
    {state==='error'&&<div className="empty-state"><h3>地图加载失败</h3><p>请检查网络后重新加载，也可以打开原图查看。</p><button className="btn" onClick={()=>{setState('loading');setAttempt(value=>value+1)}}>重新加载地图</button></div>}
    <div className="campus-map-viewport" ref={viewport} tabIndex={0} role="region" aria-label="可滚动校园地图">
      <img key={attempt} src={attempt?`${image}?retry=${attempt}`:image} alt="沈阳理工大学校园地图" onLoad={()=>setState('ready')} onError={()=>setState('error')} hidden={state==='error'} style={{width:`${zoom*100}%`}}/>
    </div>
  </>;
}

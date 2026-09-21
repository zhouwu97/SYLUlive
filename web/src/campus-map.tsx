import {useRef,useState} from 'react';

export function CampusMap(){
  const [zoom,setZoom]=useState(1);
  const viewport=useRef<HTMLDivElement>(null);
  const image=`${import.meta.env.BASE_URL}assets/campus-map.png`;
  function reset(){setZoom(1);viewport.current?.scrollTo({top:0,left:0})}
  return <>
    <div className="filter-row">
      <button className="btn" disabled={zoom<=1} onClick={()=>setZoom(z=>Math.max(1,z-.5))}>缩小</button>
      <output aria-live="polite">{Math.round(zoom*100)}%</output>
      <button className="btn" disabled={zoom>=5} onClick={()=>setZoom(z=>Math.min(5,z+.5))}>放大</button>
      <button className="btn" onClick={reset}>复位地图</button>
      <a className="btn" href={image} target="_blank" rel="noreferrer">打开原图</a>
    </div>
    <p className="muted">与 App 使用同一份校园地图。放大后可滚动或触屏滑动查看。</p>
    <div className="campus-map-viewport" ref={viewport} tabIndex={0} role="region" aria-label="可滚动校园地图">
      <img src={image} alt="沈阳理工大学校园地图" style={{width:`${zoom*100}%`}}/>
    </div>
  </>;
}

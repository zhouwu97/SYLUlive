/* Product tour: keyboard, native touch, mouse dragging and vertical wheel paging. */
(()=>{
const reduceMotion=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const storyViewport=document.getElementById('storyViewport'),storySlides=[...document.querySelectorAll('.story-slide')],storyPages=[...document.querySelectorAll('.story-page')],storyPrev=document.getElementById('storyPrev'),storyNext=document.getElementById('storyNext'),storyStatus=document.getElementById('storyStatus');
const storyProgress=document.getElementById('storyProgress'),storySection=document.getElementById('product');
if(!storySection||!storyViewport||!storySlides.length||!storyPrev||!storyNext||!storyStatus)return;
let activeStory=0,requestedStory=null,storySettleTimer=0,storyDrag=null;
const clampStory=i=>Math.max(0,Math.min(storySlides.length-1,i));
function updateStory(i){
  activeStory=clampStory(i);
  storySlides.forEach((slide,n)=>{slide.setAttribute('aria-hidden',String(n!==activeStory));slide.inert=n!==activeStory});
  storyPages.forEach((button,n)=>button.setAttribute('aria-pressed',String(n===activeStory)));
  storyPrev.disabled=activeStory===0;storyNext.disabled=activeStory===storySlides.length-1;
  const label=storySlides[activeStory].getAttribute('aria-label');
  if(storyStatus.textContent!==label)storyStatus.textContent=label;
  if(storyProgress)storyProgress.style.width=`${(activeStory+1)/storySlides.length*100}%`;
}
function goToStory(i,alignPage=false){
  if(alignPage&&window.innerHeight>620&&Math.abs(storySection.getBoundingClientRect().top)>2){
    storySection.scrollIntoView({block:'start',behavior:'instant'});
  }
  requestedStory=clampStory(i);updateStory(requestedStory);
  storyViewport.scrollTo({left:requestedStory*storyViewport.clientWidth,behavior:reduceMotion?'instant':'smooth'});
}
function settleStory(){
  if(storyDrag)return;
  requestedStory=null;updateStory(Math.round(storyViewport.scrollLeft/storyViewport.clientWidth));
}
updateStory(0);
storyPages.forEach(button=>button.addEventListener('click',()=>goToStory(Number(button.dataset.story),true)));
storyPrev.addEventListener('click',()=>goToStory((requestedStory??activeStory)-1,true));
storyNext.addEventListener('click',()=>goToStory((requestedStory??activeStory)+1,true));
storyViewport.addEventListener('keydown',e=>{
  if(e.altKey||e.ctrlKey||e.metaKey)return;
  const current=requestedStory??activeStory;
  const next=e.key==='ArrowRight'?current+1:e.key==='ArrowLeft'?current-1:e.key==='Home'?0:e.key==='End'?storySlides.length-1:null;
  if(next===null)return;e.preventDefault();goToStory(next,true);
});
storyViewport.addEventListener('scroll',()=>{clearTimeout(storySettleTimer);storySettleTimer=setTimeout(settleStory,160)},{passive:true});
storyViewport.addEventListener('scrollend',settleStory);
// 一个滚轮手势只切换一页；首尾交还页面滚动，横向触控板和缩放不拦截。
let wheelDirection=0,wheelDistance=0,wheelLocked=false,wheelTimer=0,wheelArmed=true,armTimer=0;
function resetWheel(){wheelDirection=0;wheelDistance=0;wheelLocked=false}
// 先让纵向浏览停稳；同一个进入展示区的滚轮手势不立即变成横向翻页。
window.addEventListener('scroll',()=>{
  wheelArmed=false;resetWheel();clearTimeout(armTimer);
  armTimer=setTimeout(()=>{wheelArmed=true},240);
},{passive:true});
storySection.addEventListener('wheel',e=>{
  if(window.innerHeight<=620||e.ctrlKey||e.shiftKey||e.defaultPrevented||!e.cancelable||storyDrag||Math.abs(e.deltaX)>Math.abs(e.deltaY)||!e.deltaY)return;
  const bounds=storyViewport.getBoundingClientRect();
  const navBottom=document.getElementById('nav')?.getBoundingClientRect().bottom??72;
  const pageBounds=storySection.getBoundingClientRect();
  // 页面接近整屏时允许小幅对齐误差，半屏状态仍保留正常纵向滚动。
  if(Math.abs(pageBounds.top)>32||pageBounds.bottom>window.innerHeight+32||bounds.top<navBottom+8||bounds.bottom>window.innerHeight-12){resetWheel();return}
  if(!wheelArmed){e.preventDefault();return}
  const direction=Math.sign(e.deltaY);
  if(direction!==wheelDirection){resetWheel();wheelDirection=direction}
  const current=requestedStory??activeStory,next=clampStory(current+direction);
  if(current===next&&!wheelLocked){
    e.preventDefault();
    // 越过整屏吸附范围后离开，细小滚轮也不会被吸回第一／最后一页。
    window.scrollBy({top:direction*window.innerHeight,behavior:reduceMotion?'instant':'smooth'});
    return;
  }
  e.preventDefault();
  clearTimeout(wheelTimer);wheelTimer=setTimeout(resetWheel,220);
  if(wheelLocked)return;
  const unit=e.deltaMode===1?16:e.deltaMode===2?storyViewport.clientHeight:1;
  wheelDistance+=Math.abs(e.deltaY)*unit;
  if(wheelDistance<24)return;
  wheelLocked=true;goToStory(next,true);
},{passive:false});
// 触屏保留原生滑动；鼠标拖动只处理展示区，不干扰纵向页面浏览。
storyViewport.addEventListener('pointerdown',e=>{
  requestedStory=null;
  if(e.pointerType!=='mouse'||e.button!==0)return;
  storyViewport.scrollTo({left:storyViewport.scrollLeft,behavior:'instant'});
  storyDrag={id:e.pointerId,x:e.clientX,left:storyViewport.scrollLeft,index:Math.round(storyViewport.scrollLeft/storyViewport.clientWidth)};
  storyViewport.classList.add('dragging');storyViewport.setPointerCapture(e.pointerId);
});
storyViewport.addEventListener('pointermove',e=>{if(storyDrag&&e.pointerId===storyDrag.id)storyViewport.scrollLeft=storyDrag.left+storyDrag.x-e.clientX});
function finishStoryDrag(e,cancelled=false){
  if(!storyDrag||e.pointerId!==storyDrag.id)return;
  const drag=storyDrag;storyDrag=null;storyViewport.classList.remove('dragging');
  if(storyViewport.hasPointerCapture(e.pointerId))storyViewport.releasePointerCapture(e.pointerId);
  const delta=drag.x-e.clientX,threshold=Math.min(80,storyViewport.clientWidth*.16);
  goToStory(cancelled?drag.index:Math.abs(delta)>threshold?drag.index+Math.sign(delta):drag.index);
}
storyViewport.addEventListener('pointerup',e=>finishStoryDrag(e));
storyViewport.addEventListener('pointercancel',e=>finishStoryDrag(e,true));
storyViewport.addEventListener('lostpointercapture',e=>finishStoryDrag(e,true));
new ResizeObserver(()=>{requestedStory=null;storyViewport.scrollTo({left:activeStory*storyViewport.clientWidth,behavior:'instant'})}).observe(storyViewport);
})();

/* Let a deliberate wheel gesture move between complete, aligned chapters. */
(() => {
  const sections = [...document.querySelectorAll('main > section')];
  if (!sections.length) return;
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  let direction = 0, distance = 0, locked = false, timer = 0;
  function reset() { direction = 0; distance = 0; locked = false; }

  window.addEventListener('wheel', event => {
    if (window.innerHeight <= 620 || reducedMotion.matches || event.defaultPrevented ||
        !event.cancelable || event.ctrlKey || event.shiftKey || !event.deltaY ||
        Math.abs(event.deltaX) > Math.abs(event.deltaY)) return;
    // 产品区自己的轮播负责手势；有独立滚动内容时不抢占该内容。
    if (event.target?.closest?.('#product, .nav-wrap, [data-free-scroll]')) return;
    const index = sections.findIndex(section => {
      const rect = section.getBoundingClientRect();
      return Math.abs(rect.top) <= 2 && rect.height <= window.innerHeight + 2;
    });
    if (index < 0) return;
    const nextDirection = Math.sign(event.deltaY);
    const next = sections[index + nextDirection];
    if (!next) return;
    event.preventDefault();
    clearTimeout(timer);
    timer = setTimeout(reset, 220);
    if (locked) return;
    if (direction !== nextDirection) { direction = nextDirection; distance = 0; }
    const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? window.innerHeight : 1;
    distance += Math.abs(event.deltaY) * unit;
    if (distance < 24) return;
    locked = true;
    next.scrollIntoView({block: 'start', behavior: 'smooth'});
  }, {passive: false});
})();

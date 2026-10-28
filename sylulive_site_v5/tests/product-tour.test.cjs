const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture(reducedMotion = false) {
  class Element extends EventTarget {
    constructor() {
      super();
      this.attrs = new Map(); this.style = {}; this.scrollLeft = 0;
      this.clientWidth = 1200; this.clientHeight = 500;
      this.bounds = {top:120,bottom:620};
      this.classList = {add() {}, remove() {}};
    }
    setAttribute(k, v) { this.attrs.set(k, v); }
    getAttribute(k) { return this.attrs.get(k); }
    getBoundingClientRect() { return this.bounds; }
    scrollTo(value) { this.scrollLeft = value.left; this.behavior = value.behavior; }
    scrollIntoView(value) { this.aligned=value; }
    setPointerCapture(id) { this.pointer = id; }
    hasPointerCapture(id) { return this.pointer === id; }
    releasePointerCapture() { this.pointer = null; }
  }
  const ids = Object.fromEntries(['product', 'storyViewport', 'storyPrev', 'storyNext', 'storyStatus', 'storyProgress'].map(k => [k, new Element()]));
  ids.product.bounds={top:0,bottom:800};
  const slides = Array.from({length: 4}, (_, i) => {const e = new Element(); e.setAttribute('aria-label', `Product ${i + 1}`); return e;});
  const pages = slides.map((_, i) => {const e = new Element(); e.dataset = {story: String(i)}; return e;});
  let time = 0, next = 0, resize;
  const timers = new Map();
  const windowEvents = new EventTarget(),pageScrolls=[];
  const context = {
    document: {getElementById: k => ids[k], querySelectorAll: q => q === '.story-slide' ? slides : pages},
    window: {matchMedia: () => ({matches: reducedMotion}),innerHeight:800,addEventListener:windowEvents.addEventListener.bind(windowEvents),scrollBy:value=>pageScrolls.push(value)},
    ResizeObserver: class {constructor(cb) { resize = cb; } observe() {}},
    setTimeout: (cb, ms) => {timers.set(++next, {cb, due: time + ms}); return next;},
    clearTimeout: id => timers.delete(id),
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../assets/product-tour.js'), 'utf8'), context);
  function event(target, type, values = {}) {
    const e = Object.assign(new Event(type, {cancelable: true}), values);
    target.dispatchEvent(e); return e;
  }
  return {
    ids, slides, pages, resize: () => resize(), windowEvents, pageScrolls, window: context.window,
    selected: () => pages.findIndex(e => e.getAttribute('aria-pressed') === 'true'),
    wheel: (values = {}) => event(ids.product, 'wheel', {deltaX: 0, deltaY: 120, deltaMode: 0, ...values}),
    event,
    tick(ms) {time += ms; for (const [id, timer] of timers) if (timer.due <= time) {timers.delete(id); timer.cb();}},
  };
}

test('vertical wheel selects a horizontal page and updates accessible state', () => {
  const f = fixture();
  assert.equal(f.ids.storyPrev.disabled, true);
  assert.equal(f.wheel().defaultPrevented, true);
  assert.equal(f.selected(), 1);
  assert.equal(f.ids.storyViewport.scrollLeft, 1200);
  assert.equal(f.ids.storyViewport.behavior, 'smooth');
  assert.equal(f.ids.storyProgress.style.width, '50%');
  assert.equal(f.slides[0].inert, true);
  assert.equal(f.slides[1].inert, false);
});

test('one inertial gesture changes only one page; a new gesture and reversal work', () => {
  const f = fixture();
  f.wheel();
  for (let i = 0; i < 12; i++) f.wheel({deltaY: 30});
  assert.equal(f.selected(), 1);
  f.tick(221); f.wheel();
  assert.equal(f.selected(), 2);
  f.wheel({deltaY: -120});
  assert.equal(f.selected(), 1);
});

test('first and last pages leave the full-screen tour without snapping back', () => {
  const f = fixture();
  assert.equal(f.wheel({deltaY: -120}).defaultPrevented, true);
  assert.equal(f.pageScrolls[0].top,-800);
  f.event(f.ids.storyNext, 'click'); f.event(f.ids.storyNext, 'click'); f.event(f.ids.storyNext, 'click');
  assert.equal(f.selected(), 3);
  assert.equal(f.ids.storyNext.disabled, true);
  assert.equal(f.wheel().defaultPrevented, true);
  assert.equal(f.pageScrolls[1].top,800);
  assert.equal(f.wheel({deltaY: -120}).defaultPrevented, true);
  assert.equal(f.selected(), 2);
});

test('zoom, shift-scroll and horizontal trackpad input keep native behavior', () => {
  const f = fixture();
  for (const values of [{ctrlKey: true}, {shiftKey: true}, {deltaX: 160, deltaY: 10}, {deltaY: 0}]) {
    assert.equal(f.wheel(values).defaultPrevented, false);
    assert.equal(f.selected(), 0);
  }
});

test('small trackpad deltas accumulate and line/page delta modes are normalized', () => {
  const f = fixture();
  for (let i = 0; i < 5; i++) f.wheel({deltaY: 4});
  assert.equal(f.selected(), 0);
  f.wheel({deltaY: 4}); assert.equal(f.selected(), 1);
  f.tick(221); f.wheel({deltaY: 2, deltaMode: 1}); assert.equal(f.selected(), 2);
  f.tick(221); f.wheel({deltaY: 1, deltaMode: 2}); assert.equal(f.selected(), 3);
});

test('native swipe, keyboard, direct pagination and resize remain consistent', () => {
  const f = fixture();
  f.ids.storyViewport.scrollLeft = 2400; f.event(f.ids.storyViewport, 'scrollend');
  assert.equal(f.selected(), 2);
  f.event(f.ids.storyViewport, 'keydown', {key: 'End'}); assert.equal(f.selected(), 3);
  f.event(f.ids.storyViewport, 'keydown', {key: 'Home'}); assert.equal(f.selected(), 0);
  f.event(f.pages[1], 'click'); assert.equal(f.selected(), 1);
  f.ids.storyViewport.clientWidth = 390; f.resize();
  assert.equal(f.ids.storyViewport.scrollLeft, 390);
});

test('mouse drag advances one page and cancellation returns to the starting page', () => {
  const f = fixture();
  f.event(f.ids.storyViewport, 'pointerdown', {pointerType: 'mouse', button: 0, pointerId: 1, clientX: 900});
  f.event(f.ids.storyViewport, 'pointermove', {pointerId: 1, clientX: 500});
  f.event(f.ids.storyViewport, 'pointerup', {pointerId: 1, clientX: 500});
  assert.equal(f.selected(), 1);
  f.event(f.ids.storyViewport, 'pointerdown', {pointerType: 'mouse', button: 0, pointerId: 2, clientX: 900});
  f.event(f.ids.storyViewport, 'pointercancel', {pointerId: 2, clientX: 400});
  assert.equal(f.selected(), 1);
});

test('reduced motion uses immediate paging', () => {
  const f = fixture(true); f.wheel();
  assert.equal(f.selected(), 1);
  assert.equal(f.ids.storyViewport.behavior, 'instant');
});

test('partially visible and header-obscured tours never intercept vertical browsing', () => {
  const f = fixture();
  for (const bounds of [{top:420,bottom:920},{top:70,bottom:570},{top:-100,bottom:400}]) {
    f.ids.storyViewport.bounds=bounds;
    assert.equal(f.wheel().defaultPrevented,false);
    assert.equal(f.selected(),0);
  }
});

test('settling the tour prevents snap-back before the next gesture pages it', () => {
  const f = fixture();
  f.event(f.windowEvents,'scroll');
  assert.equal(f.wheel().defaultPrevented,true);
  assert.equal(f.selected(),0);
  f.tick(180);f.event(f.windowEvents,'scroll');f.tick(180);
  assert.equal(f.wheel().defaultPrevented,true);
  assert.equal(f.selected(),0);
  f.tick(61);assert.equal(f.wheel().defaultPrevented,true);assert.equal(f.selected(),1);
});

test('wheel over the section heading selects a slide without clicking an arrow', () => {
  const f = fixture();
  assert.equal(f.event(f.ids.product,'wheel',{deltaX:0,deltaY:120,deltaMode:0}).defaultPrevented,true);
  assert.equal(f.selected(),1);
});

test('near-aligned page is corrected and the same gesture selects a slide', () => {
  const f = fixture();
  f.ids.product.bounds={top:24,bottom:824};
  assert.equal(f.wheel().defaultPrevented,true);
  assert.equal(f.selected(),1);
  assert.equal(f.ids.product.aligned.block,'start');
});

test('short windows keep ordinary vertical scrolling', () => {
  const f = fixture();
  f.window.innerHeight=600;
  assert.equal(f.wheel().defaultPrevented,false);
  assert.equal(f.selected(),0);
});

test('the whole product page must be aligned, even if the image area is fully visible', () => {
  const f = fixture();
  for(const bounds of [{top:-150,bottom:650},{top:120,bottom:920},{top:0,bottom:1000}]) {
    f.ids.product.bounds=bounds;
    assert.equal(f.wheel().defaultPrevented,false);
    assert.equal(f.selected(),0);
  }
  f.ids.product.bounds={top:0,bottom:800};
  assert.equal(f.wheel().defaultPrevented,true);
  assert.equal(f.selected(),1);
});

test('pagination brings a partially scrolled product page fully into view', () => {
  const f = fixture();f.ids.product.bounds={top:-200,bottom:600};
  f.event(f.pages[2],'click');
  assert.equal(f.selected(),2);
  assert.equal(f.ids.product.aligned.block,'start');
  assert.equal(f.ids.product.aligned.behavior,'instant');
});

const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function fixture({height = 800, reduced = false} = {}) {
  const wheelEvents = new EventTarget();
  const sections = Array.from({length: 4}, (_, i) => ({
    bounds: {top: i * height, height},
    getBoundingClientRect() { return this.bounds; },
    scrollIntoView(options) { this.aligned = options; },
  }));
  let time = 0, next = 0;
  const timers = new Map();
  const window = {
    innerHeight: height,
    matchMedia: () => ({matches: reduced}),
    addEventListener: wheelEvents.addEventListener.bind(wheelEvents),
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../assets/section-snap.js'), 'utf8'), {
    window,
    document: {querySelectorAll: () => sections},
    setTimeout: (cb, ms) => { timers.set(++next, {cb, due: time + ms}); return next; },
    clearTimeout: id => timers.delete(id),
  });
  function wheel(values = {}) {
    const e = Object.assign(new Event('wheel', {cancelable: true}), {
      deltaX: 0, deltaY: 120, deltaMode: 0, ...values,
    });
    const target = {closest: () => values.exclude || null};
    Object.defineProperty(e, 'target', {value: target});
    wheelEvents.dispatchEvent(e);
    return e;
  }
  return {sections, wheel, tick(ms) {
    time += ms;
    for (const [id, timer] of timers) if (timer.due <= time) { timers.delete(id); timer.cb(); }
  }};
}

test('aligned chapters move in both directions and one gesture moves once', () => {
  const f = fixture();
  assert.equal(f.wheel().defaultPrevented, true);
  assert.equal(f.sections[1].aligned.block, 'start');
  f.wheel();
  assert.equal(f.sections[2].aligned, undefined);
  f.tick(221);
  f.sections[0].bounds.top = -800;
  f.sections[1].bounds.top = 0;
  assert.equal(f.wheel({deltaY: -120}).defaultPrevented, true);
  assert.equal(f.sections[0].aligned.block, 'start');
});

test('tiny trackpad deltas accumulate but excluded and zoom gestures are untouched', () => {
  const f = fixture();
  for (const values of [{ctrlKey: true}, {shiftKey: true}, {deltaX: 80, deltaY: 10}, {exclude: true}]) {
    assert.equal(f.wheel(values).defaultPrevented, false);
  }
  for (let i = 0; i < 6; i++) f.wheel({deltaY: 4});
  assert.equal(f.sections[1].aligned.block, 'start');
});

test('long content, short windows and reduced motion keep native scrolling', () => {
  const long = fixture();
  long.sections[0].bounds.height = 1200;
  assert.equal(long.wheel().defaultPrevented, false);
  assert.equal(fixture({height: 600}).wheel().defaultPrevented, false);
  assert.equal(fixture({reduced: true}).wheel().defaultPrevented, false);
});

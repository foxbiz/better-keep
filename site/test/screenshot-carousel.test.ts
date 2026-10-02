import assert from 'node:assert/strict';
import test from 'node:test';
import { initializeCarousel } from '../src/lib/screenshot-carousel.ts';

type FixtureEvent = { target?: unknown; key?: string; preventDefault?: () => void };

function carousel() {
  function target() {
    const handlers = new Map<string, (event: FixtureEvent) => void>();
    return {
      hidden: false,
      attributes: {} as Record<string, string>,
      textContent: null as string | null,
      addEventListener(name: string, handler: (event: FixtureEvent) => void) { handlers.set(name, handler); },
      emit(name: string, event: FixtureEvent = {}) { handlers.get(name)?.(event); },
      setAttribute(name: string, value: string) { this.attributes[name] = value; }
    };
  }
  const timers = new Map<number, () => void>();
  let timerId = 0;
  let observe: (entries: { isIntersecting: boolean; intersectionRatio: number }[]) => void = () => assert.fail('Observer not initialized');
  const doc = { ...target(), hidden: false, defaultView: {
    matchMedia: () => ({ matches: true }),
    clearTimeout: (id: number | undefined) => { if (id !== undefined) timers.delete(id); },
    setTimeout(callback: () => void, delay: number) {
      assert.equal(delay, 6000);
      timers.set(++timerId, callback);
      return timerId;
    },
    IntersectionObserver: class {
      constructor(callback: typeof observe) { observe = callback; }
      observe() {}
    }
  } };
  const scrolls: ScrollToOptions[] = [];
  const rail = {
    ...target(), scrollLeft: 0, scrollWidth: 1200, clientWidth: 300,
    getBoundingClientRect: () => ({ left: 30 }),
    scrollTo(options: ScrollToOptions) { scrolls.push(options); this.scrollLeft = options.left ?? 0; },
    children: [] as { getBoundingClientRect: () => { left: number } }[]
  };
  rail.children = [0, 332, 664, 996].map((left) => ({
    getBoundingClientRect: () => ({ left: left + 30 - rail.scrollLeft })
  }));
  const controls = target();
  controls.hidden = true;
  const previous = target();
  const next = target();
  const toggle = target();
  const elements: Record<string, ReturnType<typeof target>> = {
    '.device-gallery': rail,
    '[data-carousel-controls]': controls,
    '[data-carousel-previous]': previous,
    '[data-carousel-next]': next,
    '[data-carousel-toggle]': toggle
  };
  const root = {
    ...target(), ownerDocument: doc,
    querySelector: (selector: string) => elements[selector]
  };
  initializeCarousel(root as unknown as HTMLElement);
  return {
    root, rail, controls, previous, next, toggle, doc, timers, scrolls,
    show(ratio = 1) { observe([{ isIntersecting: ratio > 0, intersectionRatio: ratio }]); },
    tick() {
      const [id, callback] = [...timers][0];
      timers.delete(id);
      callback();
    }
  };
}

test('autoplay ignores reduced motion, runs only in view and wraps at the last card', () => {
  const view = carousel();
  assert.equal(view.controls.hidden, false);
  assert.equal(view.timers.size, 0);
  view.show(0.1);
  assert.equal(view.timers.size, 0);
  view.show();
  for (const left of [332, 664, 900, 0]) {
    view.tick();
    assert.deepEqual(view.scrolls.at(-1), { left, behavior: 'smooth' });
    assert.equal(view.timers.size, 1);
  }
  view.show(0);
  assert.equal(view.timers.size, 0);
});

test('the pause button stays visible and preserves the manual choice until Play', () => {
  const view = carousel();
  view.show();
  assert.equal(view.toggle.hidden, false);
  assert.equal(view.timers.size, 1);
  view.toggle.emit('click');
  assert.equal(view.timers.size, 0);
  assert.equal(view.toggle.textContent, 'Play');
  assert.equal(view.toggle.attributes['aria-label'], 'Start automatic scrolling');
  view.next.emit('click');
  assert.equal(view.rail.scrollLeft, 332);
  assert.equal(view.timers.size, 0);
  view.doc.hidden = true;
  view.doc.emit('visibilitychange');
  view.doc.hidden = false;
  view.doc.emit('visibilitychange');
  assert.equal(view.timers.size, 0);
  view.toggle.emit('click');
  assert.equal(view.timers.size, 1);
  assert.equal(view.toggle.textContent, 'Pause');
  view.doc.hidden = true;
  view.doc.emit('visibilitychange');
  assert.equal(view.timers.size, 0);
  view.doc.hidden = false;
  view.doc.emit('visibilitychange');
  assert.equal(view.timers.size, 1);
});

test('keyboard and button navigation wrap without switching off autoplay', () => {
  const view = carousel();
  view.show();
  let prevented = false;
  view.rail.emit('keydown', {
    target: view.rail, key: 'ArrowLeft', preventDefault() { prevented = true; }
  });
  assert.equal(prevented, true);
  assert.deepEqual(view.scrolls.at(-1), { left: 900, behavior: 'smooth' });
  assert.equal(view.timers.size, 1);
  view.rail.emit('keydown', { target: view.rail, key: 'Tab', preventDefault() { assert.fail('Keep normal Tab navigation'); } });
  view.next.emit('click');
  assert.equal(view.rail.scrollLeft, 0);
  assert.equal(view.timers.size, 1);
  view.previous.emit('click');
  assert.equal(view.rail.scrollLeft, 900);
});

import assert from 'node:assert/strict';
import test from 'node:test';
import { initializeHeroVideo } from '../src/lib/hero-video.ts';

type Listener = () => void;

async function setup(options: {
  autoplay?: boolean;
  codec?: 'av1' | 'h264' | Promise<'av1' | 'h264'>;
  neverLoads?: boolean;
  stallMs?: number;
  narrow?: boolean;
  refusePlayback?: boolean | 'audible';
} = {}) {
  const listeners = new Map<string, Listener>();
  const attributes = new Map<string, string>();
  const video = {
    currentTime: 0,
    // Index-only, like the narrowest TextTrackList.
    textTracks: { length: 1, 0: { mode: 'disabled' } },
    paused: true,
    isMuted: true,
    get muted() { return video.isMuted; },
    set muted(value: boolean) {
      video.isMuted = value;
      listeners.get('volumechange')?.();
    },
    addEventListener: (name: string, listener: Listener) => listeners.set(name, listener),
    setAttribute: (name: string, value: string) => attributes.set(name, value),
    pause() {
      if (video.paused) return;
      video.paused = true;
      listeners.get('pause')?.();
    },
    async play() {
      if (options.refusePlayback === true || (options.refusePlayback === 'audible' && !video.muted)) {
        throw Object.assign(new Error('refused'), { name: 'NotAllowedError' });
      }
      video.paused = false;
      listeners.get('play')?.();
      if (!options.neverLoads) progress();
    }
  };
  const progress = () => {
    video.currentTime += 0.25;
    listeners.get('timeupdate')?.();
  };
  let click: Listener = () => {};
  const label = { value: '' };
  let clickMute: Listener = () => {};
  const muteLabel = { value: '' };
  const mute = {
    addEventListener: (_name: string, listener: Listener) => { clickMute = listener; },
    setAttribute: (_name: string, value: string) => { muteLabel.value = value; }
  };
  const captionState = { pressed: 'false' };
  let clickCaptions: Listener = () => {};
  const captions = {
    addEventListener: (_name: string, listener: Listener) => { clickCaptions = listener; },
    getAttribute: () => captionState.pressed,
    setAttribute: (_name: string, value: string) => { captionState.pressed = value; }
  };
  const controls = { hidden: true };
  const toggle = {
    addEventListener: (_name: string, listener: Listener) => { click = listener; },
    setAttribute: (_name: string, value: string) => { label.value = value; }
  };
  const stage = {
    dataset: {} as Record<string, string>,
    querySelector: (selector: string) =>
      selector.includes('toggle') ? toggle
        : selector.includes('mute') ? mute
          : selector.includes('captions') ? captions
          : selector.includes('controls') ? controls : video
  };
  let resize: Listener = () => {};
  const narrow = {
    matches: options.narrow ?? false,
    addEventListener: (_name: string, listener: Listener) => { resize = listener; }
  };
  const revealed = { count: 0 };
  let visibility: Listener = () => {};
  const page = {
    hidden: false,
    addEventListener: (_name: string, listener: Listener) => { visibility = listener; }
  };
  let intersect: (entries: { isIntersecting: boolean }[]) => void = () => {};
  class FakeObserver {
    constructor(callback: typeof intersect) { intersect = callback; }
    observe() {}
  }
  initializeHeroVideo(stage as unknown as HTMLElement, {
    narrow: narrow as unknown as MediaQueryList,
    page: page as unknown as Document,
    Observer: FakeObserver,
    autoplay: options.autoplay ?? true,
    codec: Promise.resolve(options.codec ?? 'h264'),
    reveal: () => { revealed.count += 1; },
    stallMs: options.stallMs ?? 5,
    select: ({ narrow: isNarrow, codec, ceiling }) => {
      const index = Math.min(2, ceiling);
      return { src: `/${isNarrow ? 'tall' : 'wide'}-${index}.${codec}`, index };
    }
  });
  await Promise.resolve();
  await Promise.resolve();
  return {
    video, revealed, captionState, controls, label, muteLabel, stage, narrow,
    page,
    source: () => attributes.get('src'),
    progress,
    emit: (name: string) => listeners.get(name)?.(),
    visibility: () => visibility(),
    click: () => click(),
    clickMute: () => clickMute(),
    clickCaptions: () => clickCaptions(),
    resize: () => resize(),
    scroll: (isIntersecting: boolean) => intersect([{ isIntersecting }])
  };
}

test('fetches and plays the matching cut only once it is on screen', async () => {
  const hero = await setup();
  assert.equal(hero.source(), undefined);
  assert.equal(hero.controls.hidden, true);
  hero.scroll(true);
  assert.equal(hero.controls.hidden, false);
  assert.equal(hero.source(), '/wide-2.h264');
  assert.equal(hero.stage.dataset.ready, 'true');
  assert.equal(hero.label.value, 'Pause video');
  hero.scroll(false);
  assert.equal(hero.video.paused, true);

  const phone = await setup({ narrow: true });
  phone.scroll(true);
  assert.equal(phone.source(), '/tall-2.h264');
});

test('a visitor pause survives scrolling away and back', async () => {
  const hero = await setup();
  hero.scroll(true);
  hero.click();
  hero.scroll(false);
  hero.scroll(true);
  assert.equal(hero.video.paused, true);
  assert.equal(hero.label.value, 'Play video');
  hero.click();
  assert.equal(hero.video.paused, false);
});

test('without autoplay nothing is fetched until play is pressed', async () => {
  {
    const hero = await setup({ autoplay: false });
    assert.equal(hero.controls.hidden, false);
    hero.scroll(true);
    assert.equal(hero.source(), undefined);
    assert.equal(hero.video.paused, true);
    hero.click();
    assert.equal(hero.source(), '/wide-2.h264');
    assert.equal(hero.video.paused, false);
  }
});

test('refused autoplay keeps the poster and a play button', async () => {
  const hero = await setup({ refusePlayback: true });
  hero.scroll(true);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(hero.stage.dataset.ready, undefined);
  assert.equal(hero.controls.hidden, false);
  assert.equal(hero.label.value, 'Play video');
});

test('crossing the breakpoint swaps a loaded cut', async () => {
  const hero = await setup();
  hero.narrow.matches = true;
  hero.resize();
  assert.equal(hero.source(), undefined);
  hero.narrow.matches = false;
  hero.scroll(true);
  hero.narrow.matches = true;
  hero.resize();
  assert.equal(hero.source(), '/tall-2.h264');
});

test('autoplay starts silent and the mute button switches sound both ways', async () => {
  const hero = await setup();
  hero.scroll(true);
  assert.equal(hero.video.muted, true);
  assert.equal(hero.muteLabel.value, 'Unmute video');
  hero.clickMute();
  assert.equal(hero.video.muted, false);
  assert.equal(hero.muteLabel.value, 'Mute video');
  assert.equal(hero.stage.dataset.muted, 'false');
  hero.clickMute();
  assert.equal(hero.video.muted, true);
});

test('a visitor who starts the video hears it, and later pauses keep their mute choice', async () => {
  const hero = await setup({ autoplay: false });
  hero.click();
  assert.equal(hero.video.muted, false);
  hero.clickMute();
  hero.click();
  hero.click();
  assert.equal(hero.video.paused, false);
  assert.equal(hero.video.muted, true);
});

test('continues silently when resuming with sound is refused', async () => {
  const hero = await setup({ refusePlayback: 'audible' });
  hero.scroll(true);
  hero.clickMute();
  hero.scroll(false);
  hero.scroll(true);
  await Promise.resolve();
  await Promise.resolve();
  assert.equal(hero.video.paused, false);
  assert.equal(hero.muteLabel.value, 'Unmute video');
});

const pause = (milliseconds: number) =>
  new Promise((resolve) => setTimeout(resolve, milliseconds));

test('a still clock steps down to a smaller file and keeps the position', async () => {
  const hero = await setup();
  hero.scroll(true);
  hero.video.currentTime = 9;
  hero.emit('timeupdate');
  hero.video.currentTime = 9;
  await pause(8);
  assert.notEqual(hero.source(), '/wide-2.h264');
  hero.video.currentTime = 0;
  hero.emit('timeupdate');
  assert.equal(hero.stage.dataset.ready, undefined);
  hero.emit('loadedmetadata');
  assert.ok(hero.video.currentTime >= 9);
  assert.equal(hero.video.paused, false);
  hero.progress();
  assert.equal(hero.stage.dataset.ready, 'true');
  hero.click();
});

test('a playing event without a moving clock keeps the poster', async () => {
  const hero = await setup({ neverLoads: true });
  hero.scroll(true);
  hero.emit('playing');
  assert.equal(hero.stage.dataset.ready, undefined);
  await pause(40);
  assert.equal(hero.source(), '/wide-0.h264');
});

test('a video that never starts keeps stepping down until the smallest file', async () => {
  const hero = await setup({ neverLoads: true });
  hero.scroll(true);
  await pause(60);
  assert.equal(hero.source(), '/wide-0.h264');
  assert.equal(hero.stage.dataset.ready, undefined);
});

test('a moving clock, or a still one while paused or off screen, keeps the file', async () => {
  const hero = await setup({ stallMs: 30 });
  hero.scroll(true);
  for (let step = 0; step < 8; step += 1) {
    await pause(8);
    hero.progress();
  }
  hero.scroll(false);
  await pause(50);
  hero.scroll(true);
  hero.click();
  await pause(50);
  assert.equal(hero.source(), '/wide-2.h264');
});

test('an AV1 failure falls back to H.264', async () => {
  const hero = await setup({ codec: 'av1' });
  hero.scroll(true);
  assert.equal(hero.source(), '/wide-2.av1');
  hero.emit('error');
  assert.equal(hero.source(), '/wide-2.h264');
  assert.equal(hero.video.paused, false);
});

test('a hidden tab pauses playback and resumes when shown', async () => {
  const hero = await setup();
  hero.scroll(true);
  hero.page.hidden = true;
  hero.visibility();
  assert.equal(hero.video.paused, true);
  hero.page.hidden = false;
  hero.visibility();
  assert.equal(hero.video.paused, false);
});

test('autoplay waits for the page, but pressing play does not', async () => {
  let settle: (codec: 'av1') => void = () => {};
  const waiting = new Promise<'av1'>((resolve) => { settle = resolve; });
  const hero = await setup({ codec: waiting });
  hero.scroll(true);
  assert.equal(hero.source(), undefined);
  settle('av1');
  await pause(1);
  assert.equal(hero.source(), '/wide-2.av1');

  const manual = await setup({ autoplay: false, codec: new Promise(() => {}) });
  assert.equal(manual.controls.hidden, false);
  manual.click();
  assert.equal(manual.source(), '/wide-2.h264');
  assert.equal(manual.video.paused, false);
});

test('captions accompany sound until the visitor chooses', async () => {
  const hero = await setup();
  hero.scroll(true);
  assert.equal(hero.video.textTracks[0].mode, 'disabled');
  hero.clickMute();
  assert.equal(hero.video.textTracks[0].mode, 'showing');
  assert.equal(hero.captionState.pressed, 'true');
  hero.clickCaptions();
  assert.equal(hero.video.textTracks[0].mode, 'disabled');
  hero.clickMute();
  hero.clickCaptions();
  assert.equal(hero.video.muted, true);
  assert.equal(hero.video.textTracks[0].mode, 'showing');
});

test('starting, unmuting, or captioning brings the video on screen', async () => {
  const hero = await setup();
  hero.scroll(true);
  assert.equal(hero.revealed.count, 0);
  hero.clickMute();
  assert.equal(hero.revealed.count, 1);
  hero.clickMute();
  assert.equal(hero.revealed.count, 1);
  hero.clickCaptions();
  assert.equal(hero.revealed.count, 2);
  hero.clickCaptions();
  hero.click();
  assert.equal(hero.revealed.count, 2);
  hero.click();
  assert.equal(hero.revealed.count, 3);
});

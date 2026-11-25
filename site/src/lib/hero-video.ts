import type { HeroCodec } from './hero-video-source.ts';

type ObserverClass = new (
  callback: (entries: { isIntersecting: boolean }[]) => void
) => { observe: (target: Element) => void };

type HeroVideoEnvironment = {
  narrow: Pick<MediaQueryList, 'matches' | 'addEventListener'>;
  page: Pick<Document, 'hidden' | 'addEventListener'>;
  Observer: ObserverClass | undefined;
  autoplay: boolean;
  // Resolves once the page has settled; autoplay waits for it, a press does not.
  codec: Promise<HeroCodec>;
  select: (request: { narrow: boolean; codec: HeroCodec; ceiling: number }) => {
    src: string;
    index: number;
  };
  // Brings the whole video on screen; captions sit at its lower edge.
  reveal: () => void;
  stallMs?: number;
};

// The poster is always in the markup. The video is fetched only when it will
// play: automatically once on screen, or after a visitor presses play.
export function initializeHeroVideo(
  stage: HTMLElement,
  { narrow, page, Observer, autoplay, codec: codecWhenReady, select, reveal, stallMs = 3000 }: HeroVideoEnvironment
) {
  const video = stage.querySelector<HTMLVideoElement>('[data-hero-video]');
  const toggle = stage.querySelector<HTMLButtonElement>('[data-hero-video-toggle]');
  const mute = stage.querySelector<HTMLButtonElement>('[data-hero-video-mute]');
  const captions = stage.querySelector<HTMLButtonElement>('[data-hero-video-captions]');
  const controls = stage.querySelector<HTMLElement>('[data-hero-video-controls]');
  if (!video || !toggle || !mute || !captions || !controls) return;

  let codec: HeroCodec = 'h264';
  let started = false;
  // Until the visitor chooses, captions accompany sound.
  let captionChoice: boolean | undefined;
  let wantsPlayback = autoplay;
  let onScreen = !Observer;
  let loaded: { narrow: boolean; index: number } | undefined;
  let ceiling = Number.POSITIVE_INFINITY;
  let resumeAt = 0;
  let lastTime = 0;
  let stallTimer: ReturnType<typeof setTimeout> | undefined;

  const showState = () => {
    const playing = !video.paused;
    controls.hidden = false;
    stage.dataset.playing = String(playing);
    toggle.setAttribute('aria-label', playing ? 'Pause video' : 'Play video');
    stage.dataset.muted = String(video.muted);
    mute.setAttribute('aria-label', video.muted ? 'Unmute video' : 'Mute video');
    const captioned = captionChoice ?? !video.muted;
    for (const track of Array.from(video.textTracks)) {
      track.mode = captioned ? 'showing' : 'disabled';
    }
    captions.setAttribute('aria-pressed', String(captioned));
  };

  const shouldPlay = () => started && wantsPlayback && onScreen && !page.hidden;

  const clearStall = () => {
    clearTimeout(stallTimer);
    stallTimer = undefined;
  };

  const load = () => {
    const { src, index } = select({ narrow: narrow.matches, codec, ceiling });
    // Carry the position over when a smaller or compatible file takes its place.
    resumeAt = loaded ? video.currentTime || resumeAt : 0;
    lastTime = resumeAt;
    loaded = { narrow: narrow.matches, index };
    delete stage.dataset.ready;
    video.setAttribute('src', src);
  };

  // Safari can report "playing" and then sit still for many seconds without a
  // "waiting" event, so only a moving clock counts as playback.
  const watchForStall = () => {
    clearStall();
    stallTimer = setTimeout(() => {
      stallTimer = undefined;
      if (!loaded || loaded.index === 0 || !shouldPlay()) return;
      ceiling = loaded.index - 1;
      load();
      update();
    }, stallMs);
  };

  const update = () => {
    if (!shouldPlay()) {
      clearStall();
      video.pause();
      return;
    }
    if (loaded?.narrow !== narrow.matches) load();
    watchForStall();
    video.play().catch((error: unknown) => {
      const name = (error as Error | undefined)?.name;
      // Replacing the file or pausing interrupts an earlier request to play.
      if (name === 'AbortError') return;
      clearStall();
      // Resuming with sound can need a fresh gesture; continue silently instead.
      if (name === 'NotAllowedError' && !video.muted && shouldPlay()) {
        video.muted = true;
        update();
        return;
      }
      // Muted autoplay can still be refused, for example in Low Power Mode. The
      // poster and play button then remain.
      showState();
    });
  };

  video.addEventListener('loadedmetadata', () => {
    if (resumeAt > 0) video.currentTime = resumeAt;
    resumeAt = 0;
  });
  video.addEventListener('timeupdate', () => {
    // Ignore the jump back to the carried-over position, and pauses.
    if (resumeAt > 0 || video.paused || video.currentTime === lastTime) return;
    lastTime = video.currentTime;
    stage.dataset.ready = 'true';
    if (shouldPlay()) watchForStall();
  });
  video.addEventListener('error', () => {
    clearStall();
    if (codec === 'h264' || !loaded) {
      showState();
      return;
    }
    codec = 'h264';
    load();
    update();
  });
  for (const event of ['play', 'pause', 'volumechange']) {
    video.addEventListener(event, showState);
  }
  toggle.addEventListener('click', () => {
    wantsPlayback = video.paused;
    if (wantsPlayback) {
      started = true;
      onScreen = true;
      // Autoplay has to start silent, but a visitor starting it expects sound.
      if (!stage.dataset.ready) video.muted = false;
      reveal();
    }
    update();
  });
  mute.addEventListener('click', () => {
    video.muted = !video.muted;
    if (!video.muted) reveal();
  });
  captions.addEventListener('click', () => {
    captionChoice = captions.getAttribute('aria-pressed') !== 'true';
    showState();
    if (captionChoice) reveal();
  });
  narrow.addEventListener('change', () => {
    if (loaded) update();
  });
  page.addEventListener('visibilitychange', () => {
    if (loaded || !page.hidden) update();
  });

  // Otherwise the controls appear with playback, not as a flash before it.
  if (!wantsPlayback) showState();
  if (Observer) {
    new Observer((entries) => {
      onScreen = entries.at(-1)?.isIntersecting ?? false;
      update();
    }).observe(stage);
  }
  void codecWhenReady.then((ready) => {
    if (!started) codec = ready;
    started = true;
    update();
  });
}

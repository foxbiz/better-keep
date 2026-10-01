export function initializeCarousel(root: HTMLElement) {
  const rail = root.querySelector<HTMLElement>('.device-gallery');
  const controls = root.querySelector<HTMLElement>('[data-carousel-controls]');
  const previous = root.querySelector<HTMLButtonElement>('[data-carousel-previous]');
  const next = root.querySelector<HTMLButtonElement>('[data-carousel-next]');
  const toggle = root.querySelector<HTMLButtonElement>('[data-carousel-toggle]');
  if (!rail || rail.children.length < 2 || !controls || !previous || !next || !toggle) return;

  const doc = root.ownerDocument;
  const view = doc.defaultView;
  if (!view) return;
  let paused = false;
  let visible = false;
  let timer: number | undefined;

  const move = (direction: number) => {
    const bounds = rail.getBoundingClientRect();
    const maximum = rail.scrollWidth - rail.clientWidth;
    const positions = [...new Set([...rail.children].map((item) =>
      Math.max(0, Math.min(maximum, item.getBoundingClientRect().left - bounds.left + rail.scrollLeft))
    ))];
    const current = positions.reduce((nearest, position, index) =>
      Math.abs(position - rail.scrollLeft) < Math.abs(positions[nearest] - rail.scrollLeft) ? index : nearest, 0);
    rail.scrollTo({
      left: positions[(current + direction + positions.length) % positions.length],
      behavior: 'smooth'
    });
  }

  const update = () => {
    view.clearTimeout(timer);
    toggle.textContent = paused ? 'Play' : 'Pause';
    toggle.setAttribute('aria-label', `${paused ? 'Start' : 'Pause'} automatic scrolling`);
    if (!paused && visible && !doc.hidden) {
      timer = view.setTimeout(() => { move(1); update(); }, 6000);
    }
  }

  const navigate = (direction: number) => {
    move(direction);
    update();
  }

  previous.addEventListener('click', () => navigate(-1));
  next.addEventListener('click', () => navigate(1));
  toggle.addEventListener('click', () => { paused = !paused; update(); });
  rail.addEventListener('keydown', (event) => {
    if (event.target !== rail) return;
    const direction = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : undefined;
    if (direction === undefined) return;
    event.preventDefault();
    navigate(direction);
  });
  doc.addEventListener('visibilitychange', update);
  new view.IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting && entry.intersectionRatio >= 0.25;
    update();
  }, { threshold: 0.25 }).observe(rail);
  controls.hidden = false;
  update();
}

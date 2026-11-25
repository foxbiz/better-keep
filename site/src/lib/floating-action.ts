type ObserverClass = new (
  callback: (entries: { target: Element; isIntersecting: boolean }[]) => void
) => { observe: (target: Element) => void };

// The floating button repeats the page's own download actions, so it stays out
// of the way while any of them is on screen.
export function hideWhileVisible(
  action: HTMLElement | null,
  targets: Iterable<Element>,
  Observer: ObserverClass | undefined = globalThis.IntersectionObserver
) {
  const observed = [...targets];
  if (!action || observed.length === 0) return;
  if (!Observer) {
    action.dataset.hidden = 'false';
    return;
  }

  const visible = new Set<Element>();
  const observer = new Observer((entries) => {
    for (const { target, isIntersecting } of entries) {
      if (isIntersecting) visible.add(target);
      else visible.delete(target);
    }
    action.dataset.hidden = String(visible.size > 0);
  });
  for (const target of observed) observer.observe(target);
}

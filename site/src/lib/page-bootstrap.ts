type Analytics = ((name: string, options: {
  props: { path: string; placement: string };
}) => void) & { q?: IArguments[] };

function stripQuery(browser: Pick<Window, 'location' | 'history'>) {
  if (browser.location.search) {
    browser.history.replaceState(null, '', browser.location.pathname + browser.location.hash);
  }
}

function initializeAnalytics(browser: Window & { plausible?: Analytics }, doc: Document) {
  browser.plausible ||= function () {
    const plausible = browser.plausible!;
    (plausible.q ||= []).push(arguments);
  };
  doc.addEventListener('click', (event) => {
    const target = event.target instanceof Element
      ? event.target.closest('[data-analytics]')
      : null;
    const name = target?.getAttribute('data-analytics');
    if (name && target) {
      browser.plausible!(name, {
        props: {
          path: browser.location.pathname,
          placement: target.textContent?.trim() || 'link'
        }
      });
    }
  });
}

function redirectLegacyStandalone(browser: Window & {
  navigator: Navigator & { standalone?: boolean };
}) {
  const legacyStandalone = browser.matchMedia('(display-mode: standalone)').matches ||
    browser.navigator.standalone === true;
  if (legacyStandalone && browser.location.pathname === '/') {
    browser.location.replace('/app/');
  }
}

// These must run synchronously in the head; serialize their compiled functions.
export const pageBootstrap = {
  query: `(${stripQuery.toString()})(window);`,
  analytics: `(${initializeAnalytics.toString()})(window, document);`,
  legacy: `(${redirectLegacyStandalone.toString()})(window);`
};

import { detectStorePlatform } from './store-platform.ts';

type NavigatorHints = {
  userAgent: string;
  platform: string;
  maxTouchPoints: number;
  userAgentData?: { platform?: string };
};

export function configureNativeAppAction(
  link: HTMLAnchorElement | null,
  navigator: NavigatorHints
) {
  const label = link?.querySelector<HTMLElement>('[data-app-action-label]');
  if (!link || !label) return;

  const hints = {
    userAgent: navigator.userAgent,
    platform: navigator.platform,
    userAgentDataPlatform: navigator.userAgentData?.platform
  };
  const store = detectStorePlatform(hints);
  const isIOS = /iphone|ipad|ipod|\bios\b/i.test(
    `${hints.userAgent} ${hints.platform} ${hints.userAgentDataPlatform || ''}`
  ) || (store === 'apple' && navigator.maxTouchPoints > 1);

  if (store === 'google' && link.dataset.playStoreUrl) {
    const playStoreUrl = new URL(link.dataset.playStoreUrl);
    const packageId = playStoreUrl.searchParams.get('id');
    if (!packageId) return;
    // Android currently registers the auth host; a link without a transaction
    // opens the app without starting an OAuth operation.
    link.href = `intent://auth#Intent;scheme=betterkeep;package=${packageId};S.browser_fallback_url=${encodeURIComponent(playStoreUrl.href)};end`;
  } else if (store === 'apple' && isIOS) {
    link.href = 'betterkeep://';
  } else {
    return;
  }

  label.textContent = 'Open app';
  link.dataset.analytics = 'open_native_app';
}

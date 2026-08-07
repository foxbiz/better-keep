export const STORE_PLATFORMS = Object.freeze([
  'apple',
  'google',
  'microsoft'
]);

export function detectStorePlatform({
  userAgentDataPlatform = '',
  userAgent = '',
  platform = ''
} = {}) {
  const classify = (value) => {
    const normalized = String(value || '').toLowerCase();
    if (!normalized) return undefined;
    if (normalized.includes('chrome os') || normalized.includes('cros')) {
      return null;
    }
    if (normalized.includes('android')) return 'google';
    if (
      normalized.includes('iphone') ||
      normalized.includes('ipad') ||
      normalized.includes('ipod') ||
      normalized === 'ios' ||
      normalized.includes('macintosh') ||
      normalized.includes('macintel') ||
      normalized.includes('mac os') ||
      normalized.includes('macos')
    ) {
      return 'apple';
    }
    if (
      normalized.includes('windows') ||
      normalized.includes('win32') ||
      normalized.includes('win64')
    ) {
      return 'microsoft';
    }
    if (normalized.includes('linux')) return null;
    return undefined;
  };

  const clientHintSelection = classify(userAgentDataPlatform);
  if (clientHintSelection !== undefined) return clientHintSelection;

  return classify(`${userAgent} ${platform}`) ?? null;
}

export function createStorePlatformBootstrap() {
  return `document.documentElement.dataset.storePlatform = (${detectStorePlatform.toString()})({
    userAgentDataPlatform: navigator.userAgentData && navigator.userAgentData.platform,
    userAgent: navigator.userAgent,
    platform: navigator.platform
  }) || 'none';`;
}

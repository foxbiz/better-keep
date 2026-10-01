export const STORE_PLATFORMS = Object.freeze([
  'apple',
  'google',
  'microsoft'
] as const);

export type StorePlatform = typeof STORE_PLATFORMS[number];
type PlatformHints = {
  userAgentDataPlatform?: string;
  userAgent?: string;
  platform?: string;
};

export function detectStorePlatform({
  userAgentDataPlatform = '',
  userAgent = '',
  platform = ''
}: PlatformHints = {}): StorePlatform | null {
  const classify = (value: string): StorePlatform | null | undefined => {
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

function applyStorePlatform(doc: Pick<Document, 'documentElement'>, nav: {
  userAgentData?: { platform?: string };
  userAgent: string;
  platform: string;
}, detect: typeof detectStorePlatform) {
  doc.documentElement.dataset.storePlatform = detect({
    userAgentDataPlatform: nav.userAgentData?.platform,
    userAgent: nav.userAgent,
    platform: nav.platform
  }) || 'none';
}

export function createStorePlatformBootstrap() {
  return `(${applyStorePlatform.toString()})(document, navigator, ${detectStorePlatform.toString()});`;
}

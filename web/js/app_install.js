/**
 * App Installation Manager for Better Keep
 * Handles PWA installation prompts, native app redirects, and theme color updates
 */
(function () {
  'use strict';

  const STORAGE_KEYS = {
    PROMPT_SHOWN: 'bk_install_prompt_shown',
    PROMPT_DISMISSED: 'bk_install_prompt_dismissed',
    PWA_INSTALLED: 'bk_pwa_installed'
  };

  const APP_URLS = {
    android: 'https://play.google.com/store/apps/details?id=io.foxbiz.better_keep',
    windows: 'https://apps.microsoft.com/detail/9PHT5C6WK6Q1',
    deepLink: 'betterkeep://'
  };

  // Store the deferred prompt for later use
  let deferredPrompt = null;

  /**
   * Update the theme color meta tag for the browser
   * This affects the browser's address bar color on mobile
   */
  function updateThemeColor(color) {
    let metaThemeColor = document.querySelector('meta[name="theme-color"]');
    if (!metaThemeColor) {
      metaThemeColor = document.createElement('meta');
      metaThemeColor.name = 'theme-color';
      document.head.appendChild(metaThemeColor);
    }
    metaThemeColor.content = color;

    // Also update apple-mobile-web-app-status-bar-style for iOS
    let metaAppleStatusBar = document.querySelector('meta[name="apple-mobile-web-app-status-bar-style"]');
    if (!metaAppleStatusBar) {
      metaAppleStatusBar = document.createElement('meta');
      metaAppleStatusBar.name = 'apple-mobile-web-app-status-bar-style';
      document.head.appendChild(metaAppleStatusBar);
    }
    // For iOS, use 'black-translucent' for dark themes, 'default' for light
    const isLight = isLightColor(color);
    metaAppleStatusBar.content = isLight ? 'default' : 'black-translucent';
  }

  /**
   * Check if a color is light or dark
   */
  function isLightColor(hexColor) {
    const hex = hexColor.replace('#', '');
    const r = parseInt(hex.substr(0, 2), 16);
    const g = parseInt(hex.substr(2, 2), 16);
    const b = parseInt(hex.substr(4, 2), 16);
    // Calculate luminance
    const luminance = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
    return luminance > 0.5;
  }

  /**
   * Update the background color of the body (for loading states)
   */
  function updateBackgroundColor(color) {
    document.documentElement.style.backgroundColor = color;
    document.body.style.backgroundColor = color;
  }

  /**
   * Detect user's platform
   */
  function getPlatform() {
    const ua = navigator.userAgent.toLowerCase();
    const platform = navigator.platform?.toLowerCase() || '';

    if (/iphone|ipad|ipod/.test(ua) || (platform === 'macintel' && navigator.maxTouchPoints > 1)) {
      return 'ios';
    }
    if (/android/.test(ua)) {
      return 'android';
    }
    if (/win/.test(platform) || /windows/.test(ua)) {
      return 'windows';
    }
    if (/mac/.test(platform)) {
      return 'macos';
    }
    if (/linux/.test(platform)) {
      return 'linux';
    }
    return 'unknown';
  }

  /**
   * Check if running as installed PWA
   */
  function isPWAInstalled() {
    // Check display mode
    if (window.matchMedia('(display-mode: standalone)').matches) {
      return true;
    }
    // Check iOS standalone mode
    if (window.navigator.standalone === true) {
      return true;
    }
    // Check stored flag
    if (localStorage.getItem(STORAGE_KEYS.PWA_INSTALLED) === 'true') {
      return true;
    }
    return false;
  }

  /**
   * Check if prompt was already shown to user
   */
  function wasPromptShown() {
    return localStorage.getItem(STORAGE_KEYS.PROMPT_SHOWN) === 'true';
  }

  /**
   * Mark prompt as shown
   */
  function markPromptShown() {
    localStorage.setItem(STORAGE_KEYS.PROMPT_SHOWN, 'true');
  }

  /**
   * Mark prompt as dismissed
   */
  function markPromptDismissed() {
    localStorage.setItem(STORAGE_KEYS.PROMPT_DISMISSED, 'true');
  }

  /**
   * Check if prompt was dismissed
   */
  function wasPromptDismissed() {
    return localStorage.getItem(STORAGE_KEYS.PROMPT_DISMISSED) === 'true';
  }

  /**
   * Try to open the native app
   */
  function tryOpenNativeApp() {
    const start = Date.now();
    const timeout = 1500;

    // Try to open with custom scheme
    window.location.href = APP_URLS.deepLink;

    // If we're still here after timeout, app is not installed
    setTimeout(() => {
      if (Date.now() - start < timeout + 100) {
        // App didn't open, we're still on the page
        window.dispatchEvent(new CustomEvent('bk-native-app-not-found'));
      }
    }, timeout);
  }

  /**
   * Get the appropriate store URL for the platform
   */
  function getStoreUrl() {
    const platform = getPlatform();
    switch (platform) {
      case 'android':
        return APP_URLS.android;
      case 'windows':
        return APP_URLS.windows;
      default:
        return null;
    }
  }

  /**
   * Trigger PWA installation (for browsers that support it)
   */
  async function triggerPWAInstall() {
    if (!deferredPrompt) {
      return { success: false, reason: 'no-prompt' };
    }

    try {
      deferredPrompt.prompt();
      const result = await deferredPrompt.userChoice;
      deferredPrompt = null;

      if (result.outcome === 'accepted') {
        localStorage.setItem(STORAGE_KEYS.PWA_INSTALLED, 'true');
        return { success: true, outcome: 'accepted' };
      }
      return { success: false, outcome: 'dismissed' };
    } catch (e) {
      console.error('PWA install error:', e);
      return { success: false, reason: 'error' };
    }
  }

  /**
   * Show iOS PWA install instructions
   */
  function showIOSInstallInstructions() {
    window.dispatchEvent(new CustomEvent('bk-show-ios-pwa-instructions'));
  }

  /**
   * Get installation status and options for Flutter
   */
  function getInstallInfo() {
    const platform = getPlatform();
    const pwaInstalled = isPWAInstalled();
    const canInstallPWA = deferredPrompt !== null;
    const storeUrl = getStoreUrl();
    const promptShown = wasPromptShown();
    const promptDismissed = wasPromptDismissed();

    return {
      platform,
      pwaInstalled,
      canInstallPWA,
      storeUrl,
      promptShown,
      promptDismissed,
      isIOS: platform === 'ios',
      isAndroid: platform === 'android',
      isWindows: platform === 'windows',
      isMacOS: platform === 'macos',
      hasNativeApp: platform === 'android' || platform === 'windows',
      iosAppComingSoon: platform === 'ios'
    };
  }

  // Listen for beforeinstallprompt event
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferredPrompt = e;
    window.dispatchEvent(new CustomEvent('bk-pwa-installable'));
  });

  // Listen for successful PWA installation
  window.addEventListener('appinstalled', () => {
    localStorage.setItem(STORAGE_KEYS.PWA_INSTALLED, 'true');
    deferredPrompt = null;
    window.dispatchEvent(new CustomEvent('bk-pwa-installed'));
  });

  // Expose API to Flutter
  window.BetterKeepInstall = {
    getPlatform,
    isPWAInstalled,
    wasPromptShown,
    markPromptShown,
    markPromptDismissed,
    wasPromptDismissed,
    tryOpenNativeApp,
    getStoreUrl,
    triggerPWAInstall,
    showIOSInstallInstructions,
    getInstallInfo,
    updateThemeColor,
    updateBackgroundColor,
    APP_URLS
  };

})();

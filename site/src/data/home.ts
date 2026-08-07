import type { IconName } from './icons';

export type Feature = {
  title: string;
  description: string;
  icon: IconName;
  href: string;
  number: string;
};

export type ScreenshotId = '1' | '2' | '3' | '4' | '5' | '6' | '7';

export type ScreenshotItem = {
  id: ScreenshotId;
  src: string;
  optimizedSrc: string;
  caption: string;
  alt: string;
  label: string;
};

export const primaryFeatures: readonly Feature[] = [
  {
    number: '01',
    title: 'Rich-text editing',
    description:
      'Use headings, lists, checklists, links, images, sketches, and emphasis without turning a quick note into a project.',
    icon: 'TextCursorInput',
    href: '/rich-text-notes'
  },
  {
    number: '02',
    title: 'Private encrypted sync',
    description:
      'Keep notes locally and optionally synchronize protected content between devices you approve.',
    icon: 'ShieldCheck',
    href: '/private-encrypted-notes'
  },
  {
    number: '03',
    title: 'Works fully offline',
    description:
      'Create, edit, search, pin, label, and organize without waiting for a network connection.',
    icon: 'CloudOff',
    href: '/offline-notes-app'
  },
  {
    number: '04',
    title: 'Every screen you use',
    description:
      'Use the same focused workflow on Android, iOS, macOS, Windows, and the web.',
    icon: 'MonitorSmartphone',
    href: '/cross-platform-notes'
  },
  {
    number: '05',
    title: 'Structure without friction',
    description:
      'Combine labels, colors, folders, pinned views, and fast search as your collection grows.',
    icon: 'Folders',
    href: '/rich-text-notes'
  },
  {
    number: '06',
    title: 'Voice notes, made searchable',
    description:
      'Attach recordings and use on-device transcription on supported native devices.',
    icon: 'AudioWaveform',
    href: '/voice-notes-transcription'
  }
] as const;

export const screenshots: readonly ScreenshotItem[] = [
  {
    id: '1',
    src: '/media/screenshots/1.png',
    optimizedSrc: '/media/screenshots/1-480.webp',
    label: 'Sign in',
    caption: 'Flexible sign-in options',
    alt: 'Better Keep sign-in screen with Google, Apple, Facebook, GitHub, and email options'
  },
  {
    id: '2',
    src: '/media/screenshots/2.png',
    optimizedSrc: '/media/screenshots/2-480.webp',
    label: 'Organize',
    caption: 'Notes, labels, reminders, and rich previews in one calm home',
    alt: 'Better Keep notes home with rich-text cards, checklists, labels, colors, images, drawings, and reminders'
  },
  {
    id: '3',
    src: '/media/screenshots/3.png',
    optimizedSrc: '/media/screenshots/3-480.webp',
    label: 'Account',
    caption: 'Subscription and connected accounts',
    alt: 'Better Keep account screen showing subscription details and connected sign-in providers'
  },
  {
    id: '4',
    src: '/media/screenshots/4.png',
    optimizedSrc: '/media/screenshots/4-480.webp',
    label: 'Protect',
    caption: 'Encrypted sync across approved devices',
    alt: 'Better Keep security screen showing encrypted notes, recovery controls, and approved devices'
  },
  {
    id: '5',
    src: '/media/screenshots/5.png',
    optimizedSrc: '/media/screenshots/5-480.webp',
    label: 'Write',
    caption: 'Rich text, images, and sketches',
    alt: 'Better Keep rich-text editor showing a formatted travel note with an image and a sketch'
  },
  {
    id: '6',
    src: '/media/screenshots/6.png',
    optimizedSrc: '/media/screenshots/6-480.webp',
    label: 'Capture',
    caption: 'Voice notes and audio capture',
    alt: 'Better Keep editor showing formatted meeting notes with an attached voice recording'
  },
  {
    id: '7',
    src: '/media/screenshots/7.png',
    optimizedSrc: '/media/screenshots/7-480.webp',
    label: 'Personalize',
    caption: 'Themes and supported languages',
    alt: 'Better Keep settings with dark theme controls and supported language choices'
  }
] as const;

export const screenshotById = Object.freeze(
  Object.fromEntries(screenshots.map((screenshot) => [screenshot.id, screenshot]))
) as Readonly<Record<ScreenshotId, ScreenshotItem>>;

export const heroScreenshots = [
  screenshotById['5'],
  screenshotById['2'],
  screenshotById['6']
] as const;

export const securityScreenshot = screenshotById['4'];

export const galleryScreenshots = [
  screenshotById['7'],
  screenshotById['3'],
  screenshotById['1']
] as const;

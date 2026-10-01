import screenshotCatalog from './screenshots.json';
import { screenshotPreviewWidths } from '../lib/screenshot-previews.ts';
import type { IconName } from './icons';

export type Feature = {
  title: string;
  description: string;
  icon: IconName;
  href: string;
  number: string;
};

export type ScreenshotId = string;

export type ScreenshotItem = {
  id: ScreenshotId;
  src: string;
  optimizedSrc: string;
  optimizedSrcset: string;
  width: number;
  height: number;
  platform: string;
  feature: string;
  caption: string;
  alt: string;
  label: string;
};

export const primaryFeatures: readonly Feature[] = [
  {
    number: '01',
    title: 'Rich-text editing',
    description:
      'Add headings, lists, checklists, links, images, and sketches to your notes.',
    icon: 'TextCursorInput',
    href: '/rich-text-notes'
  },
  {
    number: '02',
    title: 'Private encrypted sync',
    description:
      'Keep notes on your device for free. Pro adds encrypted sync between approved devices.',
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
    title: 'Phone, computer, and web',
    description:
      'Use Better Keep on Android, iOS, macOS, Windows, and the web.',
    icon: 'MonitorSmartphone',
    href: '/cross-platform-notes'
  },
  {
    number: '05',
    title: 'Find the note you need',
    description:
      'Group notes with labels, colors, and folders. Pin favorites or search your collection.',
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

export const screenshots: readonly ScreenshotItem[] = screenshotCatalog.map((item) => ({
  ...item,
  src: `/media/screenshots/${item.id}.png`,
  optimizedSrc: `/media/screenshots/${item.id}-480.webp`,
  optimizedSrcset: screenshotPreviewWidths(item)
    .map((width) => `/media/screenshots/${item.id}-${width}.webp ${width}w`)
    .join(', ')
}));

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
  screenshotById['5'],
  screenshotById['table-ios'],
  screenshotById['checklist-ios'],
  screenshotById['6'],
  screenshotById['2'],
  screenshotById['4'],
  screenshotById['7'],
  screenshotById['3']
] as const;

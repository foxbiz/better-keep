import screenshotCatalog from './screenshots.json';
import { screenshotPreviewWidths } from '../lib/screenshot-previews.ts';
import type { IconName } from './icons';

export type Feature = {
  title: string;
  description: string;
  icon: IconName;
  href: string;
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
    title: 'Rich-text editing',
    description:
      'Add headings, lists, checklists, tables, links, photos, and sketches.',
    icon: 'TextCursorInput',
    href: '/rich-text-notes'
  },
  {
    title: 'Works fully offline',
    description:
      'Create, edit, and search your notes without a network connection.',
    icon: 'CloudOff',
    href: '/offline-notes-app'
  },
  {
    title: 'Voice notes, made searchable',
    description:
      'Attach recordings and transcribe them on supported native devices.',
    icon: 'AudioWaveform',
    href: '/voice-notes-transcription'
  },
  {
    title: 'Easy to organize',
    description:
      'Use labels, colors, folders, and pins to keep notes where you expect them.',
    icon: 'Folders',
    href: '/rich-text-notes'
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

export const syncScreenshot = screenshotById['external-sync-ios'];

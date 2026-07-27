import type { IconName } from './icons';

export type Feature = {
  title: string;
  description: string;
  icon: IconName;
  tone: 'yellow' | 'blue' | 'green' | 'orange' | 'violet' | 'teal';
  href: string;
};

export type ScreenshotItem = {
  src: string;
  optimizedSrc: string;
  caption: string;
  alt: string;
};

export const primaryFeatures: readonly Feature[] = [
  {
    title: 'Rich-text editing',
    description:
      'Use headings, lists, checklists, emphasis, links, images, sketches, and more without turning every note into a workspace.',
    icon: 'TextCursorInput',
    tone: 'yellow',
    href: '/rich-text-notes'
  },
  {
    title: 'Private encrypted sync',
    description:
      'Keep notes locally and optionally synchronize protected note content and attachments between approved devices.',
    icon: 'ShieldCheck',
    tone: 'blue',
    href: '/private-encrypted-notes'
  },
  {
    title: 'Works offline',
    description:
      'Create, edit, search, pin, label, and organize notes without waiting for a network connection.',
    icon: 'CloudOff',
    tone: 'green',
    href: '/offline-notes-app'
  },
  {
    title: 'Cross-platform access',
    description:
      'Use the same focused notes workflow on Android, iOS, macOS, Windows, and the web.',
    icon: 'MonitorSmartphone',
    tone: 'orange',
    href: '/cross-platform-notes'
  },
  {
    title: 'Labels, folders, and search',
    description:
      'Combine labels, colors, folders, pinned views, and fast search to keep growing collections manageable.',
    icon: 'Folders',
    tone: 'violet',
    href: '/rich-text-notes'
  },
  {
    title: 'Voice notes and transcription',
    description:
      'Attach recordings and, on supported native devices, turn speech into searchable text using on-device transcription.',
    icon: 'AudioWaveform',
    tone: 'teal',
    href: '/voice-notes-transcription'
  }
] as const;

export const screenshots: readonly ScreenshotItem[] = [
  {
    src: '/media/screenshots/2.png',
    optimizedSrc: '/media/screenshots/2-480.webp',
    caption: 'Organize notes your way',
    alt: 'Better Keep notes home with rich-text cards, checklists, labels, colors, images, drawings, and reminders'
  },
  {
    src: '/media/screenshots/5.png',
    optimizedSrc: '/media/screenshots/5-480.webp',
    caption: 'Rich text, images, and sketches',
    alt: 'Better Keep rich-text editor showing a formatted travel note with an image and a sketch'
  },
  {
    src: '/media/screenshots/6.png',
    optimizedSrc: '/media/screenshots/6-480.webp',
    caption: 'Voice notes and audio capture',
    alt: 'Better Keep editor showing formatted meeting notes with an attached voice recording'
  },
  {
    src: '/media/screenshots/4.png',
    optimizedSrc: '/media/screenshots/4-480.webp',
    caption: 'Encrypted sync across approved devices',
    alt: 'Better Keep security screen showing encrypted notes, recovery controls, and approved devices'
  },
  {
    src: '/media/screenshots/7.png',
    optimizedSrc: '/media/screenshots/7-480.webp',
    caption: 'Themes and supported languages',
    alt: 'Better Keep settings with dark theme controls and supported language choices'
  },
  {
    src: '/media/screenshots/3.png',
    optimizedSrc: '/media/screenshots/3-480.webp',
    caption: 'Subscription and connected accounts',
    alt: 'Better Keep account screen showing subscription details and connected sign-in providers'
  },
  {
    src: '/media/screenshots/1.png',
    optimizedSrc: '/media/screenshots/1-480.webp',
    caption: 'Flexible sign-in options',
    alt: 'Better Keep sign-in screen with Google, Apple, Facebook, GitHub, and email options'
  }
] as const;

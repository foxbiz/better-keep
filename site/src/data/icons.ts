import {
  Apple,
  ArrowRight,
  AudioWaveform,
  CirclePlay,
  CloudOff,
  CodeXml,
  Folders,
  GitFork,
  Globe,
  Heart,
  Import,
  Menu,
  MonitorDown,
  MonitorSmartphone,
  ShieldCheck,
  Smartphone,
  Star,
  TextCursorInput,
  X
} from '@lucide/astro';

export const iconComponents = {
  Apple,
  ArrowRight,
  AudioWaveform,
  CirclePlay,
  CloudOff,
  CodeXml,
  Folders,
  GitFork,
  Globe,
  Heart,
  Import,
  Menu,
  MonitorDown,
  MonitorSmartphone,
  ShieldCheck,
  Smartphone,
  Star,
  TextCursorInput,
  X
} as const;

export type IconName = keyof typeof iconComponents;

export const iconNames = Object.freeze(
  Object.keys(iconComponents) as IconName[]
);

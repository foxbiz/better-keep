import {
  Apple,
  ArrowRight,
  AudioWaveform,
  Captions,
  CirclePlay,
  CloudOff,
  CodeXml,
  Folders,
  GitFork,
  Globe,
  Heart,
  Import,
  KeyRound,
  Menu,
  MonitorDown,
  MonitorSmartphone,
  Pause,
  Play,
  ShieldCheck,
  Smartphone,
  Star,
  TextCursorInput,
  Users,
  Volume2,
  VolumeX,
  X
} from '@lucide/astro';

export const iconComponents = {
  Apple,
  ArrowRight,
  AudioWaveform,
  Captions,
  CirclePlay,
  CloudOff,
  CodeXml,
  Folders,
  GitFork,
  Globe,
  Heart,
  Import,
  KeyRound,
  Menu,
  MonitorDown,
  MonitorSmartphone,
  Pause,
  Play,
  ShieldCheck,
  Smartphone,
  Star,
  TextCursorInput,
  Users,
  Volume2,
  VolumeX,
  X
} as const;

export type IconName = keyof typeof iconComponents;

export const iconNames = Object.freeze(
  Object.keys(iconComponents) as IconName[]
);

import catalog from '../data/hero-video.json' with { type: 'json' };

export type HeroCodec = 'av1' | 'h264';
export type HeroLayout = keyof typeof catalog;
export type HeroRendition = {
  width: number;
  height: number;
  kbps: { av1: number; h264?: number };
};
// Chromium exposes these; other browsers leave them undefined.
export type HeroNetwork = {
  saveData?: boolean;
  effectiveType?: string;
  downlink?: number;
};

export const heroVideoCatalog: Record<
  HeroLayout,
  { posterWidths: number[]; renditions: HeroRendition[] }
> = catalog;

export function heroVideoPath(layout: HeroLayout, { width }: HeroRendition, codec: HeroCodec) {
  return `/media/video/hero-${layout}-${width}.${codec}.mp4`;
}

// Resolves with nothing when the promise takes too long.
export async function settleWithin<Value>(
  promise: Promise<Value> | undefined,
  timeoutMs: number
) {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([
      promise,
      new Promise<undefined>((resolve) => {
        timer = setTimeout(() => resolve(undefined), timeoutMs);
      })
    ]);
  } finally {
    clearTimeout(timer);
  }
}

const av1ContentType = 'video/mp4; codecs="av01.0.08M.08"';

// AV1 files are up to half the size, but decoding it in software costs battery and
// can drop frames, so it is used only where the device reports it is efficient.
export async function pickHeroCodec(
  { width, height, kbps }: HeroRendition,
  capabilities: Pick<MediaCapabilities, 'decodingInfo'> | undefined,
  timeoutMs = 1000
): Promise<HeroCodec> {
  try {
    const probe = capabilities?.decodingInfo({
      type: 'file',
      video: {
        contentType: av1ContentType,
        width,
        height,
        bitrate: kbps.av1 * 1000,
        framerate: 30
      }
    });
    const info = await settleWithin(probe, timeoutMs);
    return info?.supported && info.smooth && info.powerEfficient ? 'av1' : 'h264';
  } catch {
    return 'h264';
  }
}

export function allowsHeroAutoplay(reducedMotion: boolean, network: HeroNetwork | undefined) {
  return (
    !reducedMotion &&
    network?.saveData !== true &&
    !/(?:^|-)2g$/.test(network?.effectiveType ?? '')
  );
}

type HeroSelection = {
  layout: HeroLayout;
  codec: HeroCodec;
  cssWidth: number;
  pixelRatio: number;
  network: HeroNetwork | undefined;
  ceiling: number;
};

// Returns the index of the smallest rendition that looks sharp at this size,
// lowered to what the codec, connection, and any earlier stall allow. The
// largest sizes exist only in AV1, because H.264 is too heavy there.
export function chooseHeroRendition({
  layout,
  codec,
  cssWidth,
  pixelRatio,
  network,
  ceiling
}: HeroSelection) {
  const { renditions } = heroVideoCatalog[layout];
  // Beyond 2x, and within 20% of it, extra pixels are not visible in motion.
  const wantedWidth = cssWidth * Math.min(pixelRatio, 2) * 0.8;
  const sharp = renditions.findIndex(({ width }) => width >= wantedWidth);
  let index = Math.min(sharp === -1 ? renditions.length - 1 : sharp, ceiling);

  while (index > 0 && renditions[index].kbps[codec] === undefined) index -= 1;
  if (network?.saveData || /2g|3g/.test(network?.effectiveType ?? '')) index = 0;
  if (network?.downlink) {
    const budget = network.downlink * 1000 * 0.6;
    while (index > 0 && (renditions[index].kbps[codec] ?? 0) > budget) index -= 1;
  }
  return Math.max(index, 0);
}

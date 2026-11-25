import assert from 'node:assert/strict';
import test from 'node:test';
import {
  allowsHeroAutoplay,
  chooseHeroRendition,
  heroVideoCatalog,
  heroVideoPath,
  pickHeroCodec,
  type HeroLayout,
  type HeroNetwork
} from '../src/lib/hero-video-source.ts';

function width(
  layout: HeroLayout,
  cssWidth: number,
  pixelRatio: number,
  network?: HeroNetwork,
  ceiling = Infinity,
  codec: 'av1' | 'h264' = 'av1'
) {
  const index = chooseHeroRendition({
    layout, cssWidth, pixelRatio, network, ceiling, codec
  });
  return heroVideoCatalog[layout].renditions[index].width;
}

test('matches the file to the screen without exceeding visible detail', () => {
  assert.equal(width('wide', 1120, 2), 1920);
  assert.equal(width('wide', 1120, 2, undefined, Infinity, 'h264'), 1280);
  assert.equal(width('wide', 1120, 1), 1280);
  assert.equal(width('wide', 736, 2), 1280);
  assert.equal(width('wide', 700, 1), 854);
  assert.equal(width('tall', 340, 3), 720);
  assert.equal(width('tall', 307, 3), 540);
  assert.equal(width('tall', 262, 1), 360);
});

test('slow connections get smaller files', () => {
  assert.equal(width('wide', 1120, 2, { effectiveType: '4g', downlink: 10 }), 1920);
  assert.equal(width('wide', 1120, 2, { effectiveType: '4g', downlink: 0.7 }), 1280);
  assert.equal(width('wide', 1120, 2, { effectiveType: '4g', downlink: 0.4 }), 854);
  assert.equal(width('tall', 340, 3, { effectiveType: '3g', downlink: 1.4 }), 360);
  assert.equal(width('tall', 340, 3, { saveData: true, downlink: 10 }), 360);
});

test('an earlier stall caps the size', () => {
  assert.equal(width('wide', 1120, 2, undefined, 1), 1280);
  assert.equal(width('wide', 1120, 2, undefined, 0), 854);
});

test('autoplay is skipped for reduced motion, data saver, and 2G', () => {
  assert.equal(allowsHeroAutoplay(false, undefined), true);
  assert.equal(allowsHeroAutoplay(false, { effectiveType: '3g' }), true);
  assert.equal(allowsHeroAutoplay(true, undefined), false);
  assert.equal(allowsHeroAutoplay(false, { saveData: true }), false);
  assert.equal(allowsHeroAutoplay(false, { effectiveType: '2g' }), false);
  assert.equal(allowsHeroAutoplay(false, { effectiveType: 'slow-2g' }), false);
});

test('AV1 is used only with efficient decoding and otherwise falls back', async () => {
  const [rendition] = heroVideoCatalog.wide.renditions;
  const decoder = (info: { supported: boolean; smooth: boolean; powerEfficient: boolean }) => ({
    decodingInfo: async () => info as MediaCapabilitiesDecodingInfo
  });
  assert.equal(
    await pickHeroCodec(rendition, decoder({ supported: true, smooth: true, powerEfficient: true })),
    'av1'
  );
  assert.equal(
    await pickHeroCodec(rendition, decoder({ supported: true, smooth: true, powerEfficient: false })),
    'h264'
  );
  assert.equal(
    await pickHeroCodec(rendition, { decodingInfo: async () => { throw new TypeError('bad'); } }),
    'h264'
  );
  assert.equal(await pickHeroCodec(rendition, undefined), 'h264');
  assert.equal(
    await pickHeroCodec(rendition, { decodingInfo: () => new Promise(() => {}) }, 5),
    'h264'
  );
  assert.equal(heroVideoPath('wide', rendition, 'av1'), '/media/video/hero-wide-854.av1.mp4');
});

export function screenshotPreviewWidths({ platform }: { platform: string }): readonly number[] {
  return platform === 'desktop' ? [480, 960, 1440] : [480, 960];
}

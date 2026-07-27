import type { APIRoute } from 'astro';
import { pages } from '../data/pages';
import { product } from '../data/product';

const escapeXml = (value: string) =>
  value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

export const GET: APIRoute = () => {
  const items = pages
    .map(
      (page) => `
    <item>
      <title>${escapeXml(page.title)}</title>
      <link>${product.siteUrl}/${page.slug}</link>
      <guid>${product.siteUrl}/${page.slug}</guid>
      <pubDate>${new Date(`${product.updatedAt}T00:00:00Z`).toUTCString()}</pubDate>
      <description>${escapeXml(page.description)}</description>
    </item>`
    )
    .join('');

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<rss version="2.0"><channel>` +
      `<title>Better Keep guides</title>` +
      `<link>${product.siteUrl}/</link>` +
      `<description>${escapeXml(product.positioning)}</description>` +
      `${items}</channel></rss>\n`,
    {
      headers: {
        'Content-Type': 'application/rss+xml; charset=utf-8'
      }
    }
  );
};

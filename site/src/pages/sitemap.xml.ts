import type { APIRoute } from 'astro';
import { pages } from '../data/pages';
import { product } from '../data/product';

const staticPaths = [
  '',
  ...pages.map((page) => page.slug),
  'pricing',
  'contact',
  'privacy',
  'terms',
  'cancellation-refund',
  'delete-user'
];

export const GET: APIRoute = () => {
  const entries = staticPaths
    .map((path) => {
      const url = path ? `${product.siteUrl}/${path}` : `${product.siteUrl}/`;
      return [
        '  <url>',
        `    <loc>${url}</loc>`,
        `    <lastmod>${product.updatedAt}</lastmod>`,
        '  </url>'
      ].join('\n');
    })
    .join('\n');

  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n` +
      `<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
      `${entries}\n</urlset>\n`,
    {
      headers: {
        'Content-Type': 'application/xml; charset=utf-8'
      }
    }
  );
};

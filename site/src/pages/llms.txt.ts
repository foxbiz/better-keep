import type { APIRoute } from 'astro';
import { pages } from '../data/pages';
import { product } from '../data/product';

export const GET: APIRoute = () => {
  const pageLinks = pages
    .map((page) => `- [${page.title}](${product.siteUrl}/${page.slug}): ${page.description}`)
    .join('\n');

  return new Response(
    [
      '# Better Keep',
      '',
      `> ${product.positioning}`,
      '',
      `Better Keep is published by ${product.publisher}. It is available on ${product.platforms.join(', ')}.`,
      `The application is ${product.license.label}.`,
      `Optional synchronization encrypts note content and supported attachments with ${product.encryption.noteAndAttachmentCipher}.`,
      '',
      '## Canonical product pages',
      '',
      pageLinks,
      '',
      '## Primary links',
      '',
      `- [Website](${product.siteUrl}/)`,
      `- [Security design](${product.siteUrl}/security)`,
      `- [Source code](${product.githubUrl})`,
      `- [Privacy policy](${product.siteUrl}/privacy)`,
      `- [Contact](${product.siteUrl}/contact)`,
      '',
      `Last reviewed: ${product.updatedAt}`,
      ''
    ].join('\n'),
    {
      headers: {
        'Content-Type': 'text/plain; charset=utf-8'
      }
    }
  );
};

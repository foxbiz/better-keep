import { readFileSync } from 'node:fs';
import path from 'node:path';

export type PublicDocument = {
  slug:
    | 'privacy'
    | 'terms'
    | 'pricing'
    | 'contact'
    | 'cancellation-refund'
    | 'delete-user';
  sourceFile: string;
  title: string;
  eyebrow: string;
  description: string;
  introduction: string;
  updatedLabel?: string;
};

export const publicDocuments: readonly PublicDocument[] = [
  {
    slug: 'privacy',
    sourceFile: 'privacy.html',
    title: 'Privacy Policy',
    eyebrow: 'Your data and your choices',
    description:
      'How Better Keep collects, protects, uses, and retains account and note-related information.',
    introduction:
      'This policy explains the information Better Keep handles, how encrypted note data is protected, and the choices available to you.',
    updatedLabel: 'December 11, 2024'
  },
  {
    slug: 'terms',
    sourceFile: 'terms.html',
    title: 'Terms of Service',
    eyebrow: 'Rules for using Better Keep',
    description:
      'The terms governing access to Better Keep applications, subscriptions, encrypted synchronization, and related services.',
    introduction:
      'These terms explain the responsibilities, service conditions, subscription rules, and encryption limitations that apply when using Better Keep.',
    updatedLabel: 'December 11, 2025'
  },
  {
    slug: 'pricing',
    sourceFile: 'pricing.html',
    title: 'Simple, honest pricing',
    eyebrow: 'Start locally for free',
    description:
      'Compare free local Better Keep notes with optional paid synchronization and advanced account features.',
    introduction:
      'Core local note-taking stays free. Optional subscriptions support encrypted synchronization, account features, and continued product development.'
  },
  {
    slug: 'contact',
    sourceFile: 'contact.html',
    title: 'Contact Better Keep',
    eyebrow: 'Questions, feedback, or support',
    description:
      'Contact Foxbiz Software about Better Keep product questions, support requests, subscriptions, or privacy.',
    introduction:
      'Reach the Better Keep team for product help, billing questions, privacy requests, bug reports, or feedback.'
  },
  {
    slug: 'cancellation-refund',
    sourceFile: 'cancellation-refund.html',
    title: 'Cancellation and Refund Policy',
    eyebrow: 'Subscription help',
    description:
      'How Better Keep subscription cancellation and refund requests work across supported payment platforms.',
    introduction:
      'Cancellation and refund handling depends on the store or payment provider used for the Better Keep subscription.'
  },
  {
    slug: 'delete-user',
    sourceFile: 'delete-user.html',
    title: 'Delete Your Account',
    eyebrow: 'Control your Better Keep data',
    description:
      'How to request Better Keep account deletion, what is removed, the grace period, recovery, and local data handling.',
    introduction:
      'Follow these steps to schedule account deletion, understand what happens during the grace period, and export anything you want to keep first.',
    updatedLabel: 'December 21, 2025'
  }
] as const;

export function getPublicDocument(slug: PublicDocument['slug']) {
  const document = publicDocuments.find((entry) => entry.slug === slug);
  if (!document) {
    throw new Error(`Unknown public document: ${slug}`);
  }
  return document;
}

function sanitizeLegacyContent(html: string) {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, '')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, '')
    .replace(
      /<header\s+class=["']page-header["'][^>]*>[\s\S]*?<\/header>/i,
      ''
    )
    .replace(
      /<section\s+class=["']hero["'][^>]*>[\s\S]*?<\/section>/i,
      ''
    )
    .replace(/\sstyle=["'][^"']*["']/gi, '')
    .replace(/\p{Extended_Pictographic}\uFE0F?/gu, '')
    .replace(/\uFE0F/g, '')
    .replace(/href=["']\/welcome(?:\.html)?(?:#[^"']*)?["']/gi, 'href="/"')
    .replace(/href=["']\/#download["']/gi, 'href="/app/"')
    .replace(
      /href=["'](?:\/)?(privacy|terms|pricing|contact|cancellation-refund|delete-user)\.html(["'])/gi,
      'href="/$1"$2'
    );
}

export function readPublicDocumentContent(sourceFile: string) {
  if (!/^[a-z-]+\.html$/.test(sourceFile)) {
    throw new Error(`Unsafe public document filename: ${sourceFile}`);
  }

  const sourcePath = path.resolve(process.cwd(), '..', 'web', sourceFile);
  const html = readFileSync(sourcePath, 'utf8');
  const main = html.match(/<main\b[^>]*>([\s\S]*?)<\/main>/i);

  if (!main) {
    throw new Error(`No main element found in ${sourceFile}`);
  }

  return sanitizeLegacyContent(main[1]);
}

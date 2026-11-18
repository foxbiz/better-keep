export type PublicDocument = {
  slug:
    | 'privacy'
    | 'terms'
    | 'pricing'
    | 'contact'
    | 'help'
    | 'web-beta'
    | 'cancellation-refund'
    | 'delete-user';
  title: string;
  eyebrow: string;
  description: string;
  introduction: string;
  updatedLabel?: string;
};

export const publicDocuments: readonly PublicDocument[] = [
  {
    slug: 'privacy',
    title: 'Privacy Policy',
    eyebrow: 'Your data and your choices',
    description:
      'How Better Keep collects, protects, uses, and retains account and note-related information.',
    introduction:
      'This policy explains the information Better Keep handles, how encrypted note data is protected, and the choices available to you.',
    updatedLabel: 'November 8, 2026'
  },
  {
    slug: 'terms',
    title: 'Terms of Service',
    eyebrow: 'Rules for using Better Keep',
    description:
      'The terms governing access to Better Keep applications, subscriptions, encrypted synchronization, and related services.',
    introduction:
      'These terms explain the responsibilities, service conditions, subscription rules, and encryption limitations that apply when using Better Keep.',
    updatedLabel: 'November 8, 2026'
  },
  {
    slug: 'pricing',
    title: 'Compare Free, Lite and Pro',
    eyebrow: 'Pricing',
    description:
      'Compare Better Keep plans and prices for manual sync, automatic sync with your own storage, built-in cloud sync, and locked notes.',
    introduction:
      'Every plan includes unlimited local notes and free manual sync with your own storage. Choose Lite for automatic sync or Pro for built-in cloud storage and unlimited locked notes.'
  },
  {
    slug: 'help',
    title: 'Help & guides',
    eyebrow: 'Better Keep support',
    description: 'Find Better Keep guides for writing, importing notes, syncing devices, and joining or leaving the web beta.',
    introduction: 'Choose a topic below or contact support for help with your account.'
  },
  {
    slug: 'web-beta',
    title: 'Using the Better Keep web beta',
    eyebrow: 'Browser help',
    description: 'How to try the web beta, open your synced notes, and return to the stable version in the same browser.',
    introduction: 'The beta lets you try upcoming changes in your browser. It has a separate sign-in and local library. Edits and deletions you sync still affect your live account.'
  },
  {
    slug: 'contact',
    title: 'Contact Better Keep',
    eyebrow: 'Questions, feedback, or support',
    description:
      'Contact Foxbiz Software about Better Keep product questions, support requests, subscriptions, or privacy.',
    introduction:
      'Reach the Better Keep team for product help, billing questions, privacy requests, bug reports, or feedback.'
  },
  {
    slug: 'cancellation-refund',
    title: 'Cancellation and Refund Policy',
    eyebrow: 'Subscription help',
    description:
      'How Better Keep subscription cancellation and refund requests work across supported payment platforms.',
    introduction:
      'Cancellation and refund handling depends on the store or payment provider used for the Better Keep subscription.'
  },
  {
    slug: 'delete-user',
    title: 'Delete Your Account',
    eyebrow: 'Control your Better Keep data',
    description:
      'How to request Better Keep account deletion, what is removed, the grace period, recovery, and local data handling.',
    introduction:
      'Follow these steps to schedule account deletion, understand what happens during the grace period, and export anything you want to keep first.',
    updatedLabel: 'November 8, 2026'
  }
] as const;

export function getPublicDocument(slug: PublicDocument['slug']) {
  const document = publicDocuments.find((entry) => entry.slug === slug);
  if (!document) {
    throw new Error(`Unknown public document: ${slug}`);
  }
  return document;
}

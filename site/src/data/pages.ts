import { product } from './product';

export type PageSection = {
  heading: string;
  paragraphs?: string[];
  bullets?: string[];
};

export type ComparisonRow = {
  subject: string;
  betterKeep: string;
  alternative: string;
};

export type Faq = {
  question: string;
  answer: string;
};

export type MarketingPage = {
  slug: string;
  title: string;
  eyebrow: string;
  description: string;
  answer: string;
  updatedAt?: string;
  sections: PageSection[];
  comparison?: {
    alternativeLabel: string;
    rows: ComparisonRow[];
  };
  faqs?: Faq[];
  sources?: { label: string; url: string }[];
};

export const pages: MarketingPage[] = [
  {
    slug: 'google-keep-alternative',
    title: 'Google Keep alternative for iPhone: private, rich-text notes',
    updatedAt: '2026-09-30',
    eyebrow: 'Bring your notes to iPhone',
    description:
      'Looking for a Google Keep alternative on iPhone? Import your notes into Better Keep, write with rich text, and use local notes free. Encrypted sync is optional Pro.',
    answer:
      'Bring your Google Keep notes to Better Keep on iPhone. Keep your cards and checklists, add headings and text formatting, and write offline after signing in. An account is required; local notes are free, and optional end-to-end encrypted cloud sync requires Pro. Better Keep also runs on iPad, Android, Mac, Windows, and Web.',
    sections: [
      {
        heading: 'Cards, lists, and reminders',
        paragraphs: [
          'Pin important notes, add reminders, and organize with labels and colors. Better Keep also supports rich text, folders, recordings, sketches, and encrypted sync across approved devices with Pro.'
        ]
      },
      {
        heading: 'Import on your device',
        paragraphs: [
          'Export your data with Google Takeout, then select the archive inside Better Keep. The import is processed locally. Text notes, checklists, labels, colors, timestamps, pinned state, archive state, trash state, and supported attachments are preserved where the Takeout record provides them.'
        ],
        bullets: [
          'No upload to a third-party conversion website',
          'Exact re-imports are skipped by default',
          'A clear report lists imported, skipped, failed, and unsupported items'
        ]
      },
      {
        heading: 'Try a few notes first',
        paragraphs: [
          'Sign in, create a local note, import a small Takeout archive, and format an imported note with headings and checklists. Check the import report before moving your whole collection. Unlimited local notes are free; Pro adds cloud sync and removes the five-locked-note limit.'
        ]
      },
      {
        heading: 'Choose based on your priorities',
        paragraphs: [
          'If you want headings, folders, recordings, or encrypted sync, try a few notes in Better Keep before moving your collection. Local notes are free after sign-in, and the source code is available to inspect.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Google Keep',
      rows: [
        {
          subject: 'Writing',
          betterKeep: 'Rich text, headings, lists, formatting, sketches, and audio',
          alternative: 'Fast lightweight notes and checklists'
        },
        {
          subject: 'Privacy',
          betterKeep: 'End-to-end encrypted note and attachment sync',
          alternative: 'Protected by the Google account and Google service controls'
        },
        {
          subject: 'Offline use',
          betterKeep: 'Local-first note database on supported platforms',
          alternative: 'Offline behavior depends on the client and platform'
        },
        {
          subject: 'Migration',
          betterKeep: 'Local Google Takeout importer with an import report',
          alternative: 'Google Takeout export'
        },
        {
          subject: 'Code',
          betterKeep: product.license.label,
          alternative: 'Proprietary service'
        }
      ]
    },
    faqs: [
      {
        question: 'Can Better Keep import Google Keep notes?',
        answer:
          'Yes. Export Keep with Google Takeout and select the ZIP inside Better Keep. Processing stays on your device, and a report identifies anything that could not be imported.'
      },
      {
        question: 'Is an account required to use Better Keep?',
        answer:
          'Yes. An account is required to use Better Keep. After signing in, local note-taking is free and works offline. Optional encrypted cloud sync requires Pro.'
      },
      {
        question: 'Is Better Keep open source?',
        answer:
          `The code is available under CC BY-NC 4.0, which restricts commercial reuse. It is source-available, but does not meet the OSI definition of open source.`
      }
    ],
    sources: [
      {
        label: 'Google Takeout export instructions',
        url: 'https://support.google.com/accounts/answer/3024190'
      },
      {
        label: 'Google Keep product page',
        url: 'https://www.google.com/keep/'
      }
    ]
  },
  {
    slug: 'import/google-keep',
    title: 'How to import Google Keep notes on iPhone with Better Keep',
    updatedAt: '2026-09-30',
    eyebrow: 'Bring your notes to iPhone',
    description:
      'Move Google Keep notes to Better Keep on iPhone using Google Takeout. Follow the export and import steps, check limitations, and start with free offline notes.',
    answer:
      'Export your Google Keep notes with Google Takeout, save the ZIP in Files on your iPhone, sign in to Better Keep, and choose “Import from Google Keep.” An account is required; import runs locally and does not require Pro. Review the report, then edit your local notes offline for free. Cloud sync is optional and requires Pro.',
    sections: [
      {
        heading: '1. Export only the data you need',
        bullets: [
          'Open Google Takeout and deselect all products.',
          'Select Keep, create the export, and download the resulting ZIP.',
          'On iPhone, save the downloaded ZIP in Files. If you exported on a computer, transfer the ZIP to your iPhone first.',
          'Keep the original ZIP intact until the Better Keep import completes.'
        ]
      },
      {
        heading: '2. Import inside Better Keep on iPhone',
        bullets: [
          'Sign in to Better Keep, open the navigation menu, then go to Settings → Help → Import from Google Keep.',
          'Choose Takeout ZIP, select the archive from Files, and review the privacy and size notice.',
          'Keep the app open while it validates and imports the archive.',
          'Review imported, skipped, warning, failed, and unsupported totals.'
        ]
      },
      {
        heading: '3. Edit your imported notes offline',
        paragraphs: [
          'Open an imported note and add a heading, a checklist, or text formatting. Turn on Airplane Mode to try creating and editing local notes without a connection. Keep the original archive and compare important notes and attachments before completing your move.'
        ]
      },
      {
        heading: 'What is preserved',
        paragraphs: [
          'Better Keep maps Takeout text and list records to rich-text notes and checklists. It also preserves labels, color using the nearest supported palette color, pinned/archive/trash state, original timestamps, and supported image or audio attachments when those files exist in the export.'
        ]
      },
      {
        heading: 'Repeat imports and unsupported items',
        paragraphs: [
          'Importing the same export again skips identical notes. The report lists missing attachments, unsupported drawings, malformed records, and unknown fields. These items do not stop the rest of the import.'
        ]
      }
    ],
    faqs: [
      {
        question: 'Do I need an account or Pro to import on iPhone?',
        answer:
          'An account is required. Import and local note-taking are free and do not require Pro. Pro is required for optional cloud sync; signing in alone does not include sync.'
      },
      {
        question: 'Does Better Keep upload my Takeout ZIP?',
        answer:
          'No. The importer reads and converts the archive locally. Notes use the normal sync process only after they have been saved to the local database.'
      },
      {
        question: 'What happens if I import the same archive twice?',
        answer:
          'Notes that exactly match a previous import are skipped by default.'
      },
      {
        question: 'Can every Google Keep drawing be imported?',
        answer:
          'Not always. Unsupported drawings or missing companion files are reported as warnings so that the rest of the archive can still be imported.'
      }
    ],
    sources: [
      {
        label: 'Official Google Takeout instructions',
        url: 'https://support.google.com/accounts/answer/3024190'
      }
    ]
  },
  {
    slug: 'private-encrypted-notes',
    title: 'Private notes with end-to-end encrypted sync',
    updatedAt: '2026-09-30',
    eyebrow: 'Local notes and encrypted sync',
    description:
      'Write private local notes and optionally synchronize encrypted note content and attachments across Better Keep devices.',
    answer:
      'Keep a personal journal, project ideas, or everyday records in Better Keep. An account is required; local note-taking is free and works offline after sign-in. Pro adds end-to-end encrypted sync across approved devices and unlimited PIN-locked notes. Note titles, content, and supported attachments are encrypted before syncing; some operational metadata remains visible.',
    sections: [
      {
        heading: 'What end-to-end encryption protects',
        bullets: [
          'Note titles and rich-text content',
          'Images and audio recordings',
          'Supported sketch files and previews',
          'The user master key, wrapped separately for each approved device'
        ]
      },
      {
        heading: 'What is not encrypted',
        paragraphs: [
          `The following metadata is not encrypted and can be visible to the sync service: ${product.encryption.metadataNotEncrypted.join(', ')}. It is used for filtering, display, and sync.`
        ]
      },
      {
        heading: 'Device approval and recovery',
        paragraphs: [
          `Every approved device has a ${product.encryption.deviceKeyExchange} key pair. A recovery passphrase uses ${product.encryption.recoveryKeyDerivation} to derive the key that protects recovery material. Losing every approved device and the recovery passphrase can make synchronized encrypted notes unrecoverable.`
        ]
      }
    ]
  },
  {
    slug: 'offline-notes-app',
    title: 'An offline notes app that keeps working',
    updatedAt: '2026-10-01',
    eyebrow: 'Write without a connection',
    description:
      'Write journal entries, study notes, lists, and project ideas offline with Better Keep. Local notes are free after sign-in; encrypted cloud sync requires Pro.',
    answer:
      'Write on a train, keep a shopping list handy, or review study notes when the connection drops. Better Keep saves notes locally, so writing, editing, searching, and organizing continue offline after you have signed in. An account and an initial connection are required. Unlimited local notes are free; optional Pro sync sends changes to your other approved devices when connectivity returns.',
    sections: [
      {
        heading: 'What you can do offline',
        bullets: [
          'Write and edit rich-text notes',
          'Search, label, pin, archive, and restore notes',
          'Use folders and color-based organization',
          'Record supported local attachments'
        ]
      },
      {
        heading: 'Prepare your notes before going offline',
        paragraphs: [
          'Sign in while you have a connection, then open the notes and attachments you will need on that device. A note saved on another device is not available offline until it has reached this one. If you use Pro sync, give pending notes and attachments time to finish syncing before leaving.',
          'Before a trip, turn on airplane mode, create a note, edit it, and reopen it to check offline access on your device. Download a transcription model beforehand if you plan to use supported on-device voice transcription.'
        ]
      },
      {
        heading: 'Keep a list handy on a train or in a shop',
        paragraphs: [
          'Make a packing or shopping checklist before you leave, group items in the order you will need them, and pin the note. For example, a travel list can start with tickets, wallet, charger, and medication. Tick items off without waiting for a connection.',
          'For longer writing, keep a journal entry or study note on the device. Add a heading for each topic and write while the idea is fresh. Search and labels help you return to it later, even when the network is unavailable.'
        ]
      },
      {
        heading: 'Save on your device, then sync',
        paragraphs: [
          'Notes are saved on your device first. Free notes stay there. With Pro, note and attachment changes sync to your other approved devices when the connection returns. Wait for sync to finish before opening the latest version on another device.',
          'Offline access covers content already available locally. Signing in, downloading a new transcription model, and receiving content from another device need a connection. On-device transcription is not available in the web app.'
        ]
      }
    ],
    faqs: [
      {
        question: 'Can I start using Better Keep entirely offline?',
        answer:
          'No. An account and an initial internet connection are required to sign in. After signing in, you can create, edit, search, and organize local notes offline.'
      },
      {
        question: 'Do I need Pro to write offline?',
        answer:
          'No. Unlimited local notes and offline use after sign-in are free. Pro adds encrypted cloud sync across approved devices and unlimited locked notes; Free includes up to five locked notes.'
      },
      {
        question: 'Will a note from another device be available without a connection?',
        answer:
          'Only if the note has already reached the device you are using. Cross-device cloud sync requires Pro and a connection. Open the notes and attachments you need before going offline.'
      }
    ]
  },
  {
    slug: 'rich-text-notes',
    title: 'Rich-text notes for everyday writing',
    updatedAt: '2026-10-01',
    eyebrow: 'Format your notes',
    description:
      'Turn quick ideas into useful journal entries, study notes, and project plans with headings, lists, photos, sketches, and voice recordings in Better Keep.',
    answer:
      'Add headings, lists, links, photos, sketches, and audio to a note in Better Keep. Use it for journal entries, study notes, and project plans. Organize your writing with labels, folders, colors, and pinned notes. Sign in for free local notes that work offline; Pro adds encrypted sync across approved devices.',
    sections: [
      {
        heading: 'Text formatting and attachments',
        bullets: [
          'Headings, bold, italic, underline, strike, and code styles',
          'Bulleted, numbered, and checklist content',
          'Text color, alignment, indentation, and line spacing',
          'Links, images, audio recordings, and sketches'
        ]
      },
      {
        heading: 'Start a note quickly',
        paragraphs: [
          'Use quick actions to start an image, audio, sketch, checklist, or blank note. Recent and pinned notes appear as cards so you can find them from the home screen.'
        ]
      },
      {
        heading: 'Journals, study notes, and plans',
        bullets: [
          'Journal: write a dated entry, add a photo, and label entries by topic.',
          'Study: use headings for subjects, highlight key points, and attach sketches or a recording.',
          'Project planning: keep context in a rich-text note, make a checklist for next steps, and set a reminder.',
          'Everyday lists: keep shopping, packing, or reading lists together and pin the one you need now.'
        ],
        paragraphs: [
          'Rich-text editing and local note-taking are free after signing in. Local notes work offline. Pro adds encrypted cloud sync across your devices and unlimited locked notes.'
        ]
      },
      {
        heading: 'A study note you can revisit',
        paragraphs: [
          'Start with one topic rather than a whole course. Add headings for Summary, Example, and Questions. Explain the idea in your own words, attach a sketch or photo where it helps, and highlight the point you want to remember.',
          'Keep unanswered questions as a checklist, then add a label for the subject. Pin the note while you are working on it. A recording can stay with the note, with supported on-device transcription available when you want searchable text.'
        ]
      },
      {
        heading: 'A journal entry with room for the details',
        paragraphs: [
          'Use a date and a short title, then try three prompts: What happened? What do I want to remember? What will I try tomorrow? Use whichever prompts help you write.',
          'Add a photo or sketch, use a label for a recurring topic, and keep the entries in a folder. Local writing is free after sign-in. If you want the journal available on another approved device, Pro adds encrypted cloud sync.'
        ]
      },
      {
        heading: 'A project plan that fits in one note',
        paragraphs: [
          'For a small project, use headings for Goal, Next steps, and References. Write the outcome under Goal, make a checklist of actions, and keep useful links or photos under References. Set a reminder for when you want to revisit the plan.',
          'Use labels and pinned notes to find active work quickly, then archive the note when the project is finished.'
        ]
      }
    ],
    faqs: [
      {
        question: 'Is rich-text editing free?',
        answer:
          'Yes. An account is required, but rich-text editing and unlimited local notes are free after sign-in. Pro adds encrypted cloud sync across devices and unlimited locked notes.'
      },
      {
        question: 'Can I write longer notes offline?',
        answer:
          'Yes. After signing in, you can create and edit local rich-text notes offline. Notes or attachments from another device must first reach the device you are using; Pro sync needs a connection.'
      }
    ]
  },
  {
    slug: 'voice-notes-transcription',
    title: 'Private voice notes with on-device transcription',
    eyebrow: 'Record and transcribe',
    description:
      'Record voice notes in Better Keep and convert speech to searchable text with supported on-device Whisper transcription.',
    answer:
      'Better Keep can attach audio recordings to notes and, on supported native devices, transcribe them with an on-device Whisper model. The transcription runs on your device without sending audio to a speech-to-text service. Model availability, download size, performance, and language accuracy vary by device, so the original recording remains attached for reference.',
    sections: [
      {
        heading: 'Keep recordings with your notes',
        bullets: [
          'Attach recordings directly to the relevant note',
          'Append transcripts to searchable note text',
          'Run supported transcription locally after the model is available',
          'Keep the original recording alongside the transcript'
        ]
      },
      {
        heading: 'Downloads and accuracy',
        paragraphs: [
          'Download a model before transcribing on supported native devices. Transcription is not available in the web app. Check transcripts for mistakes, especially names and specialist terms. Accents and background noise can also affect accuracy.'
        ]
      }
    ]
  },
  {
    slug: 'cross-platform-notes',
    title: 'Notes across Android, iPhone, Mac, Windows, and Web',
    eyebrow: 'Phone, computer, and browser',
    description:
      'Use Better Keep on Android, iOS, macOS, Windows, and the web with optional end-to-end encrypted synchronization.',
    answer:
      `Better Keep is available on ${product.platforms.join(', ')}. An account is required. Notes are saved on each device. Pro adds encrypted sync of note content and supported attachments between approved devices. Reminders, background sync, file access, and transcription vary by platform.`,
    sections: [
      {
        heading: 'Notes and organization',
        bullets: [
          'Card, grid, list, and folder-based organization',
          'Rich-text editing and search',
          'Labels, colors, pins, archive, and trash',
          'Encrypted synchronization between approved devices'
        ]
      },
      {
        heading: 'Check features for your device',
        paragraphs: [
          'Some features depend on your device and operating system. Check the store listing and release notes for limits on reminders, background sync, attachment access, and transcription.'
        ]
      }
    ]
  },
  {
    slug: 'source-available-notes',
    title: 'A source-available private notes app',
    eyebrow: 'Read the source code',
    description:
      'Review the Better Keep source code, security design, local storage approach, and CC BY-NC 4.0 license.',
    answer:
      `Better Keep publishes its application source so users and developers can inspect how notes, local storage, synchronization, and encryption are implemented. The code is licensed under CC BY-NC 4.0, which restricts commercial reuse. It is source-available, but does not meet the OSI definition of open source.`,
    sections: [
      {
        heading: 'What you can inspect',
        bullets: [
          'Flutter clients for mobile, desktop, and web',
          'Local database and synchronization logic',
          'End-to-end encryption and recovery implementation',
          'Backend functions, data rules, and automated tests'
        ]
      },
      {
        heading: 'License and reuse',
        paragraphs: [
          'The repository is available for inspection and non-commercial use under its license. The license does not meet the standard definition of open source because it includes a non-commercial restriction.'
        ]
      }
    ],
    sources: [
      {
        label: 'Better Keep source and license',
        url: product.githubUrl
      },
      {
        label: 'Open Source Definition',
        url: 'https://opensource.org/osd'
      }
    ]
  },
  {
    slug: 'security',
    title: 'Better Keep security and encryption design',
    eyebrow: 'Encryption and its limits',
    description:
      'Understand what Better Keep encrypts, what metadata remains visible, how approved devices receive keys, and how recovery works.',
    answer:
      `Better Keep encrypts synchronized note titles, content, and supported attachments on the device with ${product.encryption.noteAndAttachmentCipher}. Approved devices use ${product.encryption.deviceKeyExchange} key exchange to receive a wrapped user master key. Recovery material is protected with a passphrase-derived ${product.encryption.recoveryKeyDerivation} key. The source code is available to inspect. No independent security audit has been published.`,
    sections: [
      {
        heading: 'Threat model',
        paragraphs: [
          'The design aims to prevent the synchronization backend or an attacker who obtains only stored cloud data from reading encrypted note content and supported attachments. It does not protect plaintext visible on an unlocked device, compromised operating systems, screen capture, malicious keyboards, weak device access controls, or information intentionally shared by the user.'
        ]
      },
      {
        heading: 'Key architecture',
        bullets: [
          'A random 32-byte user master key encrypts note payloads.',
          `Each device has its own ${product.encryption.deviceKeyExchange} key pair.`,
          `The master key is wrapped separately for approved devices with ${product.encryption.noteAndAttachmentCipher}.`,
          `Optional recovery uses ${product.encryption.recoveryKeyDerivation} with a random salt.`
        ]
      },
      {
        heading: 'Encrypted data',
        bullets: [
          'Note title and rich-text content',
          'Images and audio recordings',
          'Supported sketch files and previews',
          'Master-key material stored for approved devices and recovery'
        ]
      },
      {
        heading: 'Metadata and limitations',
        paragraphs: [
          `The current encrypted payload excludes ${product.encryption.metadataNotEncrypted.join(', ')}. These values can be visible to the synchronization service. Better Keep has no published independent security audit; source availability and documented algorithms are not substitutes for one.`
        ]
      },
      {
        heading: 'Recovery responsibility',
        paragraphs: [
          'A recovery passphrase is not sent to the backend. If all approved devices and the recovery passphrase are lost, Better Keep cannot reconstruct the encryption key. Keep the passphrase in a reputable password manager or another secure offline location.'
        ]
      },
      {
        heading: 'Report a vulnerability',
        paragraphs: [
          `Send a reproducible report to ${product.supportEmail}. Please avoid accessing other users’ data, disrupting the service, or publishing an unpatched issue before a reasonable disclosure window.`
        ]
      }
    ],
    sources: [
      {
        label: 'Detailed E2EE architecture',
        url: 'https://github.com/foxbiz/better-keep/blob/main/docs/E2EE.md'
      },
      {
        label: 'Security reporting policy',
        url: 'https://github.com/foxbiz/better-keep/blob/main/SECURITY.md'
      }
    ]
  },
  {
    slug: 'changelog',
    title: 'Better Keep changelog',
    eyebrow: 'What changed and why',
    description:
      'Follow Better Keep product, privacy, migration, reliability, and platform updates with clear release notes and dates.',
    answer:
      'Read about changes to Better Keep, including note import, review prompts, the website, and security documentation. The full changelog is available in the repository.',
    sections: [
      {
        heading: 'July 2026: note import and website updates',
        bullets: [
          'Added a local-only Google Keep Takeout importer with safety limits, cancellation, duplicate detection, and an import report.',
          'Added review eligibility based on time, note count, active days, cooldowns, app version, and completed actions in the app.',
          'Moved Flutter Web to /app/ and made the root website static, crawlable HTML.',
          'Published switching, privacy, offline, rich-text, voice, platform, source-license, security, and comparison pages.',
          'Added automated metadata, link, schema, routing, store-copy, and Lighthouse checks.'
        ]
      },
      {
        heading: 'Release-note policy',
        paragraphs: [
          'A release is documented when it changes features, supported platforms, privacy or security behavior, migration compatibility, pricing, or data handling. Minor internal maintenance may be grouped. Security-sensitive details are published after users have a reasonable chance to update.'
        ]
      }
    ],
    sources: [
      {
        label: 'Full repository changelog',
        url: 'https://github.com/foxbiz/better-keep/blob/main/CHANGELOG.md'
      }
    ]
  },
  {
    slug: 'compare/standard-notes',
    title: 'Better Keep vs Standard Notes',
    eyebrow: 'Compare editing, sync, and licensing',
    description:
      'Compare Better Keep and Standard Notes for private writing, encrypted sync, card-based capture, rich editing, source licensing, and platform support.',
    answer:
      'Better Keep organizes rich-text notes as cards, with reminders, sketches, and voice recordings. Standard Notes offers encrypted notes and a choice of editors, with open-source clients and server components. Compare the editing tools and licenses before choosing.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You like notes displayed as cards and shortcuts for starting a note.',
          'You use reminders, sketches, audio, colors, and folders.',
          'A local Google Takeout migration is important.'
        ]
      },
      {
        heading: 'Standard Notes is a better fit when',
        bullets: [
          'You prefer its encrypted notes and editors.',
          'You need open-source licensing or its self-hosting options.',
          'You prefer its subscription plans.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Standard Notes',
      rows: [
        {
          subject: 'Notes and editing',
          betterKeep: 'Card-based quick capture and organization',
          alternative: 'Encrypted notes and a choice of editors'
        },
        {
          subject: 'Import options',
          betterKeep: 'Local Google Takeout importer',
          alternative: 'Multiple documented import and conversion paths'
        },
        {
          subject: 'License',
          betterKeep: product.license.label,
          alternative: 'Open-source clients and server components'
        }
      ]
    },
    sources: [
      {
        label: 'Standard Notes official site',
        url: 'https://standardnotes.com/'
      },
      {
        label: 'Standard Notes help center',
        url: 'https://standardnotes.com/help'
      }
    ]
  },
  {
    slug: 'compare/notesnook',
    title: 'Better Keep vs Notesnook',
    eyebrow: 'Two private note-taking approaches',
    description:
      'Compare Better Keep and Notesnook for privacy, migration, editing, quick capture, organization, licensing, and device support.',
    answer:
      'Better Keep has rich-text cards, reminders, sketches, voice transcription on supported native devices, and local Google Takeout import. Notesnook offers encrypted notes, publishing, a vault, and open-source code. Try each app with a few notes to see which editing and organization tools you prefer.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You prefer notes displayed as cards.',
          'Fast capture, reminders, colors, audio, and sketches matter.',
          'You want a local Takeout import inside the app.'
        ]
      },
      {
        heading: 'Notesnook is a better fit when',
        bullets: [
          'Its open-source licensing is a requirement.',
          'You want its vault, publishing, or editing features.',
          'You prefer its subscription plans.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Notesnook',
      rows: [
        {
          subject: 'Notes and editing',
          betterKeep: 'Rich-text cards and quick capture',
          alternative: 'Private notebooks, editor, vault, and publishing'
        },
        {
          subject: 'Google Keep migration',
          betterKeep: 'Local Takeout importer in the app',
          alternative: 'See Notesnook’s import guide'
        },
        {
          subject: 'License',
          betterKeep: product.license.label,
          alternative: 'Open source'
        }
      ]
    },
    sources: [
      {
        label: 'Notesnook official site',
        url: 'https://notesnook.com/'
      },
      {
        label: 'Notesnook help',
        url: 'https://help.notesnook.com/'
      }
    ]
  },
  {
    slug: 'compare/joplin',
    title: 'Better Keep vs Joplin',
    eyebrow: 'Cards or Markdown notebooks',
    description:
      'Compare Better Keep and Joplin for privacy, offline notes, migration, organization, Markdown, self-hosting, licensing, and platform support.',
    answer:
      'Better Keep has rich-text cards, reminders, colors, audio, sketches, and Google Keep import. Joplin organizes Markdown notes in notebooks, supports plugins, and offers several sync options. Compare how you write and organize notes, and whether you want to run your own sync server.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You want colorful cards instead of notebook-first navigation.',
          'You use reminders, voice transcription, and shortcuts for starting notes.',
          'You want an importer integrated into the app.'
        ]
      },
      {
        heading: 'Joplin is a better fit when',
        bullets: [
          'You need Markdown, plugins, or self-hosting.',
          'You prefer notebook hierarchies and multiple sync targets.',
          'You need an OSI-approved open-source license.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Joplin',
      rows: [
        {
          subject: 'Notes and editing',
          betterKeep: 'Rich-text cards and quick capture',
          alternative: 'Markdown notebooks and plugins'
        },
        {
          subject: 'Hosting',
          betterKeep: 'Optional Pro encrypted cloud sync',
          alternative: 'Multiple sync targets and Joplin Server'
        },
        {
          subject: 'License',
          betterKeep: product.license.label,
          alternative: 'Open source'
        }
      ]
    },
    sources: [
      {
        label: 'Joplin official site',
        url: 'https://joplinapp.org/'
      },
      {
        label: 'Joplin Google Keep importer',
        url: 'https://joplinapp.org/plugins/plugin/net.bonfigli.GoogleKeepToJoplin/'
      }
    ]
  }
];

export const pageBySlug = new Map(pages.map((page) => [page.slug, page]));

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
    title: 'A private Google Keep alternative with richer notes',
    eyebrow: 'Switch without losing simplicity',
    description:
      'Compare Better Keep with Google Keep for private, offline rich-text notes, encrypted sync, labels, reminders, voice transcription, and cross-platform access.',
    answer:
      'Better Keep is a strong Google Keep alternative for people who like a fast card-based notes workflow but need rich text, deeper organization, offline access, and end-to-end encrypted sync. It runs on mobile, desktop, and web, and its local Takeout importer lets you move notes without uploading the archive to a conversion service.',
    sections: [
      {
        heading: 'The familiar parts stay familiar',
        paragraphs: [
          'Capture a thought quickly, pin important cards, color-code notes, add reminders, search instantly, and organize with labels. Better Keep keeps those lightweight habits while adding a fuller editor, folders, audio, sketches, and multi-device privacy controls.'
        ]
      },
      {
        heading: 'A private migration path',
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
        heading: 'Choose based on your priorities',
        paragraphs: [
          'Google Keep remains convenient for a minimal Google-account workflow. Better Keep is designed for people who want a similarly direct experience with richer writing, device-local operation, a transparent security design, and source code they can inspect.'
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
        question: 'Does Better Keep work without an account?',
        answer:
          'Local note-taking works without an account. An account is used for optional encrypted synchronization and account-based features.'
      },
      {
        question: 'Is Better Keep open source?',
        answer:
          `The source is publicly inspectable under CC BY-NC 4.0. That is accurately described as source-available rather than OSI-approved open source.`
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
    title: 'Import Google Keep notes privately with Takeout',
    eyebrow: 'A local migration guide',
    description:
      'Move Google Keep notes to Better Keep with a local Google Takeout import that preserves text, checklists, labels, colors, timestamps, state, and supported attachments.',
    answer:
      'To move from Google Keep, request a Google Takeout export containing Keep, download the ZIP, and choose “Import from Google Keep” in Better Keep. The archive is parsed on your device rather than uploaded to Better Keep or another converter. Review the import summary before continuing with optional encrypted sync.',
    sections: [
      {
        heading: '1. Export only the data you need',
        bullets: [
          'Open Google Takeout and deselect all products.',
          'Select Keep, create the export, and download the resulting ZIP.',
          'Keep the original ZIP intact until the Better Keep import completes.'
        ]
      },
      {
        heading: '2. Import inside Better Keep',
        bullets: [
          'Open Help and choose “Import from Google Keep.”',
          'Select the Takeout ZIP and review the privacy and size notice.',
          'Keep the app open while it validates and imports the archive.',
          'Review imported, skipped, warning, failed, and unsupported totals.'
        ]
      },
      {
        heading: 'What is preserved',
        paragraphs: [
          'Better Keep maps Takeout text and list records to rich-text notes and checklists. It also preserves labels, color using the nearest supported palette color, pinned/archive/trash state, original timestamps, and supported image or audio attachments when those files exist in the export.'
        ]
      },
      {
        heading: 'Safe repeat imports and limitations',
        paragraphs: [
          'A stable fingerprint prevents an identical Takeout record from being imported twice. Missing attachments, drawings, malformed records, and unknown future fields are included in the report instead of stopping every other note.'
        ]
      }
    ],
    faqs: [
      {
        question: 'Does Better Keep upload my Takeout ZIP?',
        answer:
          'No. The importer reads and converts the archive locally. Notes use the normal sync process only after they have been saved to the local database.'
      },
      {
        question: 'What happens if I import the same archive twice?',
        answer:
          'Exact previously imported records are skipped by default using a stable fingerprint.'
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
    eyebrow: 'Privacy without giving up convenience',
    description:
      'Write private local notes and optionally synchronize encrypted note content and attachments across Better Keep devices.',
    answer:
      `Better Keep stores notes locally first and encrypts note titles, content, images, audio, and supported sketch attachments before optional cloud synchronization. Its current design uses ${product.encryption.noteAndAttachmentCipher} for authenticated encryption and ${product.encryption.deviceKeyExchange} device keys. Some operational metadata remains visible so synchronization and filtering can work.`,
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
          `Better Keep currently leaves ${product.encryption.metadataNotEncrypted.join(', ')} outside the encrypted note payload. This metadata supports filtering, display, and synchronization. The security page documents the boundary so you can make an informed decision.`
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
    eyebrow: 'Local-first by design',
    description:
      'Create, edit, search, organize, and review notes without waiting for a network connection in Better Keep.',
    answer:
      'Better Keep is built around a local note database, so core writing, editing, searching, pinning, labeling, archiving, and organizing continue without a network connection. When optional synchronization is configured, local changes are queued and sent after connectivity returns instead of blocking the writing experience.',
    sections: [
      {
        heading: 'Useful when the connection is not',
        bullets: [
          'Write and edit rich-text notes',
          'Search, label, pin, archive, and restore notes',
          'Use folders and color-based organization',
          'Record supported local attachments'
        ]
      },
      {
        heading: 'Sync follows the local save',
        paragraphs: [
          'A local save is the primary action. Optional cloud synchronization operates after the note exists locally, with retry tracking for notes and attachments. Features that inherently require a remote service, account verification, or a new model download still need connectivity.'
        ]
      }
    ]
  },
  {
    slug: 'rich-text-notes',
    title: 'Rich-text notes without a heavy workspace',
    eyebrow: 'Write more, keep the capture flow',
    description:
      'Use headings, lists, checklists, emphasis, color, links, images, audio, and sketches in fast card-based Better Keep notes.',
    answer:
      'Better Keep combines the speed of a card-based notes app with a fuller rich-text editor. Use headings, emphasis, lists, checklists, indentation, alignment, links, colors, images, audio, and sketches without first building a database or workspace. Notes remain searchable and can be organized with labels, folders, colors, and pinned views.',
    sections: [
      {
        heading: 'A writing tool when you need one',
        bullets: [
          'Headings, bold, italic, underline, strike, and code styles',
          'Bulleted, numbered, and checklist content',
          'Text color, alignment, indentation, and line spacing',
          'Links, images, audio recordings, and sketches'
        ]
      },
      {
        heading: 'Still optimized for quick capture',
        paragraphs: [
          'The editor adds structure without turning every thought into a project. Quick actions can start an image, audio, sketch, checklist, or blank note, while cards keep recent and pinned material easy to scan.'
        ]
      }
    ]
  },
  {
    slug: 'voice-notes-transcription',
    title: 'Private voice notes with on-device transcription',
    eyebrow: 'Capture first, search later',
    description:
      'Record voice notes in Better Keep and convert speech to searchable text with supported on-device Whisper transcription.',
    answer:
      'Better Keep can attach audio recordings to notes and, on supported native devices, transcribe them with an on-device Whisper model. This keeps transcription audio out of a hosted speech-to-text API. Model availability, download size, performance, and language accuracy vary by device, so the original recording remains attached for reference.',
    sections: [
      {
        heading: 'Designed for private capture',
        bullets: [
          'Attach recordings directly to the relevant note',
          'Append transcripts to searchable note text',
          'Run supported transcription locally after the model is available',
          'Keep the original recording alongside the transcript'
        ]
      },
      {
        heading: 'Be precise about “on device”',
        paragraphs: [
          'The transcription engine runs locally on supported native platforms, but downloading a model can require a connection. Web support and performance differ from native devices. Better Keep does not describe the transcript as perfectly accurate; names, accents, background noise, and specialist vocabulary can require correction.'
        ]
      }
    ]
  },
  {
    slug: 'cross-platform-notes',
    title: 'Notes across Android, iPhone, Mac, Windows, and Web',
    eyebrow: 'One focused app across your devices',
    description:
      'Use Better Keep on Android, iOS, macOS, Windows, and the web with optional end-to-end encrypted synchronization.',
    answer:
      `Better Keep is available on ${product.platforms.join(', ')}. Each client keeps a local note database, while an optional account synchronizes encrypted note content and attachments between approved devices. Platform capabilities such as alarms, background work, file access, and on-device transcription can differ because each operating system exposes different APIs.`,
    sections: [
      {
        heading: 'The same core workflow everywhere',
        bullets: [
          'Card, grid, list, and folder-based organization',
          'Rich-text editing and search',
          'Labels, colors, pins, archive, and trash',
          'Encrypted synchronization between approved devices'
        ]
      },
      {
        heading: 'Platform differences are documented',
        paragraphs: [
          'Better Keep avoids claiming feature parity where the operating system cannot provide it. Store listings and release notes identify platform-specific limitations for alarms, background behavior, attachment access, and transcription.'
        ]
      }
    ]
  },
  {
    slug: 'source-available-notes',
    title: 'A source-available private notes app',
    eyebrow: 'Inspect the implementation',
    description:
      'Review the Better Keep source code, security design, local storage approach, and CC BY-NC 4.0 license.',
    answer:
      `Better Keep publishes its application source so users and developers can inspect how notes, local storage, synchronization, and encryption are implemented. The code is licensed under CC BY-NC 4.0, so the accurate label is “source-available,” not OSI-approved open source. Commercial reuse is restricted by the current license.`,
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
        heading: 'License boundary',
        paragraphs: [
          'The repository is available for inspection and non-commercial use under its license. The license does not meet the standard definition of open source because it includes a non-commercial restriction. Better Keep will use the same wording consistently in the app, website, repository, and store materials.'
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
    eyebrow: 'A transparent boundary, not a vague promise',
    description:
      'Understand what Better Keep encrypts, what metadata remains visible, how approved devices receive keys, and how recovery works.',
    answer:
      `Better Keep encrypts synchronized note titles, content, and supported attachments on the device with ${product.encryption.noteAndAttachmentCipher}. Approved devices use ${product.encryption.deviceKeyExchange} key exchange to receive a wrapped user master key. Recovery material is protected with a passphrase-derived ${product.encryption.recoveryKeyDerivation} key. The implementation is source-available but has not been described as independently audited.`,
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
      'The Better Keep changelog documents meaningful product and security changes instead of hiding them inside store copy. The current work adds a local Google Keep Takeout importer, an ethical native review prompt, a static search-friendly website, clearer security and licensing claims, and automated visibility checks.',
    sections: [
      {
        heading: 'July 2026 — migration and discoverability foundation',
        bullets: [
          'Added a local-only Google Keep Takeout importer with safety limits, cancellation, duplicate detection, and an import report.',
          'Added review eligibility based on time, note count, active days, cooldowns, app version, and a successful user milestone.',
          'Moved Flutter Web to /app/ and made the root website static, crawlable HTML.',
          'Published switching, privacy, offline, rich-text, voice, platform, source-license, security, and fair comparison pages.',
          'Added automated metadata, link, schema, routing, store-copy, and Lighthouse checks.'
        ]
      },
      {
        heading: 'Release-note policy',
        paragraphs: [
          'A release is documented when it changes user workflows, supported platforms, privacy or security behavior, migration compatibility, pricing, or data handling. Minor internal maintenance may be grouped. Security-sensitive details are published after users have a reasonable chance to update.'
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
    eyebrow: 'Choose the workflow, not a universal winner',
    description:
      'Compare Better Keep and Standard Notes for private writing, encrypted sync, card-based capture, rich editing, source licensing, and platform support.',
    answer:
      'Better Keep and Standard Notes both appeal to privacy-conscious note takers, but their workflows differ. Better Keep emphasizes colorful card-based capture, reminders, sketches, voice notes, and a Keep-style interface. Standard Notes emphasizes a long-established encrypted writing system and an open-source ecosystem. Choose based on the workflow and license model you prefer.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You want a familiar card wall and quick-capture shortcuts.',
          'Reminders, sketches, audio, colors, and folders are central.',
          'A local Google Takeout migration is important.'
        ]
      },
      {
        heading: 'Standard Notes is a better fit when',
        bullets: [
          'You prioritize its established encrypted notes ecosystem.',
          'Its open-source licensing and self-hosting options are decisive.',
          'You prefer its editor and subscription model.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Standard Notes',
      rows: [
        {
          subject: 'Primary workflow',
          betterKeep: 'Card-based quick capture and organization',
          alternative: 'Encrypted writing and editor ecosystem'
        },
        {
          subject: 'Migration focus',
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
      'Better Keep and Notesnook both target people who want private cross-device notes. Better Keep stands out through a Keep-style card workflow, reminders, sketches, voice transcription, and local Google Takeout migration. Notesnook offers its own encrypted editor, publishing, vault, and open-source ecosystem. Test both with your real writing and organization habits.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You are moving from a card-based Keep workflow.',
          'Fast capture, reminders, colors, audio, and sketches matter.',
          'You want a local Takeout import inside the app.'
        ]
      },
      {
        heading: 'Notesnook is a better fit when',
        bullets: [
          'Its open-source licensing is a requirement.',
          'Its vault, publishing, and editor workflow match your needs.',
          'You prefer its account and subscription offering.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Notesnook',
      rows: [
        {
          subject: 'Primary workflow',
          betterKeep: 'Keep-style cards and quick capture',
          alternative: 'Private notebooks, editor, vault, and publishing'
        },
        {
          subject: 'Google Keep migration',
          betterKeep: 'Local Takeout importer in the app',
          alternative: 'Use currently documented Notesnook import options'
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
    eyebrow: 'Simple cards or a notebook knowledge base',
    description:
      'Compare Better Keep and Joplin for privacy, offline notes, migration, organization, Markdown, self-hosting, licensing, and platform support.',
    answer:
      'Better Keep is designed for fast card-based capture with rich text, reminders, colors, audio, sketches, and an integrated Keep migration. Joplin is a mature open-source notebook and Markdown system with plugins and multiple synchronization targets. Better Keep favors a lightweight Keep-style experience; Joplin favors extensibility and user-controlled infrastructure.',
    sections: [
      {
        heading: 'Better Keep is a better fit when',
        bullets: [
          'You want colorful cards instead of notebook-first navigation.',
          'Reminders, audio transcription, and mobile quick capture are central.',
          'You want an importer integrated into the app.'
        ]
      },
      {
        heading: 'Joplin is a better fit when',
        bullets: [
          'Markdown, plugins, and self-hosting are requirements.',
          'You prefer notebook hierarchies and multiple sync targets.',
          'An OSI-approved open-source license is non-negotiable.'
        ]
      }
    ],
    comparison: {
      alternativeLabel: 'Joplin',
      rows: [
        {
          subject: 'Primary workflow',
          betterKeep: 'Rich-text cards and quick capture',
          alternative: 'Markdown notebooks and extensibility'
        },
        {
          subject: 'Hosting',
          betterKeep: 'Managed optional encrypted sync',
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

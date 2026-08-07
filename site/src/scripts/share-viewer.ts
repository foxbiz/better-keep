import DOMPurify from 'dompurify';
import { marked } from 'marked';
import type {
  FirebaseGateway,
  ShareRecord
} from './share-firebase';
import {
  classifyRequestRecord,
  classifyShareRecord,
  decryptShareBytes,
  decryptShareText,
  detectPlatform,
  getLocalPreviewState,
  isSafeAttachmentPath,
  parseShareLocation
} from '../lib/share-viewer.mjs';

type ShareScreen =
  | 'loading'
  | 'request'
  | 'pending'
  | 'content'
  | 'expired'
  | 'revoked'
  | 'denied'
  | 'notFound'
  | 'error';

type AttachmentRecord = {
  type: 'image' | 'sketch' | 'audio';
  storagePath: string;
  mimeType: string;
  title?: string;
};

const MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024;
const allowedAttachmentTypes = new Set(['image', 'sketch', 'audio']);
const allowedMimeTypes = new Set([
  'image/jpeg',
  'image/png',
  'image/webp',
  'audio/m4a',
  'audio/mp4',
  'audio/mpeg'
]);

function requiredElement<T extends Element>(
  parent: ParentNode,
  selector: string
): T {
  const element = parent.querySelector<T>(selector);
  if (!element) throw new Error(`Share viewer is missing ${selector}`);
  return element;
}

class ShareView {
  readonly root: HTMLElement;
  readonly screens: Map<ShareScreen, HTMLElement>;
  readonly form: HTMLFormElement;
  readonly deviceName: HTMLInputElement;
  readonly requestButton: HTMLButtonElement;
  readonly checkButton: HTMLButtonElement;
  readonly pendingId: HTMLElement;
  readonly noteTitle: HTMLElement;
  readonly noteBody: HTMLElement;
  readonly attachmentsSection: HTMLElement;
  readonly attachmentsGrid: HTMLElement;
  readonly errorMessage: HTMLElement;
  readonly retryButton: HTMLButtonElement;
  readonly lightbox: HTMLDialogElement;
  readonly lightboxImage: HTMLImageElement;
  readonly lightboxClose: HTMLButtonElement;

  constructor(root: HTMLElement) {
    this.root = root;
    this.screens = new Map(
      [...root.querySelectorAll<HTMLElement>('[data-share-screen]')].map(
        (element) => [element.dataset.shareScreen as ShareScreen, element]
      )
    );
    this.form = requiredElement(root, '[data-request-form]');
    this.deviceName = requiredElement(root, '#share-device-name');
    this.requestButton = requiredElement(root, '[data-request-button]');
    this.checkButton = requiredElement(root, '[data-check-status]');
    this.pendingId = requiredElement(root, '[data-pending-id]');
    this.noteTitle = requiredElement(root, '[data-note-title]');
    this.noteBody = requiredElement(root, '[data-note-body]');
    this.attachmentsSection = requiredElement(root, '[data-attachments-section]');
    this.attachmentsGrid = requiredElement(root, '[data-attachments-grid]');
    this.errorMessage = requiredElement(root, '[data-error-message]');
    this.retryButton = requiredElement(root, '[data-retry]');
    this.lightbox = requiredElement(root, '[data-lightbox]');
    this.lightboxImage = requiredElement(root, '[data-lightbox-image]');
    this.lightboxClose = requiredElement(root, '[data-lightbox-close]');
  }

  show(screen: ShareScreen, focus = true) {
    for (const [name, element] of this.screens) {
      element.hidden = name !== screen;
    }
    this.root.dataset.shareState = screen;
    this.root.setAttribute('aria-busy', String(screen === 'loading'));
    if (focus && screen !== 'loading') {
      requestAnimationFrame(() => {
        this.screens
          .get(screen)
          ?.querySelector<HTMLElement>('[data-state-heading], [data-note-title]')
          ?.focus();
      });
    }
  }

  showError(message: string) {
    this.errorMessage.textContent = message;
    this.show('error');
  }

  setRequestBusy(busy: boolean) {
    this.requestButton.disabled = busy;
    this.requestButton.textContent = busy ? 'Requesting…' : 'Request access';
  }

  setCheckBusy(busy: boolean) {
    this.checkButton.disabled = busy;
    this.checkButton.textContent = busy ? 'Checking…' : 'Check status';
  }

  showPendingRequest(requestId: string) {
    this.pendingId.textContent = `Request ${requestId.slice(0, 8)}…`;
    this.show('pending');
  }

  renderNote(title: string, markdown: string) {
    this.noteTitle.textContent = title || 'Shared note';
    const rendered = marked.parse(markdown, { gfm: true, breaks: true });
    if (typeof rendered !== 'string') {
      throw new Error('Asynchronous Markdown rendering is unsupported');
    }
    this.noteBody.innerHTML = DOMPurify.sanitize(rendered, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ['script', 'style', 'iframe', 'object', 'embed', 'form'],
      FORBID_ATTR: ['style']
    });

    this.noteBody.querySelectorAll('img').forEach((image) => {
      const replacement = document.createElement('span');
      replacement.textContent = image.alt
        ? `[Image: ${image.alt}]`
        : '[Image omitted from note content]';
      image.replaceWith(replacement);
    });
    this.noteBody.querySelectorAll<HTMLAnchorElement>('a[href]').forEach((link) => {
      link.rel = 'noopener noreferrer';
    });
  }

  resetAttachments() {
    this.attachmentsGrid.replaceChildren();
    this.attachmentsSection.hidden = true;
  }

  attachmentContainer(className = '') {
    const item = document.createElement('div');
    item.className = `share-attachment ${className}`.trim();
    this.attachmentsGrid.append(item);
    this.attachmentsSection.hidden = false;
    return item;
  }

  reserveAttachmentSlot() {
    const item = this.attachmentContainer('share-attachment--loading');
    item.setAttribute('aria-busy', 'true');
    item.setAttribute('role', 'status');
    const label = document.createElement('span');
    label.className = 'share-attachment__loading';
    label.textContent = 'Loading attachment…';
    item.append(label);
    return item;
  }

  populateAttachmentSlot(item: HTMLElement, className = '') {
    item.className = `share-attachment ${className}`.trim();
    item.removeAttribute('aria-busy');
    item.removeAttribute('role');
    item.replaceChildren();
  }

  renderImageAttachment(item: HTMLElement, url: string, title: string) {
    this.populateAttachmentSlot(item);
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'share-attachment__preview';
    button.setAttribute('aria-label', `Open ${title}`);
    const image = document.createElement('img');
    image.src = url;
    image.alt = title;
    image.loading = 'lazy';
    image.decoding = 'async';
    button.append(image);
    button.addEventListener('click', () => this.openLightbox(url, title));
    item.append(button);
  }

  renderAudioAttachment(
    item: HTMLElement,
    url: string,
    title: string,
    mimeType: string
  ) {
    this.populateAttachmentSlot(item, 'share-attachment--audio');
    const label = document.createElement('span');
    label.className = 'share-attachment__title';
    label.textContent = title;
    const audio = document.createElement('audio');
    audio.controls = true;
    audio.preload = 'none';
    const source = document.createElement('source');
    source.src = url;
    source.type = mimeType;
    audio.append(source);
    item.append(label, audio);
  }

  renderAttachmentError(item: HTMLElement) {
    this.populateAttachmentSlot(item, 'share-attachment--error');
    item.setAttribute('role', 'status');
    item.textContent = 'This attachment could not be loaded.';
  }

  openLightbox(url: string, title: string) {
    this.lightboxImage.src = url;
    this.lightboxImage.alt = title;
    this.lightbox.showModal();
    this.lightboxClose.focus();
  }

  closeLightbox() {
    this.lightbox.close();
  }
}

function readStoredRequestId(shareId: string) {
  try {
    return localStorage.getItem(`share_request_${shareId}`);
  } catch {
    return null;
  }
}

function storeRequestId(shareId: string, requestId: string) {
  try {
    localStorage.setItem(`share_request_${shareId}`, requestId);
  } catch {
    // The page remains usable through the manual status button this session.
  }
}

function removeStoredRequestId(shareId: string) {
  try {
    localStorage.removeItem(`share_request_${shareId}`);
  } catch {
    // Ignore unavailable storage.
  }
}

function parseAttachments(value: string): AttachmentRecord[] {
  const parsed: unknown = JSON.parse(value);
  if (!Array.isArray(parsed)) throw new Error('Attachment metadata is malformed');
  return parsed.slice(0, 50).filter((item): item is AttachmentRecord => {
    if (!item || typeof item !== 'object') return false;
    const record = item as Record<string, unknown>;
    return (
      typeof record.type === 'string' &&
      allowedAttachmentTypes.has(record.type) &&
      isSafeAttachmentPath(record.storagePath) &&
      typeof record.mimeType === 'string' &&
      allowedMimeTypes.has(record.mimeType) &&
      (record.title === undefined || typeof record.title === 'string')
    );
  });
}

function validatedShareContent(record: ShareRecord) {
  if (
    typeof record.encrypted_content !== 'string' ||
    typeof record.encrypted_content_nonce !== 'string'
  ) {
    throw new Error('Encrypted note data is malformed');
  }
  return {
    content: record.encrypted_content,
    nonce: record.encrypted_content_nonce,
    title: typeof record.note_title === 'string' ? record.note_title : 'Shared note'
  };
}

function previewShareState(view: ShareView, state: ShareScreen) {
  if (state === 'content') {
    view.renderNote(
      'Shared project notes',
      '## Launch checklist\n\n- Review the final copy\n- Confirm encrypted sync\n- Share the release notes\n\n> Only approved readers can see this content.'
    );
    view.resetAttachments();
    const slot = view.reserveAttachmentSlot();
    view.renderImageAttachment(
      slot,
      '/media/brand/app-icon-512.png',
      'Better Keep attachment preview'
    );
    view.show('content');
    return;
  }
  if (state === 'pending') view.showPendingRequest('preview1');
  else if (state === 'error') view.showError('Unable to load this shared note.');
  else view.show(state);
}

export async function startShareViewer() {
  const root = document.querySelector<HTMLElement>('[data-share-viewer]');
  if (!root) return;

  const view = new ShareView(root);
  const previewState = getLocalPreviewState(window.location);
  if (previewState) {
    previewShareState(view, previewState as ShareScreen);
    view.lightboxClose.addEventListener('click', () => view.closeLightbox());
    view.lightbox.addEventListener('click', (event) => {
      if (event.target === view.lightbox) view.closeLightbox();
    });
    return;
  }

  const { shareId, shareKey } = parseShareLocation(window.location);
  let gateway: FirebaseGateway;
  let share: ShareRecord | null = null;
  let requestId = shareId ? readStoredRequestId(shareId) : null;
  let stopListening: (() => void) | null = null;
  const objectUrls = new Set<string>();

  const stopRequestListener = () => {
    stopListening?.();
    stopListening = null;
  };

  const showRequest = () => {
    stopRequestListener();
    view.show('request');
  };

  const renderAttachments = async (attachments: AttachmentRecord[]) => {
    view.resetAttachments();
    const slots = attachments.map(() => view.reserveAttachmentSlot());
    await Promise.all(
      attachments.map(async (attachment, index) => {
        const slot = slots[index];
        try {
          const downloadUrl = await gateway.attachmentUrl(attachment.storagePath);
          const response = await fetch(downloadUrl, {
            cache: 'no-store',
            credentials: 'omit',
            referrerPolicy: 'no-referrer'
          });
          if (!response.ok) throw new Error('Attachment download failed');
          const encrypted = new Uint8Array(await response.arrayBuffer());
          if (encrypted.byteLength > MAX_ATTACHMENT_BYTES) {
            throw new Error('Attachment is too large');
          }
          const decrypted = await decryptShareBytes(encrypted, shareKey);
          const url = URL.createObjectURL(
            new Blob([decrypted], { type: attachment.mimeType })
          );
          objectUrls.add(url);
          const title = attachment.title?.trim() ||
            (attachment.type === 'audio' ? 'Audio recording' : 'Shared image');
          if (attachment.type === 'audio') {
            view.renderAudioAttachment(slot, url, title, attachment.mimeType);
          } else {
            view.renderImageAttachment(slot, url, title);
          }
        } catch {
          view.renderAttachmentError(slot);
        }
      })
    );
  };

  const decryptAndShow = async () => {
    if (!share || !shareKey) {
      view.showError('This share link is incomplete.');
      return;
    }
    try {
      view.show('loading', false);
      const encrypted = validatedShareContent(share);
      const markdown = await decryptShareText(
        encrypted.content,
        encrypted.nonce,
        shareKey
      );
      view.renderNote(encrypted.title, markdown);
      view.resetAttachments();
      view.show('content');

      if (
        typeof share.encrypted_attachments === 'string' &&
        typeof share.encrypted_attachments_nonce === 'string'
      ) {
        const attachmentJson = await decryptShareText(
          share.encrypted_attachments,
          share.encrypted_attachments_nonce,
          shareKey
        );
        await renderAttachments(parseAttachments(attachmentJson));
      }
    } catch {
      view.showError(
        'This note could not be decrypted. Check that the complete share link was copied.'
      );
    }
  };

  const handleRequest = async (record: Record<string, unknown> | null) => {
    const state = classifyRequestRecord(record);
    if (state === 'missing') {
      if (shareId) removeStoredRequestId(shareId);
      requestId = null;
      showRequest();
    } else if (state === 'approved') {
      stopRequestListener();
      await decryptAndShow();
    } else if (state === 'denied') {
      stopRequestListener();
      view.show('denied');
    } else if (state === 'pending' && requestId) {
      view.showPendingRequest(requestId);
    } else {
      view.showError('The access request returned an unexpected response.');
    }
  };

  const startRequestListener = () => {
    if (!shareId || !requestId || stopListening) return;
    stopListening = gateway.watchRequest(
      shareId,
      requestId,
      (record) => void handleRequest(record),
      () => view.showError('Unable to monitor this access request right now.')
    );
  };

  const checkRequest = async () => {
    if (!shareId || !requestId) {
      showRequest();
      return;
    }
    try {
      await handleRequest(await gateway.loadRequest(shareId, requestId));
      if (requestId) startRequestListener();
    } catch {
      view.showError('Unable to check this access request right now.');
    }
  };

  view.form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!shareId || !view.form.reportValidity()) return;
    view.setRequestBusy(true);
    try {
      requestId = await gateway.createRequest(shareId, {
        share_id: shareId,
        device_name: view.deviceName.value.trim(),
        platform: detectPlatform(navigator.userAgent),
        status: 'pending',
        requested_at: new Date().toISOString()
      });
      storeRequestId(shareId, requestId);
      view.showPendingRequest(requestId);
      startRequestListener();
    } catch {
      view.showError('Unable to send an access request right now.');
    } finally {
      view.setRequestBusy(false);
    }
  });

  view.checkButton.addEventListener('click', async () => {
    view.setCheckBusy(true);
    await checkRequest();
    view.setCheckBusy(false);
  });
  view.retryButton.addEventListener('click', () => window.location.reload());
  view.lightboxClose.addEventListener('click', () => view.closeLightbox());
  view.lightbox.addEventListener('click', (event) => {
    if (event.target === view.lightbox) view.closeLightbox();
  });
  window.addEventListener('pagehide', () => {
    stopRequestListener();
    for (const url of objectUrls) URL.revokeObjectURL(url);
  });

  if (!shareId) {
    view.show('notFound');
    return;
  }
  if (!shareKey) {
    view.showError('This link is missing its decryption key. Ask the owner to copy it again.');
    return;
  }

  try {
    gateway = await (await import('./share-firebase')).createFirebaseGateway();
    share = await gateway.loadShare(shareId);
    if (!share) {
      view.show('notFound');
      return;
    }

    const state = classifyShareRecord(share);
    if (state === 'expired') view.show('expired');
    else if (state === 'revoked') view.show('revoked');
    else if (state !== 'active') {
      view.showError('This shared note returned an unexpected response.');
    } else if (requestId) {
      await checkRequest();
    } else {
      showRequest();
    }
  } catch {
    view.showError('Unable to connect to the shared note service right now.');
  }
}

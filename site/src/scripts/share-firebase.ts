import {
  getApps,
  initializeApp,
  type FirebaseOptions
} from 'firebase/app';
import {
  addDoc,
  collection,
  connectFirestoreEmulator,
  doc,
  getDoc,
  getFirestore,
  onSnapshot,
  type DocumentData,
  type Firestore,
  type Unsubscribe
} from 'firebase/firestore';
import {
  connectStorageEmulator,
  getDownloadURL,
  getStorage,
  ref,
  type FirebaseStorage
} from 'firebase/storage';

export type ShareRecord = DocumentData & {
  status?: unknown;
  expires_at?: unknown;
  note_title?: unknown;
  encrypted_content?: unknown;
  encrypted_content_nonce?: unknown;
  encrypted_attachments?: unknown;
  encrypted_attachments_nonce?: unknown;
};

export type FirebaseGateway = {
  loadShare: (shareId: string) => Promise<ShareRecord | null>;
  createRequest: (
    shareId: string,
    data: Record<string, string>
  ) => Promise<string>;
  loadRequest: (
    shareId: string,
    requestId: string
  ) => Promise<DocumentData | null>;
  watchRequest: (
    shareId: string,
    requestId: string,
    onChange: (record: DocumentData | null) => void,
    onError: () => void
  ) => Unsubscribe;
  attachmentUrl: (storagePath: string) => Promise<string>;
};

function isLocalFirebaseHost() {
  return (
    window.location.port === '5002' ||
    window.location.hostname === 'localhost' ||
    window.location.hostname === '127.0.0.1'
  );
}

async function loadFirebaseConfig(): Promise<FirebaseOptions> {
  for (const path of ['/__/firebase/init.json', '/firebase-config.json']) {
    try {
      const response = await fetch(path, {
        cache: 'no-store',
        credentials: 'same-origin'
      });
      if (response.ok) return (await response.json()) as FirebaseOptions;
    } catch {
      // Try the static fallback after Firebase Hosting's auto-config endpoint.
    }
  }
  throw new Error('Firebase configuration is unavailable');
}

function createGateway(
  firestore: Firestore,
  storage: FirebaseStorage
): FirebaseGateway {
  return {
    async loadShare(shareId) {
      const snapshot = await getDoc(doc(firestore, 'shares', shareId));
      return snapshot.exists() ? snapshot.data() : null;
    },
    async createRequest(shareId, data) {
      const request = await addDoc(
        collection(firestore, 'shares', shareId, 'requests'),
        data
      );
      return request.id;
    },
    async loadRequest(shareId, requestId) {
      const snapshot = await getDoc(
        doc(firestore, 'shares', shareId, 'requests', requestId)
      );
      return snapshot.exists() ? snapshot.data() : null;
    },
    watchRequest(shareId, requestId, onChange, onError) {
      return onSnapshot(
        doc(firestore, 'shares', shareId, 'requests', requestId),
        (snapshot) => onChange(snapshot.exists() ? snapshot.data() : null),
        onError
      );
    },
    attachmentUrl(storagePath) {
      return getDownloadURL(ref(storage, storagePath));
    }
  };
}

export async function createFirebaseGateway(): Promise<FirebaseGateway> {
  const config = await loadFirebaseConfig();
  const existingApp = getApps().find((app) => app.name === 'share-viewer');
  const app = existingApp ?? initializeApp(config, 'share-viewer');
  const local = isLocalFirebaseHost();
  const databaseId = local ? '(default)' : 'better-keep';
  const firestore = getFirestore(app, databaseId);
  const storage = getStorage(app);

  if (local && !existingApp) {
    const host = window.location.hostname;
    connectFirestoreEmulator(firestore, host, 8080);
    connectStorageEmulator(storage, host, 9199);
  }

  return createGateway(firestore, storage);
}

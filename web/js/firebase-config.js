/**
 * Firebase Configuration
 * 
 * This file loads Firebase configuration from a JSON file at runtime.
 * 
 * Security Note:
 * - Firebase API keys are designed to be public (unlike secret API keys)
 * - Security is enforced through Firebase Security Rules, not by hiding the config
 * - The API key only identifies your Firebase project to Google's servers
 * - Actual data access is controlled by Firestore/Storage security rules
 */

// Database ID - use named database in production, default in emulators
const DATABASE_ID = 'better-keep';

// Emulator configuration for local development
const EMULATOR_CONFIG = {
  firestoreHost: 'localhost',
  firestorePort: 8080,
  storageHost: 'localhost',
  storagePort: 9199,
  hostingPort: 5002
};

/**
 * Detect if running in local development mode
 */
function isLocalDevelopment() {
  return window.location.hostname === 'localhost' ||
    window.location.hostname === '127.0.0.1';
}

/**
 * Get Firebase configuration from JSON file or Firebase Hosting auto-config
 */
async function getFirebaseConfig() {
  // Option 1: Try Firebase Hosting's auto-config first (works on Firebase Hosting)
  if (!isLocalDevelopment()) {
    try {
      const response = await fetch('/__/firebase/init.json');
      if (response.ok) {
        console.log('Loaded Firebase config from hosting');
        return await response.json();
      }
    } catch (e) {
      // Fall through to JSON file
    }
  }

  // Option 2: Load from JSON file
  const response = await fetch('/firebase-config.json');
  if (!response.ok) throw new Error('Failed to load Firebase config');
  return await response.json();
}

/**
 * Initialize Firebase with proper configuration
 */
async function initializeFirebaseApp() {
  const config = await getFirebaseConfig();

  firebase.initializeApp(config);

  // Use named database in production, default database for emulators
  const isLocal = isLocalDevelopment();
  const databaseId = isLocal ? '(default)' : DATABASE_ID;

  // For Firebase JS SDK v9+/compat, we need to get the Firestore instance differently for named databases
  // The compat SDK doesn't directly support named databases, so we use the modular API
  let db;
  if (isLocal) {
    db = firebase.firestore();
  } else {
    // Use the modular API for named database support
    const { getFirestore } = firebase.firestore;
    db = firebase.firestore();
    // Note: firebase-firestore-compat doesn't support named databases directly
    // We need to use the settings to specify the database
    db._delegate._databaseId.database = DATABASE_ID;
  }

  const storage = firebase.storage();

  // Connect to emulators if in local development
  if (isLocal) {
    console.log('Running on localhost - connecting to Firebase emulators');
    db.useEmulator(EMULATOR_CONFIG.firestoreHost, EMULATOR_CONFIG.firestorePort);
    storage.useEmulator(EMULATOR_CONFIG.storageHost, EMULATOR_CONFIG.storagePort);
  }

  return { db, storage, config };
}

// Export for use in other scripts
window.FirebaseConfig = {
  DATABASE_ID,
  EMULATOR_CONFIG,
  isLocalDevelopment,
  getFirebaseConfig,
  initializeFirebaseApp
};

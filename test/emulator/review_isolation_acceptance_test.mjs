import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { createHash } from "node:crypto";
import { createRequire } from "node:module";

import { deleteApp, initializeApp } from "firebase/app";
import {
  connectAuthEmulator,
  createUserWithEmailAndPassword,
  getAuth,
  signInWithEmailAndPassword,
  signOut,
} from "firebase/auth";
import {
  connectFirestoreEmulator,
  doc,
  getDoc,
  getFirestore,
  setDoc,
} from "firebase/firestore";
import {
  connectFunctionsEmulator,
  getFunctions,
  httpsCallable,
} from "firebase/functions";
import {
  connectStorageEmulator,
  getStorage,
  ref,
  uploadBytes,
} from "firebase/storage";

const projectId = "better-keep-notes";
const reviewEmail = "review@betterkeep.app";
const password = "emulator-review-password-123";
const emulatorUrl = (environmentName, fallbackPort) => {
  const url = new URL(
    `http://${process.env[environmentName] ?? `127.0.0.1:${fallbackPort}`}`,
  );
  if (["0.0.0.0", "[::]", "::"].includes(url.hostname)) {
    url.hostname = "127.0.0.1";
  }
  return url;
};
const authEmulatorUrl = emulatorUrl("FIREBASE_AUTH_EMULATOR_HOST", 9099);
const firestoreEmulatorUrl = emulatorUrl("FIRESTORE_EMULATOR_HOST", 8080);
const functionsEmulatorUrl = emulatorUrl(
  "BETTER_KEEP_FUNCTIONS_EMULATOR_HOST",
  15001,
);
const storageEmulatorUrl = emulatorUrl(
  "FIREBASE_STORAGE_EMULATOR_HOST",
  9199,
);
const requireFromFunctions = createRequire(
  new URL("../../functions/package.json", import.meta.url),
);
const admin = requireFromFunctions("firebase-admin");

let app;
let adminApp;
let adminDb;
let auth;
let db;
let functions;
let storage;
let reviewUser;

function hasCode(...codes) {
  return (error) => {
    assert.ok(
      codes.includes(error?.code),
      `Expected ${codes.join(" or ")}, received ${error?.code}: ${error}`,
    );
    return true;
  };
}

before(async () => {
  adminApp = admin.initializeApp({ projectId }, `review-admin-${process.pid}`);
  adminDb = admin.firestore(adminApp);
  app = initializeApp(
    {
      projectId,
      apiKey: "demo-api-key",
      appId: "demo-app-id",
      authDomain: "localhost",
      storageBucket: `${projectId}.appspot.com`,
    },
    `review-isolation-${process.pid}`,
  );
  auth = getAuth(app);
  db = getFirestore(app);
  functions = getFunctions(app, "us-central1");
  storage = getStorage(app);

  connectAuthEmulator(auth, authEmulatorUrl.origin, {
    disableWarnings: true,
  });
  connectFirestoreEmulator(
    db,
    firestoreEmulatorUrl.hostname,
    Number(firestoreEmulatorUrl.port),
  );
  connectFunctionsEmulator(
    functions,
    functionsEmulatorUrl.hostname,
    Number(functionsEmulatorUrl.port),
  );
  connectStorageEmulator(
    storage,
    storageEmulatorUrl.hostname,
    Number(storageEmulatorUrl.port),
  );

  reviewUser = (
    await createUserWithEmailAndPassword(auth, reviewEmail, password)
  ).user;
  const claimsResult = await httpsCallable(
    functions,
    "setEmulatorTestClaims",
  )();
  assert.equal(claimsResult.data.success, true);
  await signOut(auth);
  reviewUser = (
    await signInWithEmailAndPassword(auth, reviewEmail, password)
  ).user;
  const token = await reviewUser.getIdTokenResult(true);
  assert.equal(token.claims.appReview, true);
});

after(async () => {
  await signOut(auth).catch(() => {});
  await deleteApp(app);
  await adminApp.delete();
});

test("review token can read only its root private Firestore document", async () => {
  const rootSnapshot = await getDoc(doc(db, `users/${reviewUser.uid}`));
  assert.equal(rootSnapshot.exists(), true);
  assert.equal(rootSnapshot.data().email, reviewEmail);

  await assert.rejects(
    getDoc(doc(db, `users/${reviewUser.uid}/notes/private-note`)),
    hasCode("permission-denied"),
  );
  await assert.rejects(
    getDoc(doc(db, `users/${reviewUser.uid}/devices/private-device`)),
    hasCode("permission-denied"),
  );
});

test("review token cannot mutate Firestore or Storage", async () => {
  await assert.rejects(
    setDoc(doc(db, `users/${reviewUser.uid}`), { displayName: "Review" }),
    hasCode("permission-denied"),
  );
  await assert.rejects(
    setDoc(doc(db, `users/${reviewUser.uid}/notes/note-1`), {
      title: "ciphertext",
    }),
    hasCode("permission-denied"),
  );
  await assert.rejects(
    setDoc(doc(db, "shares/review-share"), {
      owner_uid: reviewUser.uid,
      status: "active",
    }),
    hasCode("permission-denied"),
  );

  await assert.rejects(
    uploadBytes(
      ref(storage, `users/${reviewUser.uid}/attachments/private.bin`),
      new Uint8Array([1]),
    ),
    hasCode("storage/unauthorized"),
  );
  await assert.rejects(
    uploadBytes(
      ref(
        storage,
        `shares/${reviewUser.uid}/review-share/attachments/private.bin`,
      ),
      new Uint8Array([2]),
    ),
    hasCode("storage/unauthorized"),
  );
});

test("review token is rejected by mutation and account-link callables", async () => {
  await assert.rejects(
    httpsCallable(functions, "createCustomToken")({}),
    hasCode("functions/permission-denied"),
  );
  await assert.rejects(
    httpsCallable(functions, "requestAccountLinkOtp")({
      provider: "github.com",
    }),
    hasCode("functions/permission-denied"),
  );
  await assert.rejects(
    httpsCallable(functions, "scheduleAccountDeletion")({}),
    hasCode("functions/permission-denied"),
  );
  await assert.rejects(
    httpsCallable(functions, "checkExistingSubscription")({}),
    hasCode("functions/permission-denied"),
  );
});

test("password reset is suppressed and forged OAuth link state is rejected", async () => {
  const resetResult = await httpsCallable(functions, "sendPasswordResetOtp")({
    email: reviewEmail,
  });
  assert.equal(resetResult.data.success, true);

  await assert.rejects(
    httpsCallable(functions, "verifyPasswordResetOtp")({
      email: reviewEmail,
      otp: "000000",
    }),
    hasCode("functions/permission-denied"),
  );

  const legacyState = Buffer.from(
    JSON.stringify({
      provider: "github",
      mode: "link",
      uid: reviewUser.uid,
      redirect: "betterkeep",
    }),
  ).toString("base64");
  const response = await fetch(
    `${functionsEmulatorUrl.origin}/${projectId}/us-central1/oauthStart` +
      `?provider=github&mode=link&redirect=betterkeep` +
      `&uid=${encodeURIComponent(reviewUser.uid)}` +
      `&state=${encodeURIComponent(legacyState)}`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 400);

  const passwordResetId = createHash("sha256")
    .update(reviewEmail)
    .digest("hex");
  const passwordResetDocument = await fetch(
    `${firestoreEmulatorUrl.origin}/v1/projects/${projectId}` +
      `/databases/(default)/documents/passwordResetOtps/${passwordResetId}`,
    { headers: { Authorization: "Bearer owner" } },
  );
  assert.equal(passwordResetDocument.status, 404);
});

test("OAuth v2 start is browser-bound and creates no legacy state document", async () => {
  const query = new URLSearchParams({
    provider: "github",
    mode: "signin",
    redirect: "popup",
    flowVersion: "2",
    completionChallenge: "a".repeat(43),
    clientTransactionId: "b".repeat(22),
    clientOrigin: "http://localhost:63630",
  });
  const response = await fetch(
    `${functionsEmulatorUrl.origin}/${projectId}/us-central1/oauthStart?${query}`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 302);
  assert.match(response.headers.get("location"), /^https:\/\/github\.com\//);
  assert.match(response.headers.get("set-cookie"), /__Host-bk-oauth=/);
  assert.match(response.headers.get("set-cookie"), /HttpOnly/);
  assert.equal(response.headers.get("cache-control"), "no-store");

  const rejectedOrigin = new URLSearchParams(query);
  rejectedOrigin.set("clientOrigin", "https://betterkeep.app.evil.test");
  const rejected = await fetch(
    `${functionsEmulatorUrl.origin}/${projectId}/us-central1/oauthStart?${rejectedOrigin}`,
    { redirect: "manual" },
  );
  assert.equal(rejected.status, 403);
  assert.equal((await adminDb.collection("oauthStates").get()).size, 0);
});

test("one OTP cannot mint multiple link sessions concurrently", async () => {
  await signOut(auth);
  const ordinaryUser = (
    await createUserWithEmailAndPassword(
      auth,
      `link-concurrency-${process.pid}@example.com`,
      password,
    )
  ).user;
  const otp = "123456";
  const otpRef = adminDb
    .collection("users")
    .doc(ordinaryUser.uid)
    .collection("otpVerification")
    .doc("accountLink");
  await otpRef.set({
    otpHash: createHash("sha256").update(otp).digest("hex"),
    provider: "github.com",
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + 60_000),
    attempts: 0,
    createdAt: admin.firestore.Timestamp.now(),
  });

  const attempts = await Promise.allSettled([
    httpsCallable(functions, "verifyAccountLinkOtp")({
      provider: "github.com",
      otp,
    }),
    httpsCallable(functions, "verifyAccountLinkOtp")({
      provider: "github.com",
      otp,
    }),
  ]);
  assert.equal(
    attempts.filter((result) => result.status === "fulfilled").length,
    1,
  );
  const rejected = attempts.filter((result) => result.status === "rejected");
  assert.equal(rejected.length, 1);
  assert.equal(rejected[0].reason.code, "functions/failed-precondition");

  const issuedSessions = await adminDb
    .collection("accountLinkSessions")
    .where("uid", "==", ordinaryUser.uid)
    .get();
  assert.equal(issuedSessions.size, 1);

  await Promise.all([
    otpRef.delete(),
    ...issuedSessions.docs.map((document) => document.ref.delete()),
  ]);
});

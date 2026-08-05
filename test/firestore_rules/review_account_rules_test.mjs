import { after, before, beforeEach, test } from "node:test";
import { readFile } from "node:fs/promises";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  updateDoc,
} from "firebase/firestore";

const projectId = "demo-better-keep-review-firestore-rules";
const reviewUid = "review-uid";
const proExpiry = 4102444800000;
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules: await readFile("firestore.rules", "utf8") },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await Promise.all([
      setDoc(doc(db, `users/${reviewUid}`), { email: "review@betterkeep.app" }),
      setDoc(doc(db, `users/${reviewUid}/notes/note-1`), { title: "ciphertext" }),
      setDoc(doc(db, `users/${reviewUid}/devices/device-1`), { key: "public" }),
      setDoc(doc(db, `users/${reviewUid}/subscription/status`), { plan: "pro" }),
      setDoc(doc(db, "shares/review-share"), {
        owner_uid: reviewUid,
        status: "active",
      }),
    ]);
  });
});

after(async () => {
  await testEnv.cleanup();
});

function firestoreFor(uid, claims = {}) {
  return testEnv.authenticatedContext(uid, claims).firestore();
}

const reviewClaims = [
  {
    name: "configured email only",
    claims: {
      email: "review@betterkeep.app",
      plan: "pro",
      planExpiresAt: proExpiry,
    },
  },
  {
    name: "signed review claim only",
    claims: {
      email: "other@example.com",
      appReview: true,
      plan: "pro",
      planExpiresAt: proExpiry,
    },
  },
  {
    name: "configured email and signed claim",
    claims: {
      email: "review@betterkeep.app",
      appReview: true,
      plan: "pro",
      planExpiresAt: proExpiry,
    },
  },
];

for (const scenario of reviewClaims) {
  test(`${scenario.name} has only the essential private root read`, async () => {
    const db = firestoreFor(reviewUid, scenario.claims);

    await assertSucceeds(getDoc(doc(db, `users/${reviewUid}`)));
    await assertFails(getDoc(doc(db, `users/${reviewUid}/notes/note-1`)));
    await assertFails(getDoc(doc(db, `users/${reviewUid}/devices/device-1`)));
    await assertFails(
      getDoc(doc(db, `users/${reviewUid}/subscription/status`)),
    );
    await assertSucceeds(getDoc(doc(db, "shares/review-share")));
  });

  test(`${scenario.name} cannot create, update, or delete cloud data`, async () => {
    const db = firestoreFor(reviewUid, scenario.claims);

    await assertFails(
      updateDoc(doc(db, `users/${reviewUid}`), { lastSeen: new Date() }),
    );
    await assertFails(
      setDoc(doc(db, `users/${reviewUid}/notes/note-2`), {
        title: "ciphertext",
      }),
    );
    await assertFails(
      deleteDoc(doc(db, `users/${reviewUid}/notes/note-1`)),
    );
    await assertFails(
      setDoc(doc(db, `users/${reviewUid}/devices/device-2`), {
        key: "public",
      }),
    );
    await assertFails(
      setDoc(doc(db, "shares/new-review-share"), {
        owner_uid: reviewUid,
        status: "active",
      }),
    );
    await assertFails(
      setDoc(doc(db, "shares/review-share/requests/request-1"), {
        status: "pending",
      }),
    );
    await assertFails(deleteDoc(doc(db, "shares/review-share")));
  });
}

test("ordinary Pro owners retain existing write permissions", async () => {
  const uid = "ordinary-pro";
  const db = firestoreFor(uid, {
    email: "ordinary@example.com",
    plan: "pro",
    planExpiresAt: proExpiry,
  });

  await assertSucceeds(setDoc(doc(db, `users/${uid}`), { email: "ordinary@example.com" }));
  await assertSucceeds(setDoc(doc(db, `users/${uid}/notes/note-1`), { title: "ciphertext" }));
  await assertSucceeds(setDoc(doc(db, `users/${uid}/devices/device-1`), { key: "public" }));
  await assertSucceeds(
    setDoc(doc(db, "shares/ordinary-share"), {
      owner_uid: uid,
      status: "active",
    }),
  );
});

test("ordinary owners cannot forge backend authentication state", async () => {
  const uid = "ordinary-auth-state";
  const db = firestoreFor(uid, { email: "ordinary@example.com" });

  for (const path of [
    `users/${uid}/otpVerification/accountLink`,
    `users/${uid}/pendingProviderLinks/google.com`,
    `users/${uid}/auditLog/forged`,
    "accountLinkSessions/forged",
    "oauthCompletions/forged",
    "oauthStates/forged",
  ]) {
    await assertFails(getDoc(doc(db, path)));
    await assertFails(setDoc(doc(db, path), { forged: true }));
  }
});

test("ordinary Free owners retain existing read and cleanup permissions", async () => {
  const uid = "ordinary-free";
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, `users/${uid}/notes/existing-note`), {
      title: "ciphertext",
    });
  });
  const db = firestoreFor(uid, { email: "free@example.com" });

  await assertSucceeds(
    setDoc(doc(db, `users/${uid}`), { email: "free@example.com" }),
  );
  await assertSucceeds(getDoc(doc(db, `users/${uid}`)));
  await assertSucceeds(getDoc(doc(db, `users/${uid}/notes/existing-note`)));
  await assertFails(
    setDoc(doc(db, `users/${uid}/notes/new-note`), { title: "ciphertext" }),
  );
  await assertSucceeds(
    deleteDoc(doc(db, `users/${uid}/notes/existing-note`)),
  );
  await assertSucceeds(
    setDoc(doc(db, `users/${uid}/devices/device-1`), { key: "public" }),
  );
  await assertSucceeds(
    setDoc(doc(db, "shares/ordinary-free-share"), {
      owner_uid: uid,
      status: "active",
    }),
  );
});

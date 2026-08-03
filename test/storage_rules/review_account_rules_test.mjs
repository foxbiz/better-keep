import { after, before, test } from "node:test";
import { readFile } from "node:fs/promises";

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  deleteObject,
  getBytes,
  ref,
  uploadBytes,
} from "firebase/storage";

const projectId = "demo-better-keep-review-storage-rules";
const reviewUid = "review-uid";
const proExpiry = 4102444800000;
const userPath = `users/${reviewUid}/attachments/private.bin`;
const sharePath = `shares/${reviewUid}/share-1/attachments/public.bin`;
let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    storage: { rules: await readFile("storage.rules", "utf8") },
  });
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await uploadBytes(ref(context.storage(), userPath), new Uint8Array([1]));
    await uploadBytes(ref(context.storage(), sharePath), new Uint8Array([2]));
  });
});

after(async () => {
  await testEnv.cleanup();
});

function storageFor(uid, claims = {}) {
  return testEnv.authenticatedContext(uid, claims).storage();
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
  test(`${scenario.name} cannot read or mutate private user storage`, async () => {
    const storage = storageFor(reviewUid, scenario.claims);
    await assertFails(getBytes(ref(storage, userPath)));
    await assertFails(
      uploadBytes(
        ref(storage, `users/${reviewUid}/attachments/new.bin`),
        new Uint8Array([3]),
      ),
    );
    await assertFails(deleteObject(ref(storage, userPath)));
  });

  test(`${scenario.name} keeps public reads but cannot write share files`, async () => {
    const storage = storageFor(reviewUid, scenario.claims);
    await assertSucceeds(getBytes(ref(storage, sharePath)));
    await assertFails(
      uploadBytes(
        ref(storage, `shares/${reviewUid}/share-2/attachments/new.bin`),
        new Uint8Array([4]),
      ),
    );
    await assertFails(deleteObject(ref(storage, sharePath)));
  });
}

test("ordinary Pro owners retain user and share upload permissions", async () => {
  const uid = "ordinary-pro";
  const storage = storageFor(uid, {
    email: "ordinary@example.com",
    plan: "pro",
    planExpiresAt: proExpiry,
  });

  await assertSucceeds(
    uploadBytes(
      ref(storage, `users/${uid}/attachments/private.bin`),
      new Uint8Array([5]),
    ),
  );
  await assertSucceeds(
    uploadBytes(
      ref(storage, `shares/${uid}/share-1/attachments/public.bin`),
      new Uint8Array([6]),
    ),
  );
});

test("ordinary Free owners retain reads and public-share uploads", async () => {
  const uid = "ordinary-free";
  const privatePath = `users/${uid}/attachments/private.bin`;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await uploadBytes(
      ref(context.storage(), privatePath),
      new Uint8Array([7]),
    );
  });
  const storage = storageFor(uid, { email: "free@example.com" });

  await assertSucceeds(getBytes(ref(storage, privatePath)));
  await assertFails(
    uploadBytes(
      ref(storage, `users/${uid}/attachments/new.bin`),
      new Uint8Array([8]),
    ),
  );
  await assertSucceeds(
    uploadBytes(
      ref(storage, `shares/${uid}/share-1/attachments/public.bin`),
      new Uint8Array([9]),
    ),
  );
});

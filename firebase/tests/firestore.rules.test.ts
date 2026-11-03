// Runs against the Firestore emulator: `npm test` starts it via `firebase emulators:exec`.
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
  type RulesTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  addDoc,
  Bytes,
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  where,
  type Firestore,
} from "firebase/firestore";
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, beforeEach, describe, it } from "vitest";

let testEnv: RulesTestEnvironment;

beforeAll(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "demo-where-are-you",
    firestore: { rules: readFileSync(new URL("../firestore.rules", import.meta.url), "utf8") },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
});

// MARK: Helpers

// The test contexts hand out compat Firestore instances, which the modular API accepts.
function firestoreFor(uid?: string): Firestore {
  const context = uid ? testEnv.authenticatedContext(uid) : testEnv.unauthenticatedContext();
  return context.firestore() as unknown as Firestore;
}

const get = (uid: string | undefined, path: string) => getDoc(doc(firestoreFor(uid), path));
const set = (uid: string, path: string, data: unknown) => setDoc(doc(firestoreFor(uid), path), data as Record<string, unknown>);
const update = (uid: string, path: string, data: Record<string, unknown>) => updateDoc(doc(firestoreFor(uid), path), data);
const remove = (uid: string, path: string) => deleteDoc(doc(firestoreFor(uid), path));
const list = (uid: string, path: string) => getDocs(collection(firestoreFor(uid), path));
const add = (uid: string, path: string, data: Record<string, unknown>) => addDoc(collection(firestoreFor(uid), path), data);

function bytes(count: number) {
  return Bytes.fromUint8Array(new Uint8Array(count).fill(7));
}

const keyId = "A".repeat(22);
const inviteToken = "T".repeat(43);

function sealedBox(overrides: Record<string, unknown> = {}) {
  return {
    version: 1,
    senderKeyId: keyId,
    recipientKeyId: "B".repeat(22),
    encapsulatedKey: bytes(32),
    ciphertext: bytes(128),
    ...overrides,
  };
}

function userDoc(overrides: Record<string, unknown> = {}) {
  return { publicKey: bytes(32), keyId, updatedAt: serverTimestamp(), ...overrides };
}

function inHours(hours: number) {
  return Timestamp.fromMillis(Date.now() + hours * 3_600_000);
}

/** Seeds documents as an admin would, bypassing the rules. */
async function seed(documents: Record<string, Record<string, unknown>>) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    for (const [path, data] of Object.entries(documents)) {
      await setDoc(doc(context.firestore() as unknown as Firestore, path), data);
    }
  });
}

const aliceAndBobAreFriends = { "friendships/alice_bob": { members: ["alice", "bob"] } };

// MARK: Tests

describe("users", () => {
  it("lets signed-in users read one public key, but not list users", async () => {
    await seed({ "users/bob": { publicKey: bytes(32), keyId } });

    await assertSucceeds(get("alice", "users/bob"));
    await assertFails(get(undefined, "users/bob"));
    await assertFails(list("alice", "users"));
  });

  it("lets users publish only their own, well-formed key", async () => {
    await assertSucceeds(set("alice", "users/alice", userDoc()));
    await assertFails(set("alice", "users/bob", userDoc()));
    await assertFails(set("alice", "users/alice", userDoc({ publicKey: bytes(31) })));
    await assertFails(set("alice", "users/alice", userDoc({ keyId: "short" })));
    await assertFails(set("alice", "users/alice", userDoc({ email: "alice@example.com" })));
    await assertFails(set("alice", "users/alice", userDoc({ updatedAt: Timestamp.now() })));
  });

  it("leaves deleting users to the deleteAccount function", async () => {
    await seed({ "users/alice": { publicKey: bytes(32), keyId } });
    await assertFails(remove("alice", "users/alice"));
  });
});

describe("private documents", () => {
  it("keeps the sealed profile private to its owner", async () => {
    const profile = { box: sealedBox(), updatedAt: serverTimestamp() };

    await assertSucceeds(set("alice", "users/alice/private/profile", profile));
    await assertSucceeds(get("alice", "users/alice/private/profile"));
    await assertFails(get("bob", "users/alice/private/profile"));
    await assertFails(set("bob", "users/alice/private/profile", profile));
  });

  it("only stores well-formed sealed boxes", async () => {
    const write = (box: unknown) =>
      set("alice", "users/alice/private/profile", { box, updatedAt: serverTimestamp() });

    await assertFails(write(sealedBox({ version: 2 })));
    await assertFails(write(sealedBox({ encapsulatedKey: bytes(31) })));
    await assertFails(write(sealedBox({ ciphertext: bytes(5000) })));
    await assertFails(write(sealedBox({ plaintext: "oops" })));
    await assertFails(write("not a box"));
  });

  it("allows only known private documents", async () => {
    await assertFails(set("alice", "users/alice/private/secrets", { anything: true }));
  });

  it("keeps sharing settings private and well-formed", async () => {
    const sharing = { isEnabled: true, friendUIDs: ["bob"], activeDeviceId: "phone", updatedAt: serverTimestamp() };

    await assertSucceeds(set("alice", "users/alice/private/sharing", sharing));
    await assertSucceeds(set("alice", "users/alice/private/sharing", { ...sharing, activeDeviceId: null }));
    await assertFails(set("alice", "users/alice/private/sharing", { ...sharing, isEnabled: "yes" }));
    await assertFails(get("bob", "users/alice/private/sharing"));
  });

  it("keeps notification prefs and devices private", async () => {
    const prefs = {
      receiveAlerts: true,
      mutedAlertSenders: [],
      allowAlertsOnMe: true,
      blockedAlertRequesters: [],
      updatedAt: serverTimestamp(),
    };
    const device = { fcmToken: "token", updatedAt: serverTimestamp() };

    await assertSucceeds(set("alice", "users/alice/private/prefs", prefs));
    await assertSucceeds(set("alice", "users/alice/devices/phone", device));
    await assertFails(get("bob", "users/alice/private/prefs"));
    await assertFails(get("bob", "users/alice/devices/phone"));
    await assertFails(set("bob", "users/alice/devices/phone", device));
  });
});

describe("invites", () => {
  const invite = (overrides: Record<string, unknown> = {}) => ({
    inviterUid: "alice",
    inviterKeyId: keyId,
    createdAt: serverTimestamp(),
    expiresAt: inHours(48),
    ...overrides,
  });

  it("lets users create their own invites that expire within a week", async () => {
    await assertSucceeds(set("alice", `invites/${inviteToken}`, invite()));
    await assertFails(set("alice", `invites/${"U".repeat(43)}`, invite({ inviterUid: "bob" })));
    await assertFails(set("alice", `invites/${"V".repeat(43)}`, invite({ expiresAt: inHours(24 * 8) })));
    await assertFails(set("alice", "invites/short-token", invite()));
  });

  it("can be fetched by token but not listed or changed", async () => {
    await seed({ [`invites/${inviteToken}`]: { inviterUid: "alice", inviterKeyId: keyId } });

    await assertSucceeds(get("bob", `invites/${inviteToken}`));
    await assertFails(list("bob", "invites"));
    await assertFails(update("bob", `invites/${inviteToken}`, { inviterUid: "bob" }));
    await assertFails(remove("bob", `invites/${inviteToken}`));
    await assertSucceeds(remove("alice", `invites/${inviteToken}`));
  });
});

describe("friendships", () => {
  it("are created only by functions and visible only to members", async () => {
    await assertFails(set("alice", "friendships/alice_bob", { members: ["alice", "bob"] }));

    await seed(aliceAndBobAreFriends);
    await assertSucceeds(get("alice", "friendships/alice_bob"));
    await assertSucceeds(getDocs(query(collection(firestoreFor("bob"), "friendships"), where("members", "array-contains", "bob"))));
    await assertFails(get("carol", "friendships/alice_bob"));
    await assertFails(remove("alice", "friendships/alice_bob"));
  });
});

describe("shares", () => {
  const share = (overrides: Record<string, unknown> = {}) => ({
    profile: sealedBox(),
    location: sealedBox(),
    isSharingLocation: true,
    updatedAt: serverTimestamp(),
    ...overrides,
  });

  it("lets friends share with each other", async () => {
    await seed(aliceAndBobAreFriends);

    await assertSucceeds(set("alice", "inboxes/bob/shares/alice", share()));
    await assertSucceeds(set("alice", "inboxes/bob/shares/alice", share({ location: null, isSharingLocation: false })));
    await assertSucceeds(get("bob", "inboxes/bob/shares/alice"));
    await assertSucceeds(list("bob", "inboxes/bob/shares"));
  });

  it("blocks strangers, impersonation and snooping", async () => {
    await seed(aliceAndBobAreFriends);

    await assertFails(set("carol", "inboxes/bob/shares/carol", share()));
    await assertFails(set("alice", "inboxes/alice/shares/bob", share()));
    await assertFails(set("alice", "inboxes/alice/shares/alice", share()));

    await seed({ "inboxes/bob/shares/alice": share({ updatedAt: Timestamp.now() }) });
    await assertFails(get("carol", "inboxes/bob/shares/alice"));
    await assertFails(list("carol", "inboxes/bob/shares"));
  });

  it("can be removed by either side", async () => {
    await seed({ ...aliceAndBobAreFriends, "inboxes/bob/shares/alice": share({ updatedAt: Timestamp.now() }) });

    await assertSucceeds(remove("bob", "inboxes/bob/shares/alice"));
  });
});

describe("alert requests", () => {
  const request = (overrides: Record<string, unknown> = {}) => ({
    requesterUid: "alice",
    payload: sealedBox(),
    requesterCopy: sealedBox(),
    createdAt: serverTimestamp(),
    ...overrides,
  });

  it("can be sent by a friend and read or removed by either side", async () => {
    await seed(aliceAndBobAreFriends);

    await assertSucceeds(set("alice", "inboxes/bob/alertRequests/r1", request()));
    await assertSucceeds(get("bob", "inboxes/bob/alertRequests/r1"));
    await assertSucceeds(get("alice", "inboxes/bob/alertRequests/r1"));
    await assertFails(update("alice", "inboxes/bob/alertRequests/r1", { payload: sealedBox() }));
    await assertSucceeds(remove("bob", "inboxes/bob/alertRequests/r1"));
  });

  it("can't be sent by strangers or in someone else's name", async () => {
    await seed(aliceAndBobAreFriends);

    await assertFails(set("carol", "inboxes/bob/alertRequests/r2", request({ requesterUid: "carol" })));
    await assertFails(set("carol", "inboxes/bob/alertRequests/r3", request()));
  });

  it("needs the requester's own copy", async () => {
    await seed(aliceAndBobAreFriends);

    await assertFails(set("alice", "inboxes/bob/alertRequests/r4", request({ requesterCopy: "plain text" })));
  });
});

describe("notification events", () => {
  const event = (overrides: Record<string, unknown> = {}) => ({
    fromUid: "alice",
    toUid: "bob",
    payload: sealedBox(),
    createdAt: serverTimestamp(),
    expiresAt: inHours(12),
    ...overrides,
  });

  it("can only be created, by a friend, in their own name", async () => {
    await seed(aliceAndBobAreFriends);

    await assertSucceeds(add("alice", "notificationEvents", event()));
    await assertFails(add("alice", "notificationEvents", event({ toUid: "carol" })));
    await assertFails(add("carol", "notificationEvents", event({ fromUid: "alice" })));
    await assertFails(add("alice", "notificationEvents", event({ expiresAt: inHours(48) })));
  });

  it("can't be read back by clients", async () => {
    await seed({ "notificationEvents/e1": { fromUid: "alice", toUid: "bob" } });

    await assertFails(get("bob", "notificationEvents/e1"));
    await assertFails(get("alice", "notificationEvents/e1"));
  });
});

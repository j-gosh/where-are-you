// Runs against the Firestore emulator: `npm test` starts it via `firebase emulators:exec`,
// which sets FIRESTORE_EMULATOR_HOST for firebase-admin.
import { deleteApp, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, Timestamp, type Firestore } from "firebase-admin/firestore";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { acceptInviteFor, friendshipId, MAX_FRIENDS, removeFriendship } from "../src/friendships";

const projectId = "demo-where-are-you";
const token = "T".repeat(43);

let app: App;
let db: Firestore;

beforeAll(() => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error("Run with `npm test` so the Firestore emulator is running.");
  }
  app = initializeApp({ projectId }, "friendships-test");
  db = getFirestore(app);
});

afterAll(async () => {
  await deleteApp(app);
});

beforeEach(async () => {
  await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`, {
    method: "DELETE",
  });
});

function inHours(hours: number) {
  return Timestamp.fromMillis(Date.now() + hours * 3_600_000);
}

async function exists(path: string): Promise<boolean> {
  return (await db.doc(path).get()).exists;
}

/** The HttpsError code and details.reason a rejected acceptInviteFor carries. */
async function rejection(promise: Promise<unknown>): Promise<{ code?: string; reason?: string }> {
  try {
    await promise;
  } catch (error) {
    const httpsError = error as { code?: string; details?: { reason?: string } };
    return { code: httpsError.code, reason: httpsError.details?.reason };
  }
  throw new Error("Expected a rejection");
}

describe("friendshipId", () => {
  it("is the same in either order", () => {
    expect(friendshipId("bob", "alice")).toBe("alice_bob");
    expect(friendshipId("alice", "bob")).toBe("alice_bob");
  });
});

describe("acceptInviteFor", () => {
  it("creates the friendship and uses up the invite", async () => {
    await db.doc(`invites/${token}`).set({ inviterUid: "alice", inviterKeyId: "k", expiresAt: inHours(24) });

    const result = await acceptInviteFor(db, "bob", token);

    expect(result).toEqual({ inviterUid: "alice" });
    expect((await db.doc("friendships/alice_bob").get()).get("members")).toEqual(["alice", "bob"]);
    expect(await exists(`invites/${token}`)).toBe(false);
  });

  it("succeeds again for existing friends, so retries are safe", async () => {
    await db.doc("friendships/alice_bob").set({ members: ["alice", "bob"] });
    await db.doc(`invites/${token}`).set({ inviterUid: "alice", inviterKeyId: "k", expiresAt: inHours(24) });

    expect(await acceptInviteFor(db, "bob", token)).toEqual({ inviterUid: "alice" });
    expect(await exists(`invites/${token}`)).toBe(false);
  });

  it("rejects missing, expired and own invites", async () => {
    expect(await rejection(acceptInviteFor(db, "bob", token))).toMatchObject({ code: "not-found" });

    await db.doc(`invites/${token}`).set({ inviterUid: "alice", inviterKeyId: "k", expiresAt: inHours(-1) });
    expect(await rejection(acceptInviteFor(db, "bob", token))).toMatchObject({ code: "failed-precondition", reason: "expired" });

    await db.doc(`invites/${token}`).set({ inviterUid: "alice", inviterKeyId: "k", expiresAt: inHours(24) });
    expect(await rejection(acceptInviteFor(db, "alice", token))).toMatchObject({ code: "failed-precondition", reason: "own-invite" });
    expect(await exists("friendships/alice_alice")).toBe(false);
  });

  it("enforces the friend limit", async () => {
    const batch = db.batch();
    for (let index = 0; index < MAX_FRIENDS; index++) {
      batch.set(db.doc(`friendships/${friendshipId("alice", `friend${index}`)}`), { members: ["alice", `friend${index}`].sort() });
    }
    await batch.commit();
    await db.doc(`invites/${token}`).set({ inviterUid: "alice", inviterKeyId: "k", expiresAt: inHours(24) });

    expect(await rejection(acceptInviteFor(db, "bob", token))).toMatchObject({ code: "resource-exhausted" });
    expect(await exists(`invites/${token}`)).toBe(true);
  });
});

describe("removeFriendship", () => {
  it("deletes the friendship, both shares and alerts set on each other", async () => {
    await db.doc("friendships/alice_bob").set({ members: ["alice", "bob"] });
    await db.doc("inboxes/alice/shares/bob").set({ isSharingLocation: true });
    await db.doc("inboxes/bob/shares/alice").set({ isSharingLocation: true });
    await db.doc("inboxes/alice/alertRequests/r1").set({ requesterUid: "bob" });
    await db.doc("inboxes/bob/alertRequests/r2").set({ requesterUid: "alice" });
    await db.doc("inboxes/bob/alertRequests/r3").set({ requesterUid: "carol" });

    await removeFriendship(db, "alice", "bob");

    for (const path of ["friendships/alice_bob", "inboxes/alice/shares/bob", "inboxes/bob/shares/alice", "inboxes/alice/alertRequests/r1", "inboxes/bob/alertRequests/r2"]) {
      expect(await exists(path), path).toBe(false);
    }
    expect(await exists("inboxes/bob/alertRequests/r3")).toBe(true);
  });

  it("succeeds when there's nothing to remove", async () => {
    await removeFriendship(db, "alice", "bob");
  });
});

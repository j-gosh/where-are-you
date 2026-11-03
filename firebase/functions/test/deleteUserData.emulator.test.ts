// Runs against the Firestore emulator: `npm test` starts it via `firebase emulators:exec`,
// which sets FIRESTORE_EMULATOR_HOST for firebase-admin.
import { deleteApp, initializeApp, type App } from "firebase-admin/app";
import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { deleteUserData } from "../src/deleteUserData";

const projectId = "demo-where-are-you";

let app: App;
let db: Firestore;

beforeAll(() => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error("Run with `npm test` so the Firestore emulator is running.");
  }
  app = initializeApp({ projectId }, "deleteUserData-test");
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

async function exists(path: string): Promise<boolean> {
  return (await db.doc(path).get()).exists;
}

describe("deleteUserData", () => {
  it("removes the user's documents, what they shared, and what they requested", async () => {
    await db.doc("users/alice").set({ keyId: "a" });
    await db.doc("users/alice/private/profile").set({ box: {} });
    await db.doc("users/alice/devices/phone").set({ fcmToken: "t" });
    await db.doc("friendships/alice_bob").set({ members: ["alice", "bob"] });
    await db.doc("inboxes/bob/shares/alice").set({ isSharingLocation: true });
    await db.doc("inboxes/alice/shares/bob").set({ isSharingLocation: true });
    await db.doc("inboxes/bob/alertRequests/r1").set({ requesterUid: "alice" });
    await db.doc("inboxes/alice/alertRequests/r2").set({ requesterUid: "bob" });
    await db.doc("invites/token1").set({ inviterUid: "alice" });
    await db.doc("notificationEvents/e1").set({ fromUid: "alice", toUid: "bob" });
    await db.doc("notificationEvents/e2").set({ fromUid: "bob", toUid: "alice" });

    await deleteUserData(db, "alice");

    for (const path of [
      "users/alice",
      "users/alice/private/profile",
      "users/alice/devices/phone",
      "friendships/alice_bob",
      "inboxes/bob/shares/alice",
      "inboxes/alice/shares/bob",
      "inboxes/bob/alertRequests/r1",
      "inboxes/alice/alertRequests/r2",
      "invites/token1",
      "notificationEvents/e1",
      "notificationEvents/e2",
    ]) {
      expect(await exists(path), path).toBe(false);
    }
  });

  it("leaves other people's data alone", async () => {
    await db.doc("users/bob").set({ keyId: "b" });
    await db.doc("friendships/bob_carol").set({ members: ["bob", "carol"] });
    await db.doc("inboxes/bob/shares/carol").set({ isSharingLocation: true });
    await db.doc("inboxes/bob/alertRequests/r3").set({ requesterUid: "carol" });
    await db.doc("invites/token2").set({ inviterUid: "bob" });

    await deleteUserData(db, "alice");

    for (const path of ["users/bob", "friendships/bob_carol", "inboxes/bob/shares/carol", "inboxes/bob/alertRequests/r3", "invites/token2"]) {
      expect(await exists(path), path).toBe(true);
    }
  });

  it("can run again after everything is already gone", async () => {
    await deleteUserData(db, "alice");
    await deleteUserData(db, "alice");
  });
});

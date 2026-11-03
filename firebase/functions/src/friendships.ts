import { FieldValue, Timestamp, type Firestore, type Query } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";

/** Caps each person's friends, which bounds how many copies of each update a sharer writes. */
export const MAX_FRIENDS = 100;

/** Friendship documents are keyed by both uids, lowest first (matches firestore.rules). */
export function friendshipId(a: string, b: string): string {
  return a < b ? `${a}_${b}` : `${b}_${a}`;
}

/**
 * Accepts the invite stored under `token` on behalf of `uid` and returns the inviter's uid.
 *
 * Failures the app maps to messages (WAYFirebase/FirebaseFriendsBackend.swift):
 * - not-found: no such invite (expired and removed by TTL, or already used)
 * - failed-precondition, details.reason "expired" | "own-invite"
 * - resource-exhausted: one side already has MAX_FRIENDS friends
 *
 * Accepting an invite from someone who's already a friend succeeds and just uses up the invite,
 * so retrying after a network error is safe.
 */
export async function acceptInviteFor(db: Firestore, uid: string, token: string): Promise<{ inviterUid: string }> {
  return db.runTransaction(async (transaction) => {
    const inviteRef = db.doc(`invites/${token}`);
    const invite = await transaction.get(inviteRef);
    if (!invite.exists) {
      throw new HttpsError("not-found", "This invite has expired or was already used.");
    }

    const inviterUid: unknown = invite.get("inviterUid");
    const expiresAt: unknown = invite.get("expiresAt");
    if (typeof inviterUid !== "string" || !(expiresAt instanceof Timestamp)) {
      throw new HttpsError("failed-precondition", "This invite is malformed.", { reason: "expired" });
    }
    if (expiresAt.toMillis() <= Date.now()) {
      throw new HttpsError("failed-precondition", "This invite has expired.", { reason: "expired" });
    }
    if (inviterUid === uid) {
      throw new HttpsError("failed-precondition", "You can't accept your own invite.", { reason: "own-invite" });
    }

    const friendshipRef = db.doc(`friendships/${friendshipId(uid, inviterUid)}`);
    const friendship = await transaction.get(friendshipRef);
    if (!friendship.exists) {
      for (const member of [uid, inviterUid]) {
        const count = await transaction.get(friendsOf(db, member).count());
        if (count.data().count >= MAX_FRIENDS) {
          throw new HttpsError("resource-exhausted", "One of you already has the maximum number of friends.");
        }
      }
      transaction.create(friendshipRef, {
        members: [uid, inviterUid].sort(),
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.delete(inviteRef);
    return { inviterUid };
  });
}

/**
 * Ends the friendship between `uid` and `friendUid`: deletes the friendship, what each shared
 * with the other, and the alerts each set on the other. Safe to repeat.
 */
export async function removeFriendship(db: Firestore, uid: string, friendUid: string): Promise<void> {
  for (const [owner, other] of [
    [uid, friendUid],
    [friendUid, uid],
  ]) {
    await db.doc(`inboxes/${owner}/shares/${other}`).delete();
    await deleteQuery(db.collection(`inboxes/${owner}/alertRequests`).where("requesterUid", "==", other));
  }
  // Last, so a failed attempt can still be found and retried.
  await db.doc(`friendships/${friendshipId(uid, friendUid)}`).delete();
}

export function friendsOf(db: Firestore, uid: string): Query {
  return db.collection("friendships").where("members", "array-contains", uid);
}

export async function deleteQuery(query: Query, batchSize = 300): Promise<void> {
  for (;;) {
    const snapshot = await query.limit(batchSize).get();
    if (snapshot.empty) {
      return;
    }
    const batch = query.firestore.batch();
    for (const doc of snapshot.docs) {
      batch.delete(doc.ref);
    }
    await batch.commit();
  }
}

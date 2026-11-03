import type { Firestore } from "firebase-admin/firestore";
import { deleteQuery, friendsOf, removeFriendship } from "./friendships";

/**
 * Removes everything stored for `uid`: what they shared with friends, alerts they set,
 * invites, queued notifications, and their own documents.
 *
 * Safe to run again after a partial failure. Each friendship is deleted last, so a retry can
 * still find whose inboxes need cleaning.
 */
export async function deleteUserData(db: Firestore, uid: string): Promise<void> {
  const friendships = await friendsOf(db, uid).get();
  for (const friendship of friendships.docs) {
    const members: unknown = friendship.get("members");
    const friendUids = Array.isArray(members)
      ? members.filter((member): member is string => typeof member === "string" && member !== uid)
      : [];
    for (const friendUid of friendUids) {
      await removeFriendship(db, uid, friendUid);
    }
    // Covers malformed friendships with no other member.
    await friendship.ref.delete();
  }

  await deleteQuery(db.collection("invites").where("inviterUid", "==", uid));
  await deleteQuery(db.collection("notificationEvents").where("fromUid", "==", uid));
  await deleteQuery(db.collection("notificationEvents").where("toUid", "==", uid));

  // Includes subcollections: anything else addressed to this user, devices, private profile
  // and prefs.
  await db.recursiveDelete(db.doc(`inboxes/${uid}`));
  await db.recursiveDelete(db.doc(`users/${uid}`));
}

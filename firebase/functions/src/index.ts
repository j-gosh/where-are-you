import { initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";
import { logger } from "firebase-functions/v2";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";
import { deleteUserData } from "./deleteUserData";
import { acceptInviteFor, removeFriendship } from "./friendships";

export { onAlertRequestCreated, onNotificationEvent } from "./notifications";

initializeApp();

// The emulators can't issue App Check tokens, so only enforce App Check in production.
const enforceAppCheck = process.env.FUNCTIONS_EMULATOR !== "true";

const base64url = /^[A-Za-z0-9_-]+$/;
// Firebase Auth uids are at most 128 characters and never contain "/".
const uidPattern = /^[^/]{1,128}$/;

function requireUid(request: CallableRequest): string {
  const uid = request.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  return uid;
}

/** Accepts an invite: `{ token }` → `{ inviterUid }`. See acceptInviteFor for failures. */
export const acceptInvite = onCall({ enforceAppCheck }, async (request) => {
  const uid = requireUid(request);
  const token: unknown = request.data?.token;
  if (typeof token !== "string" || token.length !== 43 || !base64url.test(token)) {
    throw new HttpsError("invalid-argument", "Invalid invite.");
  }
  return acceptInviteFor(getFirestore(), uid, token);
});

/** Ends a friendship: `{ friendUid }`. Removing someone who isn't a friend succeeds. */
export const removeFriend = onCall({ enforceAppCheck }, async (request) => {
  const uid = requireUid(request);
  const friendUid: unknown = request.data?.friendUid;
  if (typeof friendUid !== "string" || !uidPattern.test(friendUid) || friendUid === uid) {
    throw new HttpsError("invalid-argument", "Invalid friend.");
  }
  await removeFriendship(getFirestore(), uid, friendUid);
  return { removed: true };
});

/**
 * Deletes the caller's data and then their account. The app first revokes the user's
 * Sign in with Apple token, as App Store guidelines require.
 */
export const deleteAccount = onCall({ enforceAppCheck }, async (request) => {
  const uid = requireUid(request);
  try {
    await deleteUserData(getFirestore(), uid);
    await getAuth().deleteUser(uid);
  } catch (error) {
    if (isUserNotFound(error)) {
      // A previous attempt already deleted the account.
      return { deleted: true };
    }
    logger.error("deleteAccount failed", { uid, error });
    throw new HttpsError("internal", "Couldn't delete the account. Please try again.");
  }
  return { deleted: true };
});

function isUserNotFound(error: unknown): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === "auth/user-not-found";
}

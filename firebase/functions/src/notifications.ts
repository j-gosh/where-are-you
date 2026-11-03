import { getFirestore, type Firestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { logger } from "firebase-functions/v2";
import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { friendshipId } from "./friendships";
import { buildMessage, invalidTokens, sealedBoxJSON, shouldDeliver, type PushKind } from "./pushMessages";

/**
 * Relays an alert event (sealed by the watched friend's device) to the requester's devices,
 * if they're still friends and the requester's preferences allow it. Events are deleted once
 * handled; a TTL policy on expiresAt cleans up any that aren't.
 */
export const onNotificationEvent = onDocumentCreated("notificationEvents/{eventId}", async (event) => {
  const snapshot = event.data;
  if (!snapshot) {
    return;
  }
  const db = getFirestore();
  try {
    const fromUid: unknown = snapshot.get("fromUid");
    const toUid: unknown = snapshot.get("toUid");
    const box = sealedBoxJSON(snapshot.get("payload"));
    if (typeof fromUid !== "string" || typeof toUid !== "string" || !box) {
      logger.warn("Skipping a malformed notification event", { eventId: event.params.eventId });
      return;
    }
    if (!(await db.doc(`friendships/${friendshipId(fromUid, toUid)}`).get()).exists) {
      return;
    }
    const prefs = (await db.doc(`users/${toUid}/private/prefs`).get()).data();
    if (!shouldDeliver(prefs, fromUid)) {
      return;
    }
    await sendToDevices(db, toUid, "alertEvent", fromUid, box);
  } finally {
    await snapshot.ref.delete();
  }
});

/**
 * Tells the watched person that a friend set an alert on them. Sent regardless of preferences:
 * people should always know who is watching for them.
 */
export const onAlertRequestCreated = onDocumentCreated("inboxes/{targetUid}/alertRequests/{alertId}", async (event) => {
  const snapshot = event.data;
  if (!snapshot) {
    return;
  }
  const requesterUid: unknown = snapshot.get("requesterUid");
  const box = sealedBoxJSON(snapshot.get("payload"));
  if (typeof requesterUid !== "string" || !box) {
    logger.warn("Skipping a malformed alert request", { alertId: event.params.alertId });
    return;
  }
  await sendToDevices(getFirestore(), event.params.targetUid, "alertRequest", requesterUid, box);
});

async function sendToDevices(db: Firestore, toUid: string, kind: PushKind, fromUid: string, box: string): Promise<void> {
  const devices = await db.collection(`users/${toUid}/devices`).get();
  const entries = devices.docs.flatMap((device) => {
    const token: unknown = device.get("fcmToken");
    return typeof token === "string" ? [{ ref: device.ref, token }] : [];
  });
  if (entries.length === 0) {
    return;
  }
  const tokens = entries.map((entry) => entry.token);
  const response = await getMessaging().sendEachForMulticast(buildMessage(tokens, kind, fromUid, toUid, box));
  const invalid = new Set(invalidTokens(tokens, response));
  await Promise.all(entries.filter((entry) => invalid.has(entry.token)).map((entry) => entry.ref.delete()));
  if (response.failureCount > invalid.size) {
    logger.warn("Some pushes failed", { toUid, failures: response.failureCount - invalid.size });
  }
}

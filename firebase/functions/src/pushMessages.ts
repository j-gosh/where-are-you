import type { DocumentData } from "firebase-admin/firestore";
import type { BatchResponse, MulticastMessage } from "firebase-admin/messaging";

/** What a push is about. Matches PushContent.Kind in WAYCore. */
export type PushKind = "alertEvent" | "alertRequest";

/**
 * Shown when the notification extension can't decrypt the push (or isn't running), so it must
 * never say anything private.
 */
export const fallbackText: Record<PushKind, { title: string; body: string }> = {
  alertEvent: { title: "Location Alert", body: "A friend arrived at or left a place." },
  alertRequest: { title: "New Location Alert", body: "A friend set a location alert on you. Open Where Are You to see it." },
};

/** Whether the recipient's alert preferences let `fromUid`'s alerts through. No prefs means yes. */
export function shouldDeliver(prefs: DocumentData | undefined, fromUid: string): boolean {
  if (!prefs) {
    return true;
  }
  if (prefs.receiveAlerts === false) {
    return false;
  }
  const muted: unknown = prefs.mutedAlertSenders;
  return !(Array.isArray(muted) && muted.includes(fromUid));
}

/**
 * A stored SealedBox map as the JSON the app's JSONDecoder expects (binary fields base64), or
 * null if it isn't a well-formed version 1 box.
 */
export function sealedBoxJSON(payload: unknown): string | null {
  if (typeof payload !== "object" || payload === null) {
    return null;
  }
  const box = payload as Record<string, unknown>;
  const encapsulatedKey = asBytes(box.encapsulatedKey);
  const ciphertext = asBytes(box.ciphertext);
  if (box.version !== 1 || typeof box.senderKeyId !== "string" || typeof box.recipientKeyId !== "string" || !encapsulatedKey || !ciphertext) {
    return null;
  }
  return JSON.stringify({
    version: 1,
    senderKeyId: box.senderKeyId,
    recipientKeyId: box.recipientKeyId,
    encapsulatedKey: encapsulatedKey.toString("base64"),
    ciphertext: ciphertext.toString("base64"),
  });
}

function asBytes(value: unknown): Buffer | null {
  return value instanceof Uint8Array ? Buffer.from(value) : null;
}

/**
 * One push to each of the recipient's devices. The ciphertext rides in `data`; `mutable-content`
 * wakes the notification extension, which swaps in the decrypted text.
 */
export function buildMessage(tokens: string[], kind: PushKind, fromUid: string, toUid: string, box: string): MulticastMessage {
  return {
    tokens,
    notification: fallbackText[kind],
    data: { kind, fromUid, toUid, box },
    apns: { payload: { aps: { "mutable-content": 1, sound: "default" } } },
  };
}

const invalidTokenCodes = new Set(["messaging/registration-token-not-registered", "messaging/invalid-registration-token"]);

/** Tokens FCM says no longer work, so their device documents can be deleted. */
export function invalidTokens(tokens: string[], response: BatchResponse): string[] {
  return response.responses.flatMap((result, index) =>
    !result.success && invalidTokenCodes.has(result.error?.code ?? "") ? [tokens[index]] : [],
  );
}

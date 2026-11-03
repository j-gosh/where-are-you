// Pure helpers; runs without the emulators (`npm run test:unit`).
import type { BatchResponse } from "firebase-admin/messaging";
import { describe, expect, it } from "vitest";
import { buildMessage, fallbackText, invalidTokens, sealedBoxJSON, shouldDeliver } from "../src/pushMessages";

const box = {
  version: 1,
  senderKeyId: "A".repeat(22),
  recipientKeyId: "B".repeat(22),
  encapsulatedKey: Buffer.from([1, 2, 3]),
  ciphertext: Buffer.from([4, 5, 6, 7]),
};

describe("shouldDeliver", () => {
  it("delivers when there are no preferences", () => {
    expect(shouldDeliver(undefined, "alice")).toBe(true);
  });

  it("respects the receive switch and per-friend mutes", () => {
    expect(shouldDeliver({ receiveAlerts: false, mutedAlertSenders: [] }, "alice")).toBe(false);
    expect(shouldDeliver({ receiveAlerts: true, mutedAlertSenders: ["alice"] }, "alice")).toBe(false);
    expect(shouldDeliver({ receiveAlerts: true, mutedAlertSenders: ["bob"] }, "alice")).toBe(true);
  });
});

describe("sealedBoxJSON", () => {
  it("base64-encodes the binary fields for the app's decoder", () => {
    expect(JSON.parse(sealedBoxJSON(box) ?? "null")).toEqual({
      version: 1,
      senderKeyId: box.senderKeyId,
      recipientKeyId: box.recipientKeyId,
      encapsulatedKey: "AQID",
      ciphertext: "BAUGBw==",
    });
  });

  it("rejects anything else", () => {
    expect(sealedBoxJSON(null)).toBeNull();
    expect(sealedBoxJSON("box")).toBeNull();
    expect(sealedBoxJSON({ ...box, version: 2 })).toBeNull();
    expect(sealedBoxJSON({ ...box, ciphertext: "not bytes" })).toBeNull();
  });
});

describe("buildMessage", () => {
  it("carries ciphertext in data, generic text in the notification, and wakes the extension", () => {
    const message = buildMessage(["t1", "t2"], "alertEvent", "alice", "bob", "{}");

    expect(message.tokens).toEqual(["t1", "t2"]);
    expect(message.notification).toEqual(fallbackText.alertEvent);
    expect(message.data).toEqual({ kind: "alertEvent", fromUid: "alice", toUid: "bob", box: "{}" });
    expect(message.apns?.payload?.aps?.["mutable-content"]).toBe(1);
  });

  it("never puts private details in the fallback text", () => {
    for (const text of Object.values(fallbackText)) {
      expect(text.body).not.toMatch(/alice|bob|home/i);
    }
  });
});

describe("invalidTokens", () => {
  it("finds tokens FCM no longer accepts", () => {
    const response = {
      successCount: 1,
      failureCount: 2,
      responses: [
        { success: true },
        { success: false, error: { code: "messaging/registration-token-not-registered" } },
        { success: false, error: { code: "messaging/internal-error" } },
      ],
    } as unknown as BatchResponse;

    expect(invalidTokens(["ok", "gone", "flaky"], response)).toEqual(["gone"]);
  });
});

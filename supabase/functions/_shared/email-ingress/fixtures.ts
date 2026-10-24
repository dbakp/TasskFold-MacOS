// Synthetic-only signing helpers, never imported by production preparation.
import type { EmailIngressConfig } from "./mod.ts";
export const fixtureNow = Date.parse("2026-10-24T12:00:00.000Z");
export const fixtureConfig: EmailIngressConfig = {
  enabled: true,
  provider: "synthetic-adapter",
  audience: "taskfold-synthetic-email-intake",
  inboundDomain: "mail.example.invalid",
  keys: { current: "01".repeat(32), previous: "02".repeat(32) },
};
export function fixtureEnvelope(now = fixtureNow) {
  return {
    version: 1,
    deliveryID: "original-receipt-1",
    receivedAt: new Date(now).toISOString(),
    sender: "intake-a@example.invalid",
    recipient: "a".repeat(64) + "@mail.example.invalid",
    senderVerified: true,
    raw: btoa(
      "From: attacker@other.invalid\r\nTo: not-the-envelope@other.invalid\r\nDate: Mon, 01 Jan 2001 00:00:00 +0000\r\nMessage-ID: <not-a-receipt@other.invalid>\r\nAuthentication-Results: forged\r\nSubject: Review the launch\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nKeep the original words.\r\n",
    ),
  };
}
export async function signedFixture(
  envelope: unknown = fixtureEnvelope(),
  now = fixtureNow,
  id = "current",
  config = fixtureConfig,
  bodyText = JSON.stringify(envelope),
) {
  const body = new TextEncoder().encode(bodyText),
    stamp = String(Math.floor(now / 1000));
  const prefix = new TextEncoder().encode(
    "taskfold-email-ingress.v1\n" + config.audience + "\n" + config.provider +
      "\n" + id + "\n" + stamp + "\n",
  );
  const data = new Uint8Array(prefix.length + body.length);
  data.set(prefix);
  data.set(body, prefix.length);
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(config.keys[id].match(/../g)!, (s) => parseInt(s, 16)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
  const headers = new Headers({
    "Content-Type": "application/json",
    "X-Taskfold-Mail-Key": id,
    "X-Taskfold-Mail-Time": stamp,
    "X-Taskfold-Mail-Signature": Array.from(
      signature,
      (b) => b.toString(16).padStart(2, "0"),
    ).join(""),
  });
  return { body, headers };
}

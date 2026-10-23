// Webhook signing differs from API-key authentication: the dispatcher must
// recover the receiver secret. Store only this authenticated encrypted envelope;
// its separate versioned master key belongs in server configuration, never SQL
// or a native app. Losing a master key requires receiver-secret rotation.
const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type WebhookSecretEnvelope = {
  version: 1;
  keyVersion: string;
  nonce: string;
  ciphertext: string;
};
function associated(owner: string, subscription: string, keyVersion: string) {
  if (
    !uuid.test(owner) || !uuid.test(subscription) ||
    typeof keyVersion !== "string" ||
    !/^[a-z0-9-]{1,32}$/.test(keyVersion)
  ) {
    throw new Error("Invalid webhook secret binding");
  }
  return encoder.encode(
    `taskfold-webhook-secret:v1:${owner}:${subscription}:${keyVersion}`,
  );
}
function encode(bytes: Uint8Array) {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replace(/=+$/, "");
}
function decode(text: string, length: number) {
  if (
    typeof text !== "string" || text.length !== Math.ceil(length * 4 / 3) ||
    !/^[A-Za-z0-9_-]+$/.test(text)
  ) {
    throw new Error("Invalid webhook secret envelope");
  }
  const bytes = Uint8Array.from(
    atob(
      text.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - text.length % 4) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
  if (bytes.length !== length || encode(bytes) !== text) {
    throw new Error("Invalid webhook secret envelope");
  }
  return bytes;
}
async function master(bytes: Uint8Array, operation: "encrypt" | "decrypt") {
  if (bytes.length !== 32) throw new Error("Invalid webhook master key");
  return await crypto.subtle.importKey(
    "raw",
    bytes as BufferSource,
    "AES-GCM",
    false,
    [operation],
  );
}
export async function sealWebhookSecret(
  secret: Uint8Array,
  masterKey: Uint8Array,
  owner: string,
  subscription: string,
  keyVersion: string,
): Promise<WebhookSecretEnvelope> {
  if (secret.length !== 32) throw new Error("Invalid webhook receiver secret");
  const additionalData = associated(owner, subscription, keyVersion);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv, additionalData, tagLength: 128 },
      await master(masterKey, "encrypt"),
      secret as BufferSource,
    ),
  );
  return {
    version: 1,
    keyVersion,
    nonce: encode(iv),
    ciphertext: encode(ciphertext),
  };
}
export async function openWebhookSecret(
  envelope: WebhookSecretEnvelope,
  masterKey: Uint8Array,
  owner: string,
  subscription: string,
): Promise<Uint8Array> {
  if (envelope?.version !== 1) {
    throw new Error("Unsupported webhook secret envelope");
  }
  const additionalData = associated(owner, subscription, envelope.keyVersion);
  const iv = decode(envelope.nonce, 12),
    ciphertext = decode(envelope.ciphertext, 48);
  return new Uint8Array(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv, additionalData, tagLength: 128 },
      await master(masterKey, "decrypt"),
      ciphertext,
    ),
  );
}

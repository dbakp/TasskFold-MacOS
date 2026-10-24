// Internal adapter handoff, NOT an HTTP deployment or native-app credential.
// A future provider verifier must attest original envelope/sender/receipt facts.
import { emailAliasDomain, emailAliasHash } from "../email-alias.ts";
import { normalizeEmailContent } from "../email-content.ts";
import { decodeEmailMessage, emailMimeLimits } from "../email-mime/mod.ts";

export const emailIngressLimits = Object.freeze({
  bodyBytes: 4 * Math.ceil(emailMimeLimits.rawBytes / 3) + 4096,
  streamChunks: 4096,
  headerBytes: 16384,
  headerCount: 64,
  signatureAgeSeconds: 300,
  messageAgeMilliseconds: 7 * 86400000,
});
export type EmailIngressConfig = {
  enabled: boolean;
  provider: string;
  audience: string;
  inboundDomain: string;
  keys: Readonly<Record<string, string>>; // 32 random bytes as lowercase hex.
};
export class EmailIngressError extends Error {
  constructor(readonly reason: string, readonly status = 400) {
    super("Email intake refused: " + reason);
  }
}
export type VerifiedEmailEnvelope = Readonly<{
  provider: string;
  deliveryID: string;
}>;
type PrivateEnvelope = {
  sender: string;
  recipient: string;
  receivedAt: string;
  raw: Uint8Array;
};
// An object copied/cast by a caller cannot masquerade as a verified envelope.
// Message bytes and private routing facts do not leave this module until the
// deliberate journal preparation step, after authenticated admission.
const verified = new WeakMap<VerifiedEmailEnvelope, PrivateEnvelope>();
const bytes = (text: string) => new TextEncoder().encode(text);
const hex = (text: string) =>
  Uint8Array.from(text.match(/../g) ?? [], (part) => parseInt(part, 16));
export function validateEmailIngressConfig(
  config: EmailIngressConfig,
): EmailIngressConfig {
  if (
    !config || config.enabled !== true || typeof config.provider !== "string" ||
    !/^[a-z0-9][a-z0-9_-]{0,47}$/.test(config.provider) ||
    typeof config.audience !== "string" ||
    !/^[a-z0-9][a-z0-9_-]{0,95}$/.test(config.audience) ||
    emailAliasDomain(config.inboundDomain) !== config.inboundDomain ||
    !config.keys || Object.keys(config.keys).length < 1 ||
    Object.keys(config.keys).length > 4 ||
    Object.entries(config.keys).some(([id, secret]) =>
      !/^[a-z0-9_-]{1,48}$/.test(id) || typeof secret !== "string" ||
      !/^[a-f0-9]{64}$/.test(secret)
    )
  ) throw new EmailIngressError("not_configured", 503);
  return Object.freeze({
    enabled: true,
    provider: config.provider,
    audience: config.audience,
    inboundDomain: config.inboundDomain,
    keys: Object.freeze({ ...config.keys }),
  });
}
function mailbox(value: unknown): value is string {
  if (typeof value !== "string" || value.length > 254) return false;
  const parts = value.split("@");
  return parts.length === 2 && parts[0].length <= 64 &&
    /^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(parts[0]) &&
    emailAliasDomain(parts[1]) === parts[1];
}
export async function verifyEmailEnvelope(
  rawBody: Uint8Array,
  headers: Headers,
  config: EmailIngressConfig,
  now = Date.now(),
): Promise<VerifiedEmailEnvelope> {
  config = validateEmailIngressConfig(config);
  if (
    !(rawBody instanceof Uint8Array) || rawBody.byteLength === 0 ||
    rawBody.byteLength > emailIngressLimits.bodyBytes
  ) throw new EmailIngressError("body_size", 413);
  const id = headers.get("X-Taskfold-Mail-Key") ?? "";
  const stamp = headers.get("X-Taskfold-Mail-Time") ?? "";
  const signature = headers.get("X-Taskfold-Mail-Signature") ?? "";
  if (
    !/^[a-z0-9_-]{1,48}$/.test(id) || !Object.hasOwn(config.keys, id) ||
    !/^[0-9]{1,12}$/.test(stamp) || String(Number(stamp)) !== stamp ||
    !Number.isFinite(now) ||
    Math.abs(now / 1000 - Number(stamp)) >
      emailIngressLimits.signatureAgeSeconds ||
    !/^[a-f0-9]{64}$/.test(signature)
  ) throw new EmailIngressError("signature", 401);
  const key = await crypto.subtle.importKey(
    "raw",
    hex(config.keys[id]),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const prefix = bytes(
    "taskfold-email-ingress.v1\n" + config.audience + "\n" + config.provider +
      "\n" + id + "\n" + stamp + "\n",
  );
  // Snapshot before awaiting crypto: a caller cannot mutate the verified bytes
  // between signature verification and JSON/MIME interpretation.
  const message = new Uint8Array(prefix.length + rawBody.length);
  message.set(prefix);
  message.set(rawBody, prefix.length);
  if (!await crypto.subtle.verify("HMAC", key, hex(signature), message)) {
    throw new EmailIngressError("signature", 401);
  }
  let row: Record<string, unknown>;
  try {
    const signedBody = message.subarray(prefix.length);
    row = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(signedBody),
    );
    if (!row || typeof row !== "object" || Array.isArray(row)) throw Error();
    // Compact JSON from the Taskfold adapter is the handoff format. Reject
    // duplicate keys, alternate escape spellings, BOMs and ambiguous encodings.
    const canonical = bytes(JSON.stringify(row));
    if (
      canonical.length !== signedBody.length ||
      canonical.some((value, index) => value !== signedBody[index]) ||
      Object.keys(row).sort().join(",") !==
        "deliveryID,raw,receivedAt,recipient,sender,senderVerified,version" ||
      row.version !== 1 || row.senderVerified !== true ||
      typeof row.deliveryID !== "string" ||
      !/^[!-~]{1,256}$/.test(row.deliveryID) ||
      !mailbox(row.sender) || typeof row.recipient !== "string" ||
      row.recipient !== row.recipient.toLowerCase() ||
      row.recipient.split("@")[1] !== config.inboundDomain ||
      !/^[a-f0-9]{64}@/.test(row.recipient) ||
      typeof row.receivedAt !== "string" ||
      !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{3})?Z$/.test(
        row.receivedAt,
      ) ||
      !Number.isFinite(Date.parse(row.receivedAt)) ||
      ![
        new Date(row.receivedAt).toISOString(),
        new Date(row.receivedAt).toISOString().replace(".000Z", "Z"),
      ].includes(row.receivedAt) ||
      Date.parse(row.receivedAt) <
        now - emailIngressLimits.messageAgeMilliseconds ||
      Date.parse(row.receivedAt) > now + 300000 ||
      typeof row.raw !== "string" ||
      row.raw.length > 4 * Math.ceil(emailMimeLimits.rawBytes / 3) ||
      row.raw.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(row.raw)
    ) throw Error();
    await emailAliasHash(row.recipient);
    const decoded = atob(row.raw);
    if (
      !decoded.length || decoded.length > emailMimeLimits.rawBytes ||
      btoa(decoded) !== row.raw
    ) throw Error();
    const envelope = Object.freeze({
      provider: config.provider,
      deliveryID: row.deliveryID,
    });
    verified.set(envelope, {
      sender: row.sender,
      recipient: row.recipient,
      receivedAt: row.receivedAt,
      raw: Uint8Array.from(decoded, (char) => char.charCodeAt(0)),
    });
    return envelope;
  } catch {
    throw new EmailIngressError("envelope", 422);
  }
}
export async function prepareVerifiedEmailDelivery(
  envelope: VerifiedEmailEnvelope,
) {
  const data = verified.get(envelope);
  if (!data) throw new EmailIngressError("unverified_envelope", 401);
  let content;
  try {
    content = normalizeEmailContent(await decodeEmailMessage(data.raw));
  } catch {
    throw new EmailIngressError("unsupported_content", 422);
  }
  return Object.freeze({
    _alias_hash: await emailAliasHash(data.recipient),
    _recipient_domain: data.recipient.split("@")[1],
    _provider: envelope.provider,
    _delivery_id: envelope.deliveryID,
    _received_at: data.receivedAt,
    _verified_sender: data.sender,
    _content: content,
  });
}
export type EmailJournalArguments = Awaited<
  ReturnType<typeof prepareVerifiedEmailDelivery>
>;

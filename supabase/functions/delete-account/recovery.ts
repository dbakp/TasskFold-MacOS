// Operator-issued absence-only recovery, bound to one pending private command.
import type { ProofKey } from "./proof.ts";
export type RecoveryRequest = {
  format: "taskfold-account-removal-recovery-request";
  version: 1;
  origin: string;
  account: string;
  command: string;
  authorization_hash: string;
};
export type RecoveryBinding = Pick<
  RecoveryRequest,
  "account" | "command" | "authorization_hash"
>;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const hash = /^[0-9a-f]{64}$/;
const encode = (v: Uint8Array) =>
  btoa(String.fromCharCode(...v)).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/, "");
function decode(v: string): Uint8Array<ArrayBuffer> {
  const bytes = Uint8Array.from(
    atob(
      v.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - v.length % 4) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
  if (encode(bytes) !== v) throw Error("noncanonical");
  return bytes;
}
export function recoveryRequest(
  value: unknown,
  origin: string,
  account: string,
): RecoveryRequest {
  const r = value as RecoveryRequest;
  if (
    !r || typeof r !== "object" || Array.isArray(r) ||
    Object.keys(r).sort().join(",") !==
      "account,authorization_hash,command,format,origin,version" ||
    r.format !== "taskfold-account-removal-recovery-request" ||
    r.version !== 1 || r.origin !== origin || r.account !== account ||
    !uuid.test(r.account) || !uuid.test(r.command) ||
    !hash.test(r.authorization_hash)
  ) throw Error("invalid recovery request");
  return {
    format: r.format,
    version: 1,
    origin: r.origin,
    account: r.account,
    command: r.command,
    authorization_hash: r.authorization_hash,
  };
}
type Reader = (id: string | null) => Promise<unknown>;
async function key(read: Reader, id: string | null) {
  const r = await read(id) as ProofKey;
  if (
    !r || !uuid.test(r.id) || typeof r.key !== "string" || r.key.length > 128
  ) throw Error("key unavailable");
  const bytes = Uint8Array.from(atob(r.key), (c) => c.charCodeAt(0));
  if (bytes.length !== 32) throw Error("key unavailable");
  return {
    id: r.id,
    key: await crypto.subtle.importKey(
      "raw",
      bytes,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    ),
  };
}
export async function issueRecoveryProof(
  request: RecoveryRequest,
  now: number,
  read: Reader,
) {
  const r = recoveryRequest(request, request.origin, request.account),
    k = await key(read, null);
  const claims = {
    v: 1,
    scope: "account-removal-recovery",
    origin: r.origin,
    account: r.account,
    command: r.command,
    authorization_hash: r.authorization_hash,
    kid: k.id,
    issued: Math.floor(now / 1000),
  };
  const payload = encode(new TextEncoder().encode(JSON.stringify(claims)));
  return payload + "." +
    encode(
      new Uint8Array(
        await crypto.subtle.sign(
          "HMAC",
          k.key,
          new TextEncoder().encode(payload),
        ),
      ),
    );
}
export async function verifyRecoveryProof(
  value: string,
  origin: string,
  now: number,
  read: Reader,
): Promise<RecoveryBinding | null> {
  let claims: Record<string, unknown>,
    payload: string,
    signature: Uint8Array<ArrayBuffer>;
  try {
    if (
      value.length > 2048 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(value)
    ) return null;
    [payload] = value.split(".");
    signature = decode(value.split(".")[1]);
    claims = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(decode(payload)),
    );
    if (
      !claims || typeof claims !== "object" || Array.isArray(claims) ||
      Object.keys(claims).sort().join(",") !==
        "account,authorization_hash,command,issued,kid,origin,scope,v" ||
      claims.v !== 1 || claims.scope !== "account-removal-recovery" ||
      claims.origin !== origin || typeof claims.account !== "string" ||
      !uuid.test(claims.account) || typeof claims.command !== "string" ||
      !uuid.test(claims.command) ||
      typeof claims.authorization_hash !== "string" ||
      !hash.test(claims.authorization_hash) || typeof claims.kid !== "string" ||
      !uuid.test(claims.kid) || typeof claims.issued !== "number" ||
      !Number.isSafeInteger(claims.issued) || claims.issued <= 0 ||
      claims.issued > now / 1000 + 300
    ) return null;
  } catch {
    return null;
  }
  const raw = await read(claims.kid as string);
  if (raw === null) return null;
  const material = await key(() => Promise.resolve(raw), claims.kid as string);
  if (
    material.id !== claims.kid ||
    !await crypto.subtle.verify(
      "HMAC",
      material.key,
      signature,
      new TextEncoder().encode(payload),
    )
  ) return null;
  return {
    account: claims.account as string,
    command: claims.command as string,
    authorization_hash: claims.authorization_hash as string,
  };
}

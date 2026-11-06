/** Non-expiring *status-only* proof. This never authorizes a new deletion. */
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export type ProofKey = { id: string; key: string };
type Claims = {
  v: 1;
  scope: "account-removal-status";
  origin: string;
  account: string;
  kid: string;
  issued: number;
};
type KeyReader = (id: string | null) => Promise<unknown>;
const encode = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/, "");
function decode(value: string): Uint8Array<ArrayBuffer> {
  const bytes = Uint8Array.from(
    atob(
      value.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - value.length % 4) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
  if (encode(bytes) !== value) throw new Error("Noncanonical proof");
  return bytes;
}
async function key(value: unknown) {
  const row = value as ProofKey;
  if (
    !row || !uuid.test(row.id) || typeof row.key !== "string" ||
    row.key.length > 128
  ) throw new Error("Signing key unavailable");
  const bytes = Uint8Array.from(atob(row.key), (c) => c.charCodeAt(0));
  if (bytes.length !== 32) throw new Error("Signing key invalid");
  return {
    id: row.id,
    crypto: await crypto.subtle.importKey(
      "raw",
      bytes,
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    ),
  };
}
export async function issueProof(
  account: string,
  origin: string,
  now: number,
  read: KeyReader,
): Promise<string> {
  if (!uuid.test(account)) throw new Error("Invalid proof account");
  const signing = await key(await read(null));
  const claims: Claims = {
    v: 1,
    scope: "account-removal-status",
    origin,
    account,
    kid: signing.id,
    issued: Math.floor(now / 1000),
  };
  const payload = encode(new TextEncoder().encode(JSON.stringify(claims)));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      signing.crypto,
      new TextEncoder().encode(payload),
    ),
  );
  return payload + "." + encode(signature);
}
export async function verifyProof(
  value: string,
  origin: string,
  now: number,
  read: KeyReader,
): Promise<string | null> {
  let claims: Claims, payload: string, signature: Uint8Array<ArrayBuffer>;
  try {
    if (
      value.length > 2048 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(value)
    ) return null;
    const parts = value.split(".");
    payload = parts[0];
    signature = decode(parts[1]);
    claims = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(decode(payload)),
    ) as Claims;
    if (
      !claims ||
      Object.keys(claims).sort().join(",") !==
        "account,issued,kid,origin,scope,v" ||
      claims.v !== 1 || claims.scope !== "account-removal-status" ||
      claims.origin !== origin || !uuid.test(claims.account) ||
      !uuid.test(claims.kid) || !Number.isSafeInteger(claims.issued) ||
      claims.issued <= 0 || claims.issued > now / 1000 + 300
    ) return null;
  } catch {
    return null;
  }
  const material = await read(claims.kid);
  if (material === null) return null; // Revoked/unknown keys cannot confirm anything.
  const signing = await key(material);
  if (signing.id !== claims.kid) return null;
  if (
    !await crypto.subtle.verify(
      "HMAC",
      signing.crypto,
      signature,
      new TextEncoder().encode(payload),
    )
  ) return null;
  return claims.account;
}

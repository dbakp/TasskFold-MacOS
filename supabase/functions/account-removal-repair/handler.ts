/** Disabled-by-default operator repair. A client status proof is never authority here. */
type Config = {
  url: string;
  serviceKey: string;
  maintenanceKey: string;
  enabled?: boolean;
  timeoutMilliseconds?: number;
};
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  now?: () => number;
};
type File = { id: string; bucket: string; name: string; stamp: string };
type Manifest = { account: string; files: File[]; more: boolean };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const sha = /^[0-9a-f]{64}$/;
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
class Refusal extends Error {
  constructor(public code: string, public status: number) {
    super(code);
  }
}
const encoder = new TextEncoder();
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Refusal("invalid", 400);
  }
  return value as Record<string, unknown>;
}
function exact(value: Record<string, unknown>, keys: string[]) {
  if (Object.keys(value).sort().join(",") !== [...keys].sort().join(",")) {
    throw new Refusal("invalid", 400);
  }
}
async function read(
  stream: ReadableStream<Uint8Array> | null,
  limit: number,
  signal: AbortSignal,
) {
  const reader = stream?.getReader();
  if (!reader) return null;
  const parts: Uint8Array[] = [];
  let size = 0;
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw Error("timeout");
    while (true) {
      const item = await reader.read();
      if (signal.aborted) throw Error("timeout");
      if (item.done) break;
      if ((size += item.value.length) > limit) {
        throw new Refusal("too_large", 413);
      }
      parts.push(item.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } finally {
    signal.removeEventListener("abort", abort);
    await reader.cancel().catch(() => {});
  }
}
async function hash(value: string) {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", encoder.encode(value)),
    ),
  ].map((x) => x.toString(16).padStart(2, "0")).join("");
}
function same(a: string, b: string) {
  let difference = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    difference |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }
  return difference === 0;
}
const encode = (data: Uint8Array) =>
  btoa(String.fromCharCode(...data)).replaceAll("+", "-").replaceAll("/", "_")
    .replace(/=+$/, "");
function decode(value: string) {
  const data = Uint8Array.from(
    atob(
      value.replaceAll("-", "+").replaceAll("_", "/") +
        "=".repeat((4 - value.length % 4) % 4),
    ),
    (c) => c.charCodeAt(0),
  );
  if (encode(data) !== value) throw Error("noncanonical");
  return data;
}
function manifest(value: unknown, account: string): Manifest {
  const row = object(value);
  exact(row, ["account", "files", "more"]);
  if (
    row.account !== account || typeof row.more !== "boolean" ||
    !Array.isArray(row.files) || row.files.length > 100 ||
    row.more && row.files.length !== 100
  ) throw Error("manifest");
  const ids = new Set<string>(), paths = new Set<string>();
  const files = row.files.map((value): File => {
    const f = object(value);
    exact(f, ["id", "bucket", "name", "stamp"]);
    if (
      typeof f.id !== "string" || !uuid.test(f.id) ||
      typeof f.stamp !== "string" || !sha.test(f.stamp) ||
      typeof f.bucket !== "string" ||
      !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/.test(f.bucket) ||
      typeof f.name !== "string" || !f.name || f.name.length > 2048 ||
      [...f.name].some((c) =>
        c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127
      ) ||
      f.name.split("/").some((p) => p === "." || p === "..") || ids.has(f.id) ||
      paths.has(f.bucket + "\0" + f.name)
    ) throw Error("manifest");
    ids.add(f.id);
    paths.add(f.bucket + "\0" + f.name);
    return { id: f.id, bucket: f.bucket, name: f.name, stamp: f.stamp };
  });
  return { account, files, more: row.more };
}
export function createRemovalRepairHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch, now = dependencies.now ?? Date.now;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST" || new URL(request.url).search) {
      return json({ code: "invalid" }, 400);
    }
    if (
      config.enabled !== true || !config.serviceKey ||
      config.maintenanceKey.length < 32 || config.maintenanceKey.length > 256
    ) return json({ code: "disabled" }, 503);
    const presented = request.headers.get("X-Taskfold-Removal-Repair") ?? "";
    if (
      presented.length > 256 ||
      !same(await hash(presented), await hash(config.maintenanceKey))
    ) return json({ code: "unauthorized" }, 401);
    const abort = new AbortController(),
      timer = setTimeout(
        () => abort.abort(),
        Math.min(20000, Math.max(10, config.timeoutMilliseconds ?? 20000)),
      );
    try {
      const url = new URL(config.url);
      if (
        url.protocol !== "https:" || url.pathname !== "/" || url.username ||
        url.password || url.search || url.hash
      ) throw Error("configuration");
      const origin = url.origin;
      const input = object(await read(request.body, 4096, abort.signal));
      const applying = input.action === "repair";
      exact(
        input,
        applying
          ? ["action", "account", "review", "confirmation"]
          : ["action", "account"],
      );
      if (
        !applying && input.action !== "preview" ||
        typeof input.account !== "string" || !uuid.test(input.account)
      ) throw new Refusal("invalid", 400);
      const account = input.account;
      const key = await crypto.subtle.importKey(
        "raw",
        encoder.encode(config.maintenanceKey),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign", "verify"],
      );
      const sign = async (payload: string) =>
        encode(
          new Uint8Array(
            await crypto.subtle.sign("HMAC", key, encoder.encode(payload)),
          ),
        );
      const api = async (path: string, body: unknown, method = "POST") => {
        if (abort.signal.aborted) throw Error("timeout");
        const outgoing = new Request(origin + path, {
          method,
          body: JSON.stringify(body),
          redirect: "error",
          signal: abort.signal,
          headers: {
            apikey: config.serviceKey,
            Authorization: "Bearer " + config.serviceKey,
            "Content-Type": "application/json",
          },
        });
        let remove: () => void = () => {};
        const timeout = new Promise<never>((_, reject) => {
          const handler = () => reject(Error("timeout"));
          abort.signal.addEventListener("abort", handler, { once: true });
          remove = () => abort.signal.removeEventListener("abort", handler);
        });
        try {
          const response = await Promise.race([send(outgoing), timeout]);
          const value = await read(response.body, 1000000, abort.signal);
          if (!response.ok) {
            if ((value as { code?: string })?.code === "28000") {
              throw new Refusal("account_present", 409);
            }
            throw Error("upstream");
          }
          return value;
        } finally {
          remove();
        }
      };
      const rpc = (name: string) =>
        api("/rest/v1/rpc/taskfold_account_removal_" + name, {
          _account: account,
        });
      const current = async () =>
        manifest(await rpc("repair_manifest"), account);
      if (applying) {
        if (
          input.confirmation !== account || typeof input.review !== "string" ||
          input.review.length > 2048 ||
          !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]{43}$/.test(input.review)
        ) throw new Refusal("review_required", 409);
        let reviewedDigest: string;
        try {
          const [payload, signature] = input.review.split(".");
          if (
            !await crypto.subtle.verify(
              "HMAC",
              key,
              decode(signature),
              encoder.encode(payload),
            )
          ) throw Error("signature");
          const claims = object(
            JSON.parse(
              new TextDecoder("utf-8", { fatal: true }).decode(decode(payload)),
            ),
          );
          exact(claims, [
            "v",
            "scope",
            "origin",
            "account",
            "digest",
            "expires",
          ]);
          if (
            claims.v !== 1 ||
            claims.scope !== "account-removal-residual-repair" ||
            claims.origin !== origin || claims.account !== account ||
            typeof claims.digest !== "string" || !sha.test(claims.digest) ||
            typeof claims.expires !== "number" ||
            !Number.isSafeInteger(claims.expires) ||
            claims.expires <= now() || claims.expires > now() + 900000
          ) throw Error("claims");
          reviewedDigest = claims.digest;
        } catch {
          throw new Refusal("review_required", 409);
        }
        const plan = await current();
        if (!same(reviewedDigest, await hash(JSON.stringify(plan)))) {
          throw new Refusal("review_changed", 409);
        }
        const buckets = new Map<string, File[]>();
        for (const file of plan.files) {
          buckets.set(file.bucket, [
            ...(buckets.get(file.bucket) ?? []),
            file,
          ]);
        }
        for (const [bucket, files] of buckets) {
          // Recheck Auth absence and exact identities/stamps before each API batch.
          const fresh = await current();
          if (
            files.some((f) =>
              !fresh.files.some((n) => JSON.stringify(n) === JSON.stringify(f))
            )
          ) throw new Refusal("review_changed", 409);
          await api("/storage/v1/object/" + encodeURIComponent(bucket), {
            prefixes: files.map((f) => f.name),
          }, "DELETE");
        }
        const absent = await rpc("absent");
        if (typeof absent !== "boolean") throw Error("absence");
        return json(
          { complete: absent, reviewRequired: !absent },
          absent ? 200 : 202,
        );
      }
      const plan = await current();
      const payload = encode(
        encoder.encode(
          JSON.stringify({
            v: 1,
            scope: "account-removal-residual-repair",
            origin,
            account,
            digest: await hash(JSON.stringify(plan)),
            expires: now() + 900000,
          }),
        ),
      );
      return json({ ...plan, review: payload + "." + await sign(payload) });
    } catch (error) {
      return error instanceof Refusal
        ? json({ code: error.code }, error.status)
        : json({
          code: "retry",
          message:
            "Repair is not confirmed. Some files may already be removed. Review the remaining files before retrying.",
        }, 503);
    } finally {
      clearTimeout(timer);
    }
  };
}

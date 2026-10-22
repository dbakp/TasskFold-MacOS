import { issueProof, verifyProof } from "./proof.ts";
type Config = { url: string; serviceKey: string };
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  now?: () => number;
};
type Grant = { account: string; complete: boolean };
type File = { bucket: string; name: string };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
class Refusal extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}
const failure =
  "Account removal isn't finished. Some files may already be removed. Please try again.";
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
const digest = async (token: string) =>
  [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token)),
    ),
  ].map((x) => x.toString(16).padStart(2, "0")).join("");
async function limited(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      size += item.value.length;
      if (size > 2_000_000) throw new Error("Response limit");
      parts.push(item.value);
    }
  } catch (error) {
    await reader.cancel();
    throw error;
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return size ? JSON.parse(new TextDecoder().decode(bytes)) : null;
}
function grant(value: unknown): Grant | null {
  if (value === null) return null;
  const row = value as Grant;
  if (!row || !uuid.test(row.account) || typeof row.complete !== "boolean") {
    throw new Error("Invalid authorization response");
  }
  return row;
}
export function createHandler(config: Config, dependencies: Dependencies = {}) {
  const send = dependencies.send ?? fetch, now = dependencies.now ?? Date.now;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json({ error: "Use POST to remove an account." }, 405);
    }
    const token = /^Bearer ([^\s]{1,8192})$/i.exec(
      request.headers.get("Authorization") ?? "",
    )?.[1];
    if (!token) return json({ error: "Sign in to remove your account." }, 401);
    // Compatibility is not authorization. Old callers must upgrade to the
    // durable native recovery contract before starting an irreversible command.
    if (request.headers.get("X-Taskfold-Account-Removal") !== "2") {
      return json(
        { error: "Update Taskfold before removing your account." },
        428,
      );
    }

    let origin: string;
    try {
      const url = new URL(config.url);
      if (url.protocol !== "https:" || !config.serviceKey) throw new Error();
      origin = url.origin;
    } catch {
      return json(
        { error: "Account removal is temporarily unavailable." },
        503,
      );
    }
    const deadline = now() + 20_000;
    async function api(
      path: string,
      method = "GET",
      body?: unknown,
      bearer = config.serviceKey,
    ) {
      const remaining = deadline - now();
      if (remaining <= 0) throw new Error("Deadline");
      const controller = new AbortController(),
        timer = setTimeout(
          () => controller.abort(),
          Math.min(8_000, remaining),
        );
      try {
        const response = await send(
          new Request(origin + path, {
            method,
            redirect: "error",
            signal: controller.signal,
            headers: {
              apikey: config.serviceKey,
              Authorization: "Bearer " + bearer,
              "Content-Type": "application/json",
            },
            body: body === undefined ? undefined : JSON.stringify(body),
          }),
        );
        return { status: response.status, value: await limited(response) };
      } finally {
        clearTimeout(timer);
      }
    }
    async function rpc(name: string, args: Record<string, unknown>) {
      const response = await api(
        "/rest/v1/rpc/taskfold_account_removal_" + name,
        "POST",
        args,
      );
      if (response.status < 200 || response.status >= 300) {
        if ((response.value as { code?: string })?.code === "28000") {
          throw new Refusal(401, "Sign in again to remove your account.");
        }
        throw new Error("Removal service unavailable");
      }
      return response.value;
    }
    try {
      // Do not permit the caller to nominate an account, storage path or admin option.
      const reader = request.body?.getReader();
      let bytes = new Uint8Array();
      if (reader) {
        let timedOut = false;
        const timer = setTimeout(() => {
          timedOut = true;
          void reader.cancel().catch(() => {});
        }, 2000);
        try {
          const parts: Uint8Array[] = [];
          let size = 0;
          while (true) {
            const item = await reader.read();
            if (item.done) break;
            size += item.value.length;
            if (size > 2048) {
              await reader.cancel();
              return json({ error: "Removal request is too large." }, 413);
            }
            parts.push(item.value);
          }
          if (timedOut) {
            throw new Refusal(
              408,
              "The removal request took too long. Please try again.",
            );
          }
          bytes = new Uint8Array(size);
          let offset = 0;
          for (const part of parts) {
            bytes.set(part, offset);
            offset += part.length;
          }
        } finally {
          clearTimeout(timer);
        }
      }
      let body: unknown;
      try {
        body = bytes.length ? JSON.parse(new TextDecoder().decode(bytes)) : {};
      } catch {
        return json({ error: "Use an empty removal request." }, 400);
      }
      const preparing = !!body && typeof body === "object" &&
        !Array.isArray(body) && Object.keys(body).length === 1 &&
        (body as { action?: unknown }).action === "prepare";
      if (
        !body || typeof body !== "object" || Array.isArray(body) ||
        (!preparing && Object.keys(body).length)
      ) return json({ error: "Use a reviewed account-removal request." }, 400);
      const proofHeader = request.headers.get(
        "X-Taskfold-Account-Removal-Proof",
      );
      let proofAccount: string | null = null;
      if (!preparing) {
        if (!proofHeader) {
          return json(
            { error: "Prepare account removal before continuing." },
            428,
          );
        }
        proofAccount = await verifyProof(
          proofHeader,
          origin,
          now(),
          (id) => rpc("proof_key", { _id: id }),
        );
        if (!proofAccount) {
          throw new Refusal(
            401,
            "Account removal needs a valid recovery proof.",
          );
        }
      }
      const hash = await digest(token), key = { _token_hash: hash };
      let authority = grant(await rpc("status", key));
      if (authority && proofAccount && authority.account !== proofAccount) {
        throw new Refusal(401, "Removal authorization does not match.");
      }
      // A durable signed proof can confirm absence after receipt expiry, but
      // cannot authorize any destructive operation on an existing account.
      if (
        !authority && proofAccount &&
        await rpc("absent", { _account: proofAccount }) === true
      ) return json({ deleted: true });
      if (!authority) {
        const authenticated = await api(
          "/auth/v1/user",
          "GET",
          undefined,
          token,
        );
        if (authenticated.status === 401 || authenticated.status === 403) {
          throw new Refusal(401, "Sign in again to remove your account.");
        }
        if (authenticated.status !== 200) {
          throw new Error("Authentication service unavailable");
        }
        const user = authenticated.value as { id?: string };
        let claims: { sub?: string; session_id?: string };
        try {
          claims = JSON.parse(
            atob(token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/")),
          );
        } catch {
          throw new Refusal(401, "Sign in again to remove your account.");
        }
        if (
          !user?.id || !uuid.test(user.id) || claims.sub !== user.id ||
          !uuid.test(claims.session_id ?? "")
        ) throw new Refusal(401, "Sign in again to remove your account.");
        if (proofAccount && user.id !== proofAccount) {
          throw new Refusal(401, "Removal authorization does not match.");
        }
        authority = grant(
          await rpc("begin", {
            ...key,
            _account: user.id,
            _session: claims.session_id,
          }),
        );
        if (!authority) throw new Error("Missing authorization");
      }
      if (preparing) {
        const proof = await issueProof(
          authority.account,
          origin,
          now(),
          (id) => rpc("proof_key", { _id: id }),
        );
        return json({ prepared: true, account: authority.account, proof });
      }
      // A hash receipt is an already-authorized irreversible command, not a new
      // deletion authorized by a revoked JWT. It also confirms a lost success reply.
      if (authority.complete) return json({ deleted: true });
      let empty = false;
      for (let batch = 0; batch < 8; batch++) {
        const files = await rpc("files", key);
        if (!Array.isArray(files) || files.length > 100) {
          throw new Error("Invalid file manifest");
        }
        if (files.length === 0) {
          empty = true;
          break;
        }
        const buckets = new Map<string, string[]>();
        for (const file of files as File[]) {
          if (
            typeof file.bucket !== "string" ||
            !/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/.test(file.bucket) ||
            typeof file.name !== "string" || !file.name ||
            file.name.length > 2048
          ) throw new Error("Invalid stored object");
          buckets.set(file.bucket, [
            ...(buckets.get(file.bucket) ?? []),
            file.name,
          ]);
        }
        for (const [bucket, names] of buckets) {
          const removed = await api(
            "/storage/v1/object/" + encodeURIComponent(bucket),
            "DELETE",
            { prefixes: names },
          );
          if (removed.status < 200 || removed.status >= 300) {
            throw new Error("Storage removal failed");
          }
        }
      }
      if (!empty) throw new Error("More files remain");
      const account = await rpc("prepare", key);
      if (account !== authority.account) {
        throw new Error("Removal owner changed");
      }
      const removed = await api("/auth/v1/admin/users/" + account, "DELETE", {
        should_soft_delete: false,
      });
      if (removed.status < 200 || removed.status >= 300) {
        const existing = await api("/auth/v1/admin/users/" + account);
        if (existing.status !== 404) throw new Error("Auth removal failed");
      }
      if (await rpc("complete", key) !== true) {
        throw new Error("Removal not confirmed");
      }
      return json({ deleted: true });
    } catch (error) {
      if (error instanceof Refusal) {
        return json({ error: error.message }, error.status);
      }
      return json({ error: failure }, 503);
    }
  };
}

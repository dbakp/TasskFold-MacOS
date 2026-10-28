import {
  audio64,
  bucket,
  exact,
  identity,
  key,
  maximumAudioBytes,
  maximumEnvelopeBytes,
  object,
  path,
  publication,
  publicReceipt,
  receipt,
  type Row,
  target,
  verifyAudio,
} from "./wire.ts";
type Config = {
  url: string;
  serviceKey: string;
  enabled?: boolean;
  timeoutMilliseconds?: number;
};
type Dependencies = { send?: (request: Request) => Promise<Response> };
class Failure extends Error {
  constructor(readonly status: number, readonly code: string) {
    super(code);
  }
}
const headers = {
  "Cache-Control": "private, no-store",
  "Pragma": "no-cache",
  "Vary": "Authorization",
  "X-Content-Type-Options": "nosniff",
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Expose-Headers": "Retry-After, X-Audio-SHA256",
};
const json = (
  value: unknown,
  status = 200,
  extra: Record<string, string> = {},
) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { ...headers, "Content-Type": "application/json", ...extra },
  });
function bounded<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(new Failure(503, "retry"));
    work.then(resolve, reject).finally(() =>
      signal.removeEventListener("abort", abort)
    );
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}
async function bytes(
  stream: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
) {
  if (!stream) throw new Failure(400, "invalid");
  const reader = stream.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    signal.throwIfAborted();
    while (true) {
      const part = await bounded(reader.read(), signal);
      signal.throwIfAborted();
      if (part.done) break;
      if ((size += part.value.length) > maximum) {
        throw new Failure(413, "too_large");
      }
      chunks.push(part.value);
    }
    const result = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      result.set(chunk, offset);
      offset += chunk.length;
    }
    return result;
  } catch (error) {
    cancel();
    throw error;
  } finally {
    signal.removeEventListener("abort", cancel);
    try {
      reader.releaseLock();
    } catch { /* Aborted stream unwinding. */ }
  }
}
async function readJSON(
  response: Response,
  maximum: number,
  signal: AbortSignal,
) {
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(
      await bytes(response.body, maximum, signal),
    ),
  );
}
function refused(value: unknown): never {
  const row = object(value);
  const status = String(row.status);
  if (status === "quota") throw new Failure(409, "storage_limit");
  if (["expired", "retired", "conflict"].includes(status)) {
    throw new Failure(409, "review");
  }
  if (status === "unavailable") throw new Failure(404, "unavailable");
  if (status === "disabled") throw new Failure(503, "disabled");
  throw new Failure(503, "retry");
}
function actorFromToken(token: string) {
  const parts = token.split(".");
  if (parts.length !== 3 || parts[1].length > 12000) {
    throw new Failure(401, "sign_in");
  }
  const text = parts[1].replaceAll("-", "+").replaceAll("_", "/");
  const row = object(
    JSON.parse(atob(text + "=".repeat((4 - text.length % 4) % 4))),
  );
  if (!identity(row.sub) || !identity(row.session_id)) {
    throw new Failure(401, "sign_in");
  }
  return { account: row.sub, session: row.session_id };
}
const sameMedia = (a: Row, b: Row) =>
  key(
    Object.fromEntries(
      ["operation_id", "comment_id", "asset_id", "target", "caption", "audio"]
        .map((k) => [k, a[k]]),
    ),
  ) ===
    key(
      Object.fromEntries(
        ["operation_id", "comment_id", "asset_id", "target", "caption", "audio"]
          .map((k) => [k, b[k]]),
      ),
    );
export function createAudioCommentsHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
    const cancelInput = () => {
      void request.body?.cancel().catch(() => {});
    };
    if (request.method === "OPTIONS") {
      cancelInput();
      return new Response(null, {
        status: 204,
        headers: {
          ...headers,
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers":
            "authorization, content-type, apikey, x-client-info",
          "Access-Control-Max-Age": "600",
        },
      });
    }
    let retryAfter = 0;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    try {
      const url = new URL(request.url), action = url.searchParams.get("action");
      if (request.method !== "POST") throw new Failure(405, "method");
      if (
        !action ||
        !["publish", "list", "download", "remove"].includes(action) ||
        [...url.searchParams.keys()].some((k) => k !== "action") ||
        url.searchParams.getAll("action").length !== 1
      ) throw new Failure(400, "invalid");
      // Removal remains available after publication is disabled; the database still
      // requires current user authority. Maintenance has no public handler route.
      if (config.enabled !== true && action !== "remove") {
        throw new Failure(503, "disabled");
      }
      const origin = new URL(config.url);
      if (
        origin.protocol !== "https:" || origin.username || origin.password ||
        origin.pathname !== "/" || origin.search || origin.hash ||
        !config.serviceKey || /\s/.test(config.serviceKey)
      ) throw new Failure(503, "retry");
      if (
        request.headers.get("content-type")?.split(";")[0].trim()
            .toLowerCase() !== "application/json" ||
        request.headers.has("content-encoding")
      ) throw new Failure(415, "invalid");
      const maximum = action === "publish" ? maximumEnvelopeBytes : 32000,
        length = request.headers.get("content-length");
      if (
        length !== null &&
        (!/^\d{1,12}$/.test(length) || Number(length) > maximum)
      ) throw new Failure(413, "too_large");
      const authorization = request.headers.get("authorization") ?? "",
        token = /^Bearer ([^\s]{1,16384})$/i.exec(authorization)?.[1];
      if (!token) throw new Failure(401, "sign_in");
      const duration = Math.max(
        50,
        Math.min(30000, config.timeoutMilliseconds ?? 20000),
      );
      const expiry = new AbortController();
      deadline = setTimeout(() => expiry.abort(), duration);
      const signal = AbortSignal.any([request.signal, expiry.signal]);
      const upstreamJSON = async (response: Response, maximum: number) => {
        try {
          return await readJSON(response, maximum, signal);
        } catch {
          throw new Failure(503, "retry");
        }
      };
      const fetchResponse = async (route: string, init: RequestInit) => {
        signal.throwIfAborted();
        const sent = send(
          new Request(origin.origin + route, {
            ...init,
            redirect: "error",
            signal,
          }),
        );
        sent.then((r) => {
          if (signal.aborted) void r.body?.cancel().catch(() => {});
        }, () => {});
        const response = await bounded(sent, signal);
        if (signal.aborted) {
          void response.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        return response;
      };
      const serviceHeaders = {
        "apikey": config.serviceKey,
        "Authorization": "Bearer " + config.serviceKey,
      };
      const auth = await fetchResponse("/auth/v1/user", {
        method: "GET",
        headers: {
          "apikey": config.serviceKey,
          "Authorization": authorization,
        },
      });
      if (auth.status === 401 || auth.status === 403) {
        void auth.body?.cancel().catch(() => {});
        throw new Failure(401, "sign_in");
      }
      if (!auth.ok) {
        void auth.body?.cancel().catch(() => {});
        throw new Failure(503, "retry");
      }
      const user = object(await upstreamJSON(auth, 64000));
      let actor: { account: string; session: string };
      try {
        actor = actorFromToken(token);
      } catch {
        throw new Failure(401, "sign_in");
      }
      if (!identity(user.id) || user.id !== actor.account) {
        throw new Failure(401, "sign_in");
      }
      const rpc = async (name: string, input: Row) => {
        const result = await fetchResponse("/rest/v1/rpc/" + name, {
          method: "POST",
          headers: { ...serviceHeaders, "Content-Type": "application/json" },
          body: JSON.stringify(input),
        });
        if (!result.ok) {
          void result.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        return object(await upstreamJSON(result, 640000));
      };
      const admitted = await rpc("taskfold_audio_comment_admit", {
        _actor: actor.account,
        _session: actor.session,
        _action: action,
      });
      if (admitted.allowed !== true) {
        if (
          admitted.status === "rate_limited" &&
          Number.isInteger(admitted.retry_after) &&
          Number(admitted.retry_after) >= 1 &&
          Number(admitted.retry_after) <= 60
        ) {
          retryAfter = Number(admitted.retry_after);
          throw new Failure(429, "rate_limited");
        }
        refused(admitted);
      }
      exact(admitted, ["protocol", "account", "allowed", "retry_after"]);
      if (
        admitted.protocol !== 1 || admitted.account !== actor.account ||
        admitted.retry_after !== 0
      ) throw new Failure(503, "retry");
      let body: Row;
      try {
        body = object(
          JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(
              await bytes(request.body, maximum, signal),
            ),
          ),
        );
      } catch (error) {
        if (signal.aborted) throw new Failure(503, "retry");
        if (error instanceof Failure) throw error;
        throw new Failure(400, "invalid");
      }
      const command = (kind: string, body: Row) =>
        rpc("taskfold_audio_comment_command", {
          _action: kind,
          _actor: actor.account,
          _session: actor.session,
          _body: body,
        });
      const getStored = async (row: Row, missing: boolean) => {
        const result = await fetchResponse(
          "/storage/v1/object/" + bucket + "/" + path(row),
          {
            method: "GET",
            headers: { ...serviceHeaders, "Accept-Encoding": "identity" },
          },
        );
        if (missing && result.status === 404) {
          void result.body?.cancel().catch(() => {});
          return null;
        }
        if (!result.ok) {
          void result.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        if (
          result.headers.get("content-type")?.split(";")[0].toLowerCase() !==
            "audio/mp4"
        ) {
          void result.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        try {
          const stored = await bytes(result.body, maximumAudioBytes, signal);
          await verifyAudio(stored, row.audio);
          signal.throwIfAborted();
          return stored;
        } catch {
          throw new Failure(503, "retry");
        }
      };
      if (action === "publish") {
        let intent: Row, audio: Uint8Array;
        try {
          exact(body, ["intent", "audio_base64"]);
          intent = publication(body.intent);
          if (intent.account !== actor.account) throw Error();
          audio = audio64(body.audio_base64);
          await verifyAudio(audio, intent.audio);
          signal.throwIfAborted();
        } catch {
          if (signal.aborted) throw new Failure(503, "retry");
          throw new Failure(400, "invalid");
        }
        const reserved = await command("reserve", intent);
        if (reserved.status) refused(reserved);
        let current = receipt(reserved, actor.account, intent),
          stored = await getStored(current, true);
        if (stored === null) {
          if (current.state === "published") throw new Failure(503, "retry"); // Never resurrect a missing acknowledged object.
          const fresh = await command("reserve", intent);
          if (fresh.status) refused(fresh);
          current = receipt(fresh, actor.account, intent);
          if (current.state === "pending") {
            const lease = await command("upload_begin", {
              operation_id: intent.operation_id,
            });
            if (lease.status) refused(lease);
            exact(lease, ["protocol", "operation_id", "ticket_id", "state"]);
            if (
              lease.protocol !== 1 ||
              lease.operation_id !== intent.operation_id ||
              !identity(lease.ticket_id) || lease.state !== "open"
            ) throw new Failure(503, "retry");
            try {
              const upload = await fetchResponse(
                "/storage/v1/object/" + bucket + "/" + path(current),
                {
                  method: "POST",
                  headers: {
                    ...serviceHeaders,
                    "Content-Type": "audio/mp4",
                    "cache-control": "max-age=0",
                    "x-upsert": "false",
                  },
                  body: audio as BodyInit,
                },
              );
              void upload.body?.cancel().catch(() => {});
              // Only a definite successful/conflict response settles the request.
              // Timeout/5xx outcomes remain fenced until verified finalization.
              if (upload.ok || upload.status === 409) {
                const settled = await command("upload_settle", {
                  operation_id: intent.operation_id,
                  ticket_id: lease.ticket_id,
                });
                if (settled.protocol !== 1 || settled.settled !== true) {
                  throw new Failure(503, "retry");
                }
              }
            } catch (error) {
              if (signal.aborted) {
                throw error; /* A lost upload acknowledgement must be reconciled by readback. */
              }
            }
          }
          stored = await getStored(current, false);
        }
        if (!stored) throw new Failure(503, "retry");
        const observed = await verifyAudio(stored, intent.audio);
        const finalized = await command("finalize", {
          intent,
          stored_sha256: observed.sha256,
          stored_bytes: observed.byteCount,
        });
        if (finalized.status) refused(finalized);
        const confirmed = receipt(finalized, actor.account, intent);
        if (confirmed.state !== "published") throw new Failure(503, "retry");
        signal.throwIfAborted();
        return json({ receipt: publicReceipt(confirmed) });
      }
      if (action === "list") {
        try {
          target(body);
        } catch {
          throw new Failure(400, "invalid");
        }
        const result = await command("list", body);
        if (result.status) refused(result);
        exact(result, ["protocol", "account", "items"]);
        if (
          result.protocol !== 1 || result.account !== actor.account ||
          !Array.isArray(result.items) || result.items.length > 20
        ) throw new Failure(503, "retry");
        const items = result.items.map((value) => {
          const r = receipt(value, actor.account);
          if (r.state !== "published" || key(r.target) !== key(body)) {
            throw Error("list");
          }
          return publicReceipt(r);
        });
        if (new Set(items.map((r) => r.comment_id)).size !== items.length) {
          throw new Failure(503, "retry");
        }
        return json({ protocol: 1, account: actor.account, items });
      }
      try {
        exact(body, ["comment_id"]);
        if (!identity(body.comment_id)) throw Error();
      } catch {
        throw new Failure(400, "invalid");
      }
      if (action === "remove") {
        const result = await command("remove", body);
        if (result.status) refused(result);
        exact(result, [
          "protocol",
          "account",
          "operation_id",
          "comment_id",
          "state",
        ]);
        if (
          result.protocol !== 1 || result.account !== actor.account ||
          result.comment_id !== body.comment_id ||
          !identity(result.operation_id) ||
          !["retired", "purged"].includes(String(result.state))
        ) throw new Failure(503, "retry");
        return json(result);
      }
      const first = await command("read", body);
      if (first.status) refused(first);
      const readable = receipt(first, actor.account);
      if (
        readable.state !== "published" ||
        readable.comment_id !== body.comment_id
      ) throw new Failure(503, "retry");
      const stored = await getStored(readable, false);
      if (!stored) throw new Failure(503, "retry");
      const second = await command("read", body);
      if (second.status) refused(second);
      const live = receipt(second, actor.account);
      if (live.state !== "published" || !sameMedia(readable, live)) {
        throw new Failure(503, "retry");
      }
      signal.throwIfAborted();
      return new Response(stored as BodyInit, {
        headers: {
          ...headers,
          "Content-Type": "audio/mp4",
          "Content-Disposition": 'inline; filename="recording.m4a"',
          "X-Audio-SHA256": String(object(live.audio).sha256),
        },
      });
    } catch (error) {
      cancelInput();
      const failure = error instanceof Failure
        ? error
        : new Failure(503, "retry");
      const message = failure.code === "sign_in"
        ? "Sign in again to continue. Your saved work is unchanged."
        : failure.code === "storage_limit"
        ? "Recording storage is full. Your local draft is unchanged."
        : failure.code === "invalid" || failure.code === "too_large"
        ? "Choose a complete supported recording. Your saved work is unchanged."
        : failure.code === "review"
        ? "Review this recording before sending again. Your local draft is unchanged."
        : failure.code === "rate_limited"
        ? "Please wait briefly before trying again."
        : "Recording unavailable. Your saved work is unchanged.";
      return json(
        { error: message, code: failure.code },
        failure.status,
        retryAfter ? { "Retry-After": String(retryAfter) } : {},
      );
    } finally {
      if (deadline !== undefined) clearTimeout(deadline);
    }
  };
}

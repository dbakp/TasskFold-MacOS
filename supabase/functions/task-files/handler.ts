// No provider URL, service key, signed URL or client-authored custody proof is
// returned. Both app repositories own this source independently.
type Row = Record<string, unknown>;
type Config = {
  url: string;
  serviceKey: string;
  enabled?: boolean;
  timeoutMilliseconds?: number;
};
type Dependencies = { send?: (request: Request) => Promise<Response> };
class Failure extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    readonly retryAfter = 0,
  ) {
    super(code);
  }
}
const maximum = 5 * 1024 * 1024;
const id = (v: unknown): v is string =>
  typeof v === "string" &&
  /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(v);
const sha = (v: unknown): v is string =>
  typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
const row = (v: unknown): Row => {
  if (!v || typeof v !== "object" || Array.isArray(v)) {
    throw new Failure(400, "invalid");
  }
  return v as Row;
};
const exact = (v: Row, keys: string[]) => {
  if (Object.keys(v).sort().join(",") !== keys.sort().join(",")) {
    throw new Failure(400, "invalid");
  }
};
const types = [
  "application/pdf",
  "application/octet-stream",
  "application/zip",
  "image/png",
  "image/jpeg",
  "image/webp",
  "text/plain",
];
const count = (v: unknown): v is number =>
  typeof v === "number" && Number.isInteger(v) && v > 0 && v <= maximum;
const hash = async (bytes: Uint8Array) =>
  [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(bytes)),
    ),
  ].map((v) => v.toString(16).padStart(2, "0")).join("");
const headers = {
  "Cache-Control": "private, no-store",
  "Pragma": "no-cache",
  "Vary": "Authorization",
  "X-Content-Type-Options": "nosniff",
};
const json = (
  value: unknown,
  status = 200,
  extra: Record<string, string> = {},
) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { ...headers, ...extra, "Content-Type": "application/json" },
  });
async function bounded<T>(
  promise: Promise<T>,
  signal: AbortSignal,
): Promise<T> {
  return await new Promise((resolve, reject) => {
    const stop = () => reject(new Failure(503, "retry"));
    if (signal.aborted) {
      stop();
      return;
    }
    signal.addEventListener("abort", stop, { once: true });
    promise.then(resolve, reject).finally(() =>
      signal.removeEventListener("abort", stop)
    );
  });
}
async function read(
  stream: ReadableStream<Uint8Array> | null,
  limit: number,
  signal: AbortSignal,
) {
  if (!stream) throw new Failure(400, "invalid");
  const reader = stream.getReader(), chunks: Uint8Array[] = [];
  let length = 0;
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      const value = await bounded(reader.read(), signal);
      signal.throwIfAborted();
      if (value.done) break;
      if ((length += value.value.length) > limit) {
        throw new Failure(413, "too_large");
      }
      chunks.push(value.value);
    }
    const result = new Uint8Array(length);
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
    } catch { /* cancelled reader unwinds */ }
  }
}
function intent(value: unknown) {
  const i = row(value);
  exact(i, ["operation_id", "target", "name", "type", "byte_count", "sha256"]);
  const t = row(i.target);
  exact(t, ["team_id", "project_id", "task_id", "task_generation"]);
  if (
    !id(i.operation_id) || !Object.values(t).every(id) ||
    !count(i.byte_count) || !sha(i.sha256) || typeof i.name !== "string" ||
    i.name.length < 1 || i.name.length > 240 ||
    [...i.name].some((c) =>
      c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127 || c === "/" || c === "\\"
    ) || [".", ".."].includes(i.name) ||
    !types.includes(String(i.type))
  ) throw new Failure(400, "invalid");
  return i;
}
function receipt(value: unknown, account: string, operation: string) {
  const r = row(value);
  exact(r, [
    "protocol",
    "account",
    "operation_id",
    "target",
    "state",
    "attachment",
  ]);
  const target = row(r.target);
  exact(target, ["team_id", "project_id", "task_id", "task_generation"]);
  if (
    r.protocol !== 1 || r.account !== account || r.operation_id !== operation ||
    !Object.values(target).every(id) ||
    !["reserved", "published", "cancelled", "expired"].includes(String(r.state))
  ) throw new Failure(503, "retry");
  if (r.state === "published") {
    const a = row(r.attachment);
    exact(a, [
      "id",
      "storage_object_id",
      "name",
      "size",
      "type",
      "sha256",
      "uploadedAt",
    ]);
    if (
      a.id !== operation || !id(a.storage_object_id) ||
      typeof a.name !== "string" || a.name.length > 240 || !count(a.size) ||
      !types.includes(String(a.type)) || !sha(a.sha256) ||
      typeof a.uploadedAt !== "string" ||
      !Number.isFinite(Date.parse(a.uploadedAt))
    ) throw new Failure(503, "retry");
  } else if (r.attachment !== null) throw new Failure(503, "retry");
  return r;
}
function status(r: Row): never {
  if (
    r.status === "rate_limited" && Number.isInteger(r.retry_after) &&
    Number(r.retry_after) >= 1 && Number(r.retry_after) <= 60
  ) throw new Failure(429, "rate_limited", Number(r.retry_after));
  if (r.status === "unavailable") throw new Failure(404, "unavailable");
  if (r.status === "disabled") throw new Failure(503, "disabled");
  if (r.status === "quota") throw new Failure(409, "quota");
  if (["conflict", "verification_failed"].includes(String(r.status))) {
    throw new Failure(409, "review");
  }
  throw new Failure(503, "retry");
}
export function createTaskFilesHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const url = new URL(request.url), action = url.searchParams.get("action");
      if (request.method !== "POST") throw new Failure(405, "method");
      if (
        !action ||
        !["publish", "resolve", "cancel", "download"].includes(action) ||
        url.searchParams.size !== 1 ||
        url.searchParams.getAll("action").length !== 1
      ) throw new Failure(400, "invalid");
      if (action === "publish" && config.enabled !== true) {
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
      const token = /^Bearer ([^\s]{1,16384})$/i.exec(
        request.headers.get("authorization") ?? "",
      )?.[1];
      if (!token) throw new Failure(401, "sign_in");
      const abort = new AbortController();
      timer = setTimeout(
        () => abort.abort(),
        Math.max(50, Math.min(30000, config.timeoutMilliseconds ?? 25000)),
      );
      const signal = AbortSignal.any([abort.signal, request.signal]);
      const fetchResponse = async (path: string, init: RequestInit) => {
        signal.throwIfAborted();
        const pending = send(
          new Request(origin.origin + path, {
            ...init,
            signal,
            redirect: "error",
          }),
        );
        pending.then((r) => {
          if (signal.aborted) void r.body?.cancel().catch(() => {});
        }, () => {});
        return await bounded(pending, signal);
      };
      const parsed = async (response: Response, limit = 64000) =>
        row(
          JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(
              await read(response.body, limit, signal),
            ),
          ),
        );
      const serviceHeaders = {
        "apikey": config.serviceKey,
        "Authorization": "Bearer " + config.serviceKey,
      };
      const auth = await fetchResponse("/auth/v1/user", {
        headers: {
          apikey: config.serviceKey,
          Authorization: "Bearer " + token,
        },
      });
      if (!auth.ok) {
        void auth.body?.cancel().catch(() => {});
        throw new Failure(
          auth.status === 401 || auth.status === 403 ? 401 : 503,
          auth.status === 401 || auth.status === 403 ? "sign_in" : "retry",
        );
      }
      const user = await parsed(auth);
      let claims: Row;
      try {
        const parts = token.split(".");
        if (parts.length !== 3 || parts[1].length > 12000) throw new Error();
        const text = parts[1].replaceAll("-", "+").replaceAll("_", "/");
        claims = row(
          JSON.parse(atob(text + "=".repeat((4 - text.length % 4) % 4))),
        );
      } catch {
        throw new Failure(401, "sign_in");
      }
      if (!id(claims.sub) || claims.sub !== user.id || !id(claims.session_id)) {
        throw new Failure(401, "sign_in");
      }
      const account = claims.sub, session = claims.session_id;
      const rpc = async (action: string, body: Row) => {
        const response = await fetchResponse(
          "/rest/v1/rpc/taskfold_task_file_command",
          {
            method: "POST",
            headers: { ...serviceHeaders, "Content-Type": "application/json" },
            body: JSON.stringify({
              _action: action,
              _actor: account,
              _session: session,
              _body: body,
            }),
          },
        );
        if (!response.ok) {
          void response.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        return await parsed(response, 1000000);
      };
      let body: Row;
      try {
        body = row(
          JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(
              await read(
                request.body,
                action === "publish" ? 7100000 : 32000,
                signal,
              ),
            ),
          ),
        );
      } catch (error) {
        if (error instanceof Failure) throw error;
        throw new Failure(400, "invalid");
      }
      const terminal = (reply: Row, operation: string) => {
        if (
          !["published", "cancelled", "expired", "reserved"].includes(
            String(reply.status),
          )
        ) status(reply);
        const r = receipt(reply.receipt, account, operation);
        if (r.state !== reply.status) throw new Failure(503, "retry");
        return r;
      };
      if (action === "resolve" || action === "cancel") {
        exact(body, ["operation_id"]);
        if (!id(body.operation_id)) throw new Failure(400, "invalid");
        return json({
          receipt: terminal(await rpc(action, body), body.operation_id),
        });
      }
      const stored = async (path: string) => {
        const result = await fetchResponse(
          "/storage/v1/object/authenticated/task-attachments/" + path,
          { headers: serviceHeaders },
        );
        if (!result.ok) {
          void result.body?.cancel().catch(() => {});
          throw new Failure(503, "retry");
        }
        return await read(result.body, maximum, signal);
      };
      if (action === "download") {
        exact(body, ["object_id", "task_id", "task_generation"]);
        if (!Object.values(body).every(id)) throw new Failure(400, "invalid");
        const authorize = (reply: Row) => {
          if (reply.status !== "download") status(reply);
          exact(reply, [
            "status",
            "object_name",
            "sha256",
            "byte_count",
            "mime",
          ]);
          if (
            typeof reply.object_name !== "string" ||
            !/^team-task-files\/v1\/[a-f0-9-]{36}$/.test(reply.object_name) ||
            !id(reply.object_name.split("/").at(-1)) || !sha(reply.sha256) ||
            !count(reply.byte_count) || !types.includes(String(reply.mime))
          ) throw new Failure(503, "retry");
          return reply;
        };
        const first = authorize(await rpc("download", body)),
          data = await stored(String(first.object_name));
        if (
          data.length !== first.byte_count || await hash(data) !== first.sha256
        ) throw new Failure(409, "review");
        const second = authorize(await rpc("download", body));
        if (
          ["object_name", "sha256", "byte_count", "mime"].some((k) =>
            first[k] !== second[k]
          )
        ) throw new Failure(409, "review");
        return new Response(data, {
          headers: {
            ...headers,
            "Content-Type": String(first.mime),
            "Content-Disposition": "attachment",
            "X-File-SHA256": String(first.sha256),
          },
        });
      }
      exact(body, ["intent", "bytes_base64"]);
      const i = intent(body.intent);
      if (
        typeof body.bytes_base64 !== "string" ||
        body.bytes_base64.length !== 4 * Math.ceil(Number(i.byte_count) / 3) ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(body.bytes_base64)
      ) throw new Failure(400, "invalid");
      let data: Uint8Array<ArrayBuffer>;
      try {
        const text = atob(body.bytes_base64);
        if (btoa(text) !== body.bytes_base64) throw new Error();
        data = Uint8Array.from(text, (c) => c.charCodeAt(0));
      } catch {
        throw new Failure(400, "invalid");
      }
      if (data.length !== i.byte_count || await hash(data) !== i.sha256) {
        throw new Failure(400, "invalid");
      }
      const reserved = await rpc("reserve", i),
        r = terminal(reserved, String(i.operation_id));
      if (r.state !== "reserved") return json({ receipt: r });
      if (JSON.stringify(r.target) !== JSON.stringify(i.target)) {
        const target = row(r.target), expected = row(i.target);
        if (Object.keys(expected).some((k) => target[k] !== expected[k])) {
          throw new Failure(503, "retry");
        }
      }
      const path = "team-task-files/v1/" + i.operation_id;
      if (reserved.object_name !== path) throw new Failure(503, "retry");
      const uploaded = await fetchResponse(
        "/storage/v1/object/task-attachments/" + path,
        {
          method: "POST",
          headers: {
            ...serviceHeaders,
            "Content-Type": String(i.type),
            "x-upsert": "false",
          },
          body: data,
        },
      );
      const accepted = uploaded.ok || uploaded.status === 400 ||
        uploaded.status === 409;
      void uploaded.body?.cancel().catch(() => {});
      if (!accepted) throw new Failure(503, "retry");
      const verified = await stored(path);
      if (
        verified.length !== i.byte_count || await hash(verified) !== i.sha256
      ) throw new Failure(409, "review");
      const result = await rpc("finalize", {
        intent: i,
        stored_sha256: await hash(verified),
        stored_bytes: verified.length,
      });
      return json({ receipt: terminal(result, String(i.operation_id)) });
    } catch (error) {
      void request.body?.cancel().catch(() => {});
      const failure = error instanceof Failure
        ? error
        : new Failure(503, "retry");
      return json(
        { error: failure.code },
        failure.status,
        failure.retryAfter ? { "Retry-After": String(failure.retryAfter) } : {},
      );
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  };
}

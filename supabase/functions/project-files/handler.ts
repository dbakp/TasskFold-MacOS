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
const types = [
  "application/pdf",
  "application/octet-stream",
  "application/zip",
  "image/png",
  "image/jpeg",
  "image/webp",
  "text/plain",
];
const row = (v: unknown): Row => {
  if (!v || typeof v !== "object" || Array.isArray(v)) {
    throw new Failure(400, "invalid");
  }
  return v as Row;
};
const exact = (v: Row, keys: string[]) => {
  if (Object.keys(v).sort().join() !== [...keys].sort().join()) {
    throw new Failure(400, "invalid");
  }
};
const sha = async (data: Uint8Array) =>
  [
    ...new Uint8Array(
      await crypto.subtle.digest("SHA-256", new Uint8Array(data)),
    ),
  ].map((v) => v.toString(16).padStart(2, "0")).join("");
const headers = {
  "Cache-Control": "private, no-store",
  Pragma: "no-cache",
  Vary: "Authorization",
  "X-Content-Type-Options": "nosniff",
  "Content-Type": "application/json",
};
const json = (
  value: unknown,
  status = 200,
  extra: Record<string, string> = {},
) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { ...headers, ...extra },
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
  response: Response | Request,
  limit: number,
  signal: AbortSignal,
) {
  if (!response.body) throw new Failure(400, "invalid");
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let count = 0;
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    for (;;) {
      const next = await bounded(reader.read(), signal);
      signal.throwIfAborted();
      if (next.done) break;
      count += next.value.length;
      if (count > limit) throw new Failure(413, "too_large");
      chunks.push(next.value);
    }
    const bytes = new Uint8Array(count);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.length;
    }
    return bytes;
  } catch (error) {
    cancel();
    throw error;
  } finally {
    signal.removeEventListener("abort", cancel);
    try {
      reader.releaseLock();
    } catch { /* cancelled stream */ }
  }
}
function failed(value: Row): never {
  if (value.status === "disabled") throw new Failure(503, "disabled");
  if (value.status === "unavailable") throw new Failure(404, "unavailable");
  if (
    value.status === "rate_limited" && Number.isInteger(value.retry_after) &&
    Number(value.retry_after) >= 1 && Number(value.retry_after) <= 60
  ) throw new Failure(429, "rate_limited", Number(value.retry_after));
  if (
    [
      "source_changed",
      "conflict",
      "review",
      "verification_failed",
      "busy",
      "producer_closed",
      "quota",
    ].includes(String(value.status))
  ) throw new Failure(409, String(value.status));
  throw new Failure(503, "retry");
}
export function createProjectFilesHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const action = new URL(request.url).searchParams.get("action");
      if (request.method !== "POST") throw new Failure(405, "method");
      if (
        !action ||
        !["prepare", "resolve", "cancel_request", "check", "cancel", "copy"]
          .includes(action)
      ) {
        throw new Failure(400, "invalid");
      }
      if (!config.enabled && ["prepare", "copy"].includes(action)) {
        throw new Failure(503, "disabled");
      }
      const origin = new URL(config.url);
      if (
        origin.username || origin.password || origin.search || origin.hash ||
        !["", "/"].includes(origin.pathname) ||
        (origin.protocol !== "https:" &&
          !(origin.protocol === "http:" &&
            ["127.0.0.1", "localhost"].includes(origin.hostname))) ||
        !config.serviceKey
      ) throw new Failure(503, "disabled");
      const token = /^Bearer ([A-Za-z0-9_.-]+)$/.exec(
        request.headers.get("Authorization") ?? "",
      )?.[1];
      if (!token) throw new Failure(401, "unauthorized");
      const abort = new AbortController();
      timer = setTimeout(
        () => abort.abort(),
        Math.max(50, Math.min(30000, config.timeoutMilliseconds ?? 25000)),
      );
      const signal = AbortSignal.any([abort.signal, request.signal]);
      const call = async (path: string, init: RequestInit) => {
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
      const parsed = async (r: Response | Request, max = 262144) =>
        row(
          JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(
              await read(r, max, signal),
            ),
          ),
        );
      const service = {
        apikey: config.serviceKey,
        Authorization: "Bearer " + config.serviceKey,
      };
      const auth = await call("/auth/v1/user", {
        headers: {
          apikey: config.serviceKey,
          Authorization: "Bearer " + token,
        },
      });
      if (!auth.ok) {
        throw new Failure(
          auth.status >= 500 ? 503 : 401,
          auth.status >= 500 ? "retry" : "unauthorized",
        );
      }
      const actor = (await parsed(auth)).id;
      let claims: Row;
      try {
        const encoded = token.split(".")[1];
        claims = row(
          JSON.parse(atob(encoded.replaceAll("-", "+").replaceAll("_", "/"))),
        );
      } catch {
        throw new Failure(401, "unauthorized");
      }
      const session = claims.session_id;
      if (!id(actor) || !id(session) || claims.sub !== actor) {
        throw new Failure(401, "unauthorized");
      }
      const body = await parsed(request);
      if (["prepare", "resolve", "cancel_request"].includes(action)) {
        exact(body, ["request_id", "scope", "inspection_token"]);
        if (
          !id(body.request_id) || typeof body.inspection_token !== "string" ||
          !/^[a-f0-9]{64}$/.test(body.inspection_token)
        ) throw new Failure(400, "invalid");
        row(body.scope);
      } else if (action === "check") {
        exact(body, ["plan_id", "after"]);
        if (!id(body.plan_id) || (body.after !== null && !id(body.after))) {
          throw new Failure(400, "invalid");
        }
      } else {
        exact(
          body,
          action === "cancel" ? ["plan_id"] : ["plan_id", "operation_id"],
        );
        if (!Object.values(body).every(id)) throw new Failure(400, "invalid");
      }
      const rpc = async (operation: string, value: Row, files = false) => {
        const r = await call(
          "/rest/v1/rpc/" +
            (files
              ? "taskfold_task_file_command"
              : "taskfold_project_file_preparation"),
          {
            method: "POST",
            headers: { ...service, "Content-Type": "application/json" },
            body: JSON.stringify({
              _action: operation,
              _actor: actor,
              _session: session,
              _body: value,
            }),
          },
        );
        if (!r.ok) {
          void r.body?.cancel().catch(() => {});
          throw new Failure(
            r.status === 400
              ? 400
              : r.status === 403
              ? 404
              : r.status === 409
              ? 409
              : 503,
            r.status === 400
              ? "invalid"
              : r.status === 403
              ? "unavailable"
              : r.status === 409
              ? "review"
              : "retry",
          );
        }
        return await parsed(r);
      };
      const plan = (r: Row) => {
        if (r.status !== "plan") failed(r);
        const p = row(r.plan);
        exact(p, [
          "protocol",
          "plan_id",
          "request_id",
          "scope",
          "state",
          "total",
          "prepared",
          "expires_at",
          "items",
          "next",
          "project_transferred",
        ]);
        if (
          p.protocol !== 1 || !id(p.plan_id) || !id(p.request_id) ||
          p.project_transferred !== (p.state === "committed") ||
          !["preparing", "ready", "cancelled", "expired", "committed"].includes(
            String(p.state),
          ) ||
          !Number.isInteger(p.total) || Number(p.total) < 0 ||
          (Number(p.total) === 0 && p.state !== "cancelled") ||
          Number(p.total) > 10000 ||
          !Number.isInteger(p.prepared) || Number(p.prepared) < 0 ||
          Number(p.prepared) > Number(p.total) ||
          (["ready", "committed"].includes(String(p.state)) &&
            p.prepared !== p.total) ||
          !Array.isArray(p.items) || p.items.length > 100 ||
          p.items.length > Number(p.total) ||
          (p.next !== null && !id(p.next)) ||
          typeof p.expires_at !== "string" || p.expires_at.length > 40 ||
          !Number.isFinite(Date.parse(p.expires_at)) ||
          (body.plan_id !== undefined && p.plan_id !== body.plan_id) ||
          (["prepare", "resolve", "cancel_request"].includes(action) &&
            p.request_id !== body.request_id)
        ) throw new Failure(503, "retry");
        const scope = row(p.scope);
        exact(scope, [
          "team_id",
          "roots",
          "visibility",
          "folder_id",
          "parent_id",
        ]);
        if (
          !id(scope.team_id) || !Array.isArray(scope.roots) ||
          scope.roots.length < 1 || scope.roots.length > 100 ||
          !scope.roots.every(id) ||
          !["private", "team"].includes(String(scope.visibility)) ||
          (scope.folder_id !== null && !id(scope.folder_id)) ||
          (scope.parent_id !== null && !id(scope.parent_id))
        ) throw new Failure(503, "retry");
        for (const value of p.items) {
          const item = row(value);
          exact(item, ["operation_id", "label", "byte_count", "type", "state"]);
          if (
            !id(item.operation_id) || typeof item.label !== "string" ||
            item.label.length < 1 ||
            new TextEncoder().encode(item.label).length > 960 ||
            /[\u0000-\u001f\u007f]/.test(item.label) ||
            !Number.isInteger(item.byte_count) || Number(item.byte_count) < 1 ||
            Number(item.byte_count) > maximum ||
            !types.includes(String(item.type)) ||
            (["ready", "committed"].includes(String(p.state)) &&
              item.state !== "ready") ||
            !["waiting", "reserved", "ready"].includes(String(item.state))
          ) throw new Failure(503, "retry");
        }
        return p;
      };
      if (action !== "copy") {
        const result = await rpc(action, body);
        if (action === "resolve" && result.status === "absent") {
          exact(result, ["status"]);
          return json({ absent: true });
        }
        return json({ plan: plan(result) });
      }
      const source = await rpc("source", body);
      if (source.status === "plan") return json({ plan: plan(source) });
      if (source.status !== "source") failed(source);
      exact(source, ["status", "source_name", "byte_count", "mime"]);
      if (
        typeof source.source_name !== "string" ||
        !source.source_name.startsWith(actor + "/") ||
        !Number.isInteger(source.byte_count) || Number(source.byte_count) < 1 ||
        Number(source.byte_count) > maximum ||
        !types.includes(String(source.mime))
      ) throw new Failure(503, "retry");
      const path = (name: string) => {
        const segments = name.split("/");
        if (
          segments.some((part) =>
            !part || part === "." || part === ".." ||
            /[%\\\u0000-\u001f\u007f]/.test(part)
          )
        ) throw new Failure(409, "review");
        return segments.map(encodeURIComponent).join("/");
      };
      const get = async (name: string) => {
        const r = await call(
          "/storage/v1/object/authenticated/task-attachments/" + path(name),
          { headers: service },
        );
        if (!r.ok) {
          void r.body?.cancel().catch(() => {});
          throw new Failure(409, "verification_required");
        }
        return await read(r, maximum, signal);
      };
      const original = await get(source.source_name);
      if (original.length !== source.byte_count) {
        throw new Failure(409, "source_changed");
      }
      const digest = await sha(original);
      const producer = crypto.randomUUID();
      let writeAttempted = false, providerTerminal = false, reconciled = false;
      try {
        const reserved = await rpc("reserve_producer", {
          ...body,
          producer_id: producer,
          byte_count: original.length,
          sha256: digest,
        });
        if (reserved.status === "plan") return json({ plan: plan(reserved) });
        if (!["upload", "verify"].includes(String(reserved.status))) {
          failed(reserved);
        }
        exact(reserved, [
          "status",
          "object_name",
          "sha256",
          "byte_count",
          "mime",
          "ticket_id",
        ]);
        const name = reserved.object_name;
        if (
          typeof name !== "string" ||
          !/^team-task-files\/v1\/[a-f0-9-]{36}\/[a-f0-9-]{36}$/.test(name) ||
          name.split("/")[2] !== body.operation_id || !id(name.split("/")[3]) ||
          !id(reserved.ticket_id) || reserved.sha256 !== digest ||
          reserved.byte_count !== original.length ||
          reserved.mime !== source.mime
        ) throw new Failure(503, "retry");
        if (reserved.status === "upload") {
          try {
            signal.throwIfAborted();
            writeAttempted = true;
            const r = await call(
              "/storage/v1/object/task-attachments/" + path(name),
              {
                method: "POST",
                headers: {
                  ...service,
                  "Content-Type": String(source.mime),
                  "x-upsert": "false",
                },
                body: new Uint8Array(original),
              },
            );
            providerTerminal = r.ok || r.status === 409;
            // A lost response is reconciled by fully reading committed bytes. It
            // never licenses another POST or settles an absent/unfinished write.
            await read(r, 64000, signal);
          } catch {
            signal.throwIfAborted();
          }
        }
        const copied = await get(name);
        if (copied.length !== original.length || await sha(copied) !== digest) {
          throw new Failure(409, "verification_required");
        }
        const observed = await rpc("upload_reconcile", {
          operation_id: body.operation_id,
          ticket_id: reserved.ticket_id,
          stored_bytes: copied.length,
          stored_sha256: digest,
        }, true);
        if (observed.protocol !== 1 || observed.settled !== true) {
          throw new Failure(409, "verification_required");
        }
        reconciled = true;
        return json({ plan: plan(await rpc("verify", body)) });
      } finally {
        // This invocation attests only its own producer. Aborting the client
        // request must not abort a bounded, private settlement observation.
        // An indeterminate POST is deliberately left open for positive proof.
        if (!writeAttempted || providerTerminal || reconciled) {
          const terminalSignal = AbortSignal.timeout(2000);
          try {
            const pending = send(
              new Request(
                origin.origin +
                  "/rest/v1/rpc/taskfold_project_file_producer_terminal",
                {
                  method: "POST",
                  headers: { ...service, "Content-Type": "application/json" },
                  redirect: "error",
                  signal: terminalSignal,
                  body: JSON.stringify({
                    _actor: actor,
                    _body: {
                      ...body,
                      producer_id: producer,
                      proof: !writeAttempted
                        ? "not_started"
                        : providerTerminal
                        ? "provider_terminal"
                        : "verified",
                    },
                  }),
                },
              ),
            );
            pending.then((r) => {
              if (terminalSignal.aborted) void r.body?.cancel().catch(() => {});
            }, () => {});
            const reply = await bounded(pending, terminalSignal);
            // The private observation cannot replace the preparation outcome.
            // Failed/lost acknowledgements leave the original fence retained.
            await read(reply, 4096, terminalSignal);
          } catch { /* No terminal proof is inferred from failed cleanup. */ }
        }
      }
    } catch (error) {
      return error instanceof Failure
        ? json(
          { code: error.code },
          error.status,
          error.retryAfter ? { "Retry-After": String(error.retryAfter) } : {},
        )
        : json({ code: "retry" }, 503);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  };
}

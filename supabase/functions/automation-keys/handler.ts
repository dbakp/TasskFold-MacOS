type Config = { url: string; serviceKey: string };
type Dependencies = { send?: (request: Request) => Promise<Response> };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
async function read(body: ReadableStream<Uint8Array> | null, maximum: number) {
  if (!body) return null;
  const reader = body.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      size += item.value.length;
      if (size > maximum) throw new Error("Body limit");
      chunks.push(item.value);
    }
  } catch (error) {
    await reader.cancel();
    throw error;
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return size
    ? JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes))
    : null;
}
const scopes = [
  "tasks:read",
  "tasks:create",
  "tasks:update",
  "tasks:complete",
  "tasks:delete",
];
function metadata(value: unknown) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Invalid receipt");
  }
  const row = value as Record<string, unknown>;
  if (
    typeof row.id !== "string" || !uuid.test(row.id) ||
    typeof row.name !== "string" ||
    row.name.length < 1 || row.name.length > 320 ||
    row.prefix !== "tfk_v1_" + row.id.replaceAll("-", "").slice(0, 8) ||
    !Array.isArray(row.scopes) || row.scopes.length < 1 ||
    row.scopes.length > 5 || new Set(row.scopes).size !== row.scopes.length ||
    row.scopes.some((x) => !scopes.includes(x))
  ) throw new Error("Invalid receipt");
  for (
    const field of ["created_at", "expires_at", "revoked_at", "last_used_at"]
  ) {
    const date = row[field];
    if (date === null && ["revoked_at", "last_used_at"].includes(field)) {
      continue;
    }
    if (
      typeof date !== "string" || date.length > 40 ||
      !/^\d{4}-\d{2}-\d{2}T/.test(date) || !Number.isFinite(Date.parse(date))
    ) throw new Error("Invalid date");
  }
  // Never forward a future/accidental hash, secret, internal counter or SQL field.
  return Object.fromEntries(
    [
      "id",
      "name",
      "prefix",
      "scopes",
      "created_at",
      "expires_at",
      "revoked_at",
      "last_used_at",
    ].map((key) => [key, row[key]]),
  );
}
export function createHandler(config: Config, dependencies: Dependencies = {}) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") {
      return json({ error: "Use POST to manage automation keys." }, 405);
    }
    const token = /^Bearer ([^\s]{1,8192})$/i.exec(
      request.headers.get("Authorization") ?? "",
    )?.[1];
    if (!token) {
      return json({ error: "Sign in to manage automation keys." }, 401);
    }
    if (request.headers.get("X-Taskfold-Automation") !== "1") {
      return json({ error: "Update Taskfold to manage automation keys." }, 428);
    }
    let origin: string;
    try {
      const url = new URL(config.url);
      if (url.protocol !== "https:" || !config.serviceKey) throw new Error();
      origin = url.origin;
    } catch {
      return json(
        { error: "Automation access is temporarily unavailable." },
        503,
      );
    }
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), 15000);
    try {
      let input: { action?: unknown; body?: unknown };
      const reader = request.body?.getReader();
      let timeout = false;
      const timer = setTimeout(() => {
        timeout = true;
        void reader?.cancel().catch(() => {});
      }, 2000);
      try {
        // A bounded, timed reader also covers chunked callers without Content-Length.
        const stream = reader
          ? new ReadableStream<Uint8Array>({
            async pull(destination) {
              const part = await reader.read();
              if (part.done) destination.close();
              else destination.enqueue(part.value);
            },
            cancel() {
              return reader.cancel();
            },
          })
          : null;
        input = await read(stream, 8192) as typeof input;
      } catch {
        return json({ error: "Use a bounded automation-key request." }, 400);
      } finally {
        clearTimeout(timer);
      }
      if (timeout) {
        return json({ error: "The request took too long. Try again." }, 408);
      }
      if (
        !input || typeof input !== "object" || Array.isArray(input) ||
        Object.keys(input).sort().join(",") !== "action,body" ||
        !["list", "create", "revoke", "cancel"].includes(
          input.action as string,
        ) ||
        !input.body || typeof input.body !== "object" ||
        Array.isArray(input.body)
      ) {
        return json({ error: "Use a supported automation-key action." }, 400);
      }
      if (input.action === "cancel") {
        const body = input.body as Record<string, unknown>;
        if (
          Object.keys(body).join(",") !== "id" || typeof body.id !== "string" ||
          !uuid.test(body.id) ||
          body.id === "00000000-0000-0000-0000-000000000000"
        ) {
          return json({ error: "Review the key settings and try again." }, 400);
        }
      }
      const api = async (path: string, bearer: string, value?: unknown) => {
        const result = await send(
          new Request(origin + path, {
            method: value === undefined ? "GET" : "POST",
            redirect: "error",
            signal: controller.signal,
            headers: {
              apikey: config.serviceKey,
              Authorization: "Bearer " + bearer,
              "Content-Type": "application/json",
            },
            body: value === undefined ? undefined : JSON.stringify(value),
          }),
        );
        return {
          status: result.status,
          value: await read(result.body, 256000),
        };
      };
      const user = await api("/auth/v1/user", token);
      if (user.status === 401 || user.status === 403) {
        return json({ error: "Sign in again to manage automation keys." }, 401);
      }
      if (user.status !== 200 || !user.value || !uuid.test(user.value.id)) {
        throw new Error("Auth unavailable");
      }
      let claims: { sub?: unknown; session_id?: unknown };
      try {
        const payload = token.split(".")[1].replaceAll("-", "+").replaceAll(
          "_",
          "/",
        );
        claims = JSON.parse(
          atob(payload + "=".repeat((4 - payload.length % 4) % 4)),
        );
      } catch {
        return json({ error: "Sign in again to manage automation keys." }, 401);
      }
      if (
        claims?.sub !== user.value.id ||
        typeof claims?.session_id !== "string" || !uuid.test(claims.session_id)
      ) {
        return json({ error: "Sign in again to manage automation keys." }, 401);
      }
      const result = await api(
        input.action === "cancel"
          ? "/rest/v1/rpc/taskfold_automation_cancel_key"
          : "/rest/v1/rpc/taskfold_automation_keys",
        config.serviceKey,
        input.action === "cancel"
          ? {
            _account: user.value.id,
            _session: claims.session_id,
            _id: (input.body as { id: string }).id,
          }
          : {
            _account: user.value.id,
            _session: claims.session_id,
            _action: input.action,
            _body: input.body,
          },
      );
      if (result.status < 200 || result.status >= 300) {
        const code = result.value?.code;
        const status = ({
          "28000": 401,
          "42501": 403,
          "22023": 400,
          "23505": 409,
          "PT409": 409,
          "PT429": 429,
        } as Record<string, number>)[code] ?? 503;
        const messages: Record<number, string> = {
          401: "Sign in again to manage automation keys.",
          403: "That key is unavailable in this account.",
          400: "Review the key settings and try again.",
          409:
            "This key setup was discarded or already has different settings. Create a new key.",
          429:
            "The automation-key limit was reached. Revoke an unused key, or try again later.",
          503: "Automation access is temporarily unavailable. Try again.",
        };
        return json({
          error: status === 429 && input.action === "cancel"
            ? "Too many new setup cancellations today. Retry this discard later; existing keys can still be revoked."
            : messages[status],
        }, status);
      }
      if (!result.value || result.value.account !== user.value.id) {
        throw new Error("Owner mismatch");
      }
      if (input.action === "cancel") {
        if (
          result.value.id !== (input.body as { id: string }).id ||
          result.value.cancelled !== true
        ) throw new Error("Cancellation unconfirmed");
        return json({
          account: user.value.id,
          id: result.value.id,
          cancelled: true,
        });
      }
      if (input.action === "list") {
        if (
          !Array.isArray(result.value.keys) || result.value.keys.length > 100
        ) throw new Error("Invalid page");
        const keys = result.value.keys.map(metadata),
          ids = keys.map((key: Record<string, unknown>) => key.id);
        const cursor = result.value.next_cursor;
        if (
          new Set(ids).size !== ids.length ||
          !(cursor === null ||
            typeof cursor === "string" && uuid.test(cursor) &&
              cursor === ids.at(-1))
        ) throw new Error("Invalid cursor");
        return json({ account: user.value.id, keys, next_cursor: cursor });
      }
      const key = metadata(result.value.key);
      if (key.id !== (input.body as { id?: unknown }).id) {
        throw new Error("Request changed");
      }
      return json({ account: user.value.id, key });
    } catch {
      return json({
        error: "Automation access is temporarily unavailable. Try again.",
      }, 503);
    } finally {
      clearTimeout(deadline);
    }
  };
}

import {
  type Admission,
  createAdmission,
} from "../_shared/automation-admission.ts";

type Config = {
  url: string;
  serviceKey: string;
  forwardedForMode?: string;
  inboundDomain?: string;
};
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  admit?: Admission;
};
const uuid = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const nil = "00000000-0000-0000-0000-000000000000";
const identity = (value: unknown): value is string =>
  typeof value === "string" && uuid.test(value) && value !== nil;
const object = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error();
  }
  return value as Record<string, unknown>;
};
const exact = (row: Record<string, unknown>, keys: string[]) =>
  Object.keys(row).sort().join(",") === keys.sort().join(",");
const date = (value: unknown): value is string =>
  typeof value === "string" && value.length <= 40 &&
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$/.test(
    value,
  ) &&
  Number.isFinite(Date.parse(value));
const name = (value: unknown): value is string =>
  typeof value === "string" && !!value.trim() &&
  Array.from(value.trim()).length <= 80 &&
  new TextEncoder().encode(value).length <= 320 && !/\p{Cc}/u.test(value);
export function emailInboundDomain(value: string | undefined): string | null {
  // Configuration is a bare, canonical public DNS name, never a URL or mailbox.
  if (!value || value.length > 253 || value !== value.toLowerCase()) {
    return null;
  }
  const labels = value.split(".");
  if (labels.length < 2 || !/^[a-z]{2,63}$/.test(labels.at(-1)!)) return null;
  return labels.every((p) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(p))
    ? value
    : null;
}
function setup(value: unknown) {
  const row = object(value);
  if (
    !exact(row, ["id", "name", "alias_hash", "project_id", "requested_at"]) ||
    !identity(row.id) || !name(row.name) ||
    typeof row.alias_hash !== "string" ||
    !/^[a-f0-9]{64}$/.test(row.alias_hash) ||
    !(row.project_id === null || identity(row.project_id)) ||
    !date(row.requested_at)
  ) throw Error();
  return row;
}
function command(action: unknown, value: unknown) {
  const row = object(value);
  if (action === "list") {
    if (!exact(row, [])) throw Error();
  } else if (action === "create") setup(row);
  else if (["pause", "resume", "revoke", "rotate"].includes(action as string)) {
    if (
      !exact(
        row,
        action === "rotate"
          ? ["id", "revision", "replacement"]
          : ["id", "revision"],
      ) ||
      !identity(row.id) || !Number.isInteger(row.revision) ||
      Number(row.revision) < (action === "revoke" ? 0 : 1) ||
      Number(row.revision) > 2147483646
    ) throw Error();
    if (action === "rotate" && setup(row.replacement).id === row.id) {
      throw Error();
    }
  } else throw Error();
  return row;
}
function receipt(value: unknown) {
  const row = object(value);
  if (
    !identity(row.id) || !name(row.name) ||
    row.name !== (row.name as string).trim() ||
    !(row.project_id === null || identity(row.project_id)) ||
    typeof row.sender_email !== "string" || row.sender_email.length > 254 ||
    !/^[^\s@]+@[^\s@]+$/.test(row.sender_email) ||
    !["active", "paused", "revoked"].includes(row.state as string) ||
    !Number.isInteger(row.revision) || Number(row.revision) < 1 ||
    Number(row.revision) > 2147483647 ||
    !(row.rotated_to === null || identity(row.rotated_to)) ||
    !["created_at", "updated_at", "accept_after"].every((key) => date(row[key]))
  ) throw Error();
  // Deliberate projection: never return hashes, raw aliases or future SQL fields.
  return Object.fromEntries(
    [
      "id",
      "name",
      "project_id",
      "sender_email",
      "state",
      "revision",
      "rotated_to",
      "created_at",
      "updated_at",
      "accept_after",
    ].map((key) => [key, row[key]]),
  );
}
const json = (value: unknown, status = 200, retry = false) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...(retry ? { "Retry-After": "1" } : {}),
    },
  });
// Race both fetch and reads against the deadline even if an injected/upstream
// transport neglects AbortSignal. Cancel its eventual response body as well.
function bounded<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = () => reject(Error("Deadline"));
    work.then(resolve, reject).finally(() =>
      signal.removeEventListener("abort", abort)
    );
    if (signal.aborted) abort();
    else signal.addEventListener("abort", abort, { once: true });
  });
}
async function read(
  stream: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
) {
  if (!stream) throw Error();
  const reader = stream.getReader(), parts: Uint8Array[] = [];
  let size = 0;
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    if (signal.aborted) throw Error();
    while (true) {
      const part = await bounded(reader.read(), signal);
      if (signal.aborted) throw Error();
      if (part.done) break;
      if ((size += part.value.length) > maximum) throw Error();
      parts.push(part.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch (error) {
    cancel();
    throw error;
  } finally {
    signal.removeEventListener("abort", cancel);
    try {
      reader.releaseLock();
    } catch { /* Cancelled read unwinding. */ }
  }
}
const uncertain =
  "Could not confirm the result. Retry the same action with the same address setup and revision.";
export function createEmailRoutesHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  // Share the durable native-management budget with keys/webhooks; this is not
  // the provider ingress budget and cannot be used for untrusted inbound mail.
  const admit = dependencies.admit ?? createAdmission(config, "keys", send);
  const domain = emailInboundDomain(config.inboundDomain);
  return async (request: Request): Promise<Response> => {
    const started = performance.now();
    const blocked = await admit(request);
    if (blocked) return blocked;
    const refuse = (error: string, status: number) => {
      void request.body?.cancel().catch(() => {});
      return json({ error }, status);
    };
    if (request.method !== "POST") {
      return refuse("Use POST to manage email addresses.", 405);
    }
    const token = /^Bearer ([^\s]{1,8192})$/i.exec(
      request.headers.get("Authorization") ?? "",
    )?.[1];
    if (!token) return refuse("Sign in to manage email addresses.", 401);
    if (request.headers.get("X-Taskfold-Email") !== "1") {
      return refuse("Update Taskfold to manage email addresses.", 428);
    }
    let origin: string;
    try {
      const url = new URL(config.url);
      if (
        url.protocol !== "https:" || url.username || url.password ||
        url.search || url.hash ||
        url.pathname !== "/" || !config.serviceKey
      ) throw Error();
      origin = url.origin;
    } catch {
      return refuse("Email capture is temporarily unavailable.", 503);
    }
    const deadline = AbortSignal.any([
      request.signal,
      AbortSignal.timeout(Math.max(1, 15000 - (performance.now() - started))),
    ]);
    let action: unknown;
    try {
      let body: Record<string, unknown>;
      const inputDeadline = AbortSignal.any([
        deadline,
        AbortSignal.timeout(2000),
      ]);
      try {
        const input = object(await read(request.body, 8192, inputDeadline));
        if (!exact(input, ["action", "body"])) throw Error();
        action = input.action;
        body = command(action, input.body);
      } catch {
        return json({
          error: inputDeadline.aborted
            ? "The request took too long. Try again."
            : "Review the email address settings and try again.",
        }, inputDeadline.aborted ? 408 : 400);
      }
      const api = async (path: string, bearer: string, payload?: unknown) => {
        if (deadline.aborted) throw Error("Deadline");
        const upstream = send(
          new Request(origin + path, {
            method: payload === undefined ? "GET" : "POST",
            redirect: "error",
            signal: deadline,
            headers: {
              apikey: config.serviceKey,
              Authorization: "Bearer " + bearer,
              "Content-Type": "application/json",
            },
            body: payload === undefined ? undefined : JSON.stringify(payload),
          }),
        ).then((response) => {
          if (deadline.aborted) {
            void response.body?.cancel().catch(() => {});
            throw Error();
          }
          return response;
        });
        const result = await bounded(upstream, deadline);
        return {
          status: result.status,
          value: object(await read(result.body, 512000, deadline)),
        };
      };
      // Live Auth verifies the bearer; only then extract its subject/session.
      const user = await api("/auth/v1/user", token);
      if ([401, 403].includes(user.status)) {
        return json({ error: "Sign in again to manage email addresses." }, 401);
      }
      if (user.status !== 200 || !identity(user.value.id)) throw Error();
      let claims: Record<string, unknown>;
      try {
        const parts = token.split(".");
        if (parts.length !== 3) throw Error();
        const payload = parts[1].replaceAll("-", "+").replaceAll("_", "/");
        claims = object(
          JSON.parse(atob(payload + "=".repeat((4 - payload.length % 4) % 4))),
        );
        if (
          claims.sub !== user.value.id || !identity(claims.session_id) ||
          user.value.is_anonymous === true
        ) throw Error();
      } catch {
        return json({ error: "Sign in again to manage email addresses." }, 401);
      }
      if (
        !domain && ["create", "resume", "rotate"].includes(action as string)
      ) {
        return json({
          error:
            "Email capture is not configured yet. Existing addresses can still be paused or revoked.",
        }, 503);
      }
      if (
        ["create", "resume", "rotate"].includes(action as string) &&
        request.headers.get("X-Taskfold-Email-Domain") !== domain
      ) {
        return json({
          error:
            "The email domain changed. Refresh and review the address before continuing.",
        }, 409);
      }
      const result = await api(
        "/rest/v1/rpc/taskfold_email_routes",
        config.serviceKey,
        {
          _account: user.value.id,
          _session: claims.session_id,
          _action: action,
          _body: body,
        },
      );
      if (result.status < 200 || result.status >= 300) {
        const code = typeof result.value.code === "string"
          ? result.value.code
          : "";
        const status = ({
          "28000": 401,
          "42501": 403,
          "PT404": 404,
          "22023": 400,
          "23505": 409,
          "PT409": 409,
          "PT429": 429,
          "PT503": 503,
        } as Record<string, number>)[code] ?? 503;
        const messages: Record<number, string> = {
          400: "Review the email address settings and try again.",
          401: "Sign in again to manage email addresses.",
          403:
            "Verify your sending email and current project access before continuing.",
          404: "That email address is unavailable in this account.",
          409:
            "This address setup changed or was discarded. Refresh its status before continuing.",
          429:
            "The email address limit was reached. Retry later; existing addresses can still be paused or revoked.",
          503: action === "list"
            ? "Email capture is temporarily unavailable. Try again."
            : uncertain,
        };
        return json(
          { error: messages[status] },
          status,
          ["40P01", "40001", "55P03", "57014"].includes(code),
        );
      }
      if (result.value.account !== user.value.id) throw Error();
      if (action === "list") {
        if (
          typeof result.value.available !== "boolean" ||
          !Array.isArray(result.value.routes) ||
          result.value.routes.length > 512
        ) throw Error();
        const routes = result.value.routes.map(receipt);
        if (new Set(routes.map((r) => r.id)).size !== routes.length) {
          throw Error();
        }
        const available = result.value.available && domain !== null;
        return json({
          account: user.value.id,
          available,
          domain: available ? domain : null,
          routes,
        });
      }
      if (action === "revoke" && result.value.cancelled === true) {
        if (body.revision !== 0 || result.value.id !== body.id) throw Error();
        return json({ account: user.value.id, id: body.id, cancelled: true });
      }
      const route = receipt(result.value.route);
      const expected = action === "rotate" ? setup(body.replacement) : body;
      if (
        route.id !== expected.id ||
        (action === "pause" && route.state !== "paused") ||
        (action === "resume" && route.state !== "active") ||
        (action === "revoke" && route.state !== "revoked")
      ) throw Error();
      if (
        ["create", "rotate"].includes(action as string) &&
        (route.name !== (expected.name as string).trim() ||
          route.project_id !== expected.project_id)
      ) throw Error();
      if (action === "rotate") {
        const replaced = receipt(result.value.replaced);
        if (
          replaced.id !== body.id || replaced.state !== "revoked" ||
          replaced.rotated_to !== route.id
        ) throw Error();
        return json({ account: user.value.id, route, replaced });
      }
      return json({ account: user.value.id, route });
    } catch {
      return json({
        error: action === "list"
          ? "Email capture is temporarily unavailable. Try again."
          : uncertain,
      }, 503);
    }
  };
}

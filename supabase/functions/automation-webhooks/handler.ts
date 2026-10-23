import {
  type Admission,
  createAdmission,
} from "../_shared/automation-admission.ts";
import { abortable } from "./socket.ts";
import { createWebhookTransport, webhookTarget } from "./transport.ts";
import {
  openWebhookSecret,
  sealWebhookSecret,
  type WebhookSecretEnvelope,
} from "./secret.ts";
import { verifyWebhookChallenge } from "./challenge.ts";
type Config = {
  url: string;
  serviceKey: string;
  forwardedForMode?: string;
  currentMasterVersion: string;
  masterKeys: Record<string, Uint8Array>;
};
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  admit?: Admission;
  deliver?: ReturnType<typeof createWebhookTransport>;
};
const uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const nil = "00000000-0000-0000-0000-000000000000";
const events = [
  "task.created",
  "task.updated",
  "task.completed",
  "task.reopened",
  "task.deleted",
];
const json = (
  body: unknown,
  status = 200,
  extra: Record<string, string> = {},
) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Expose-Headers": "Retry-After",
      ...extra,
    },
  });
class Refusal extends Error {
  constructor(readonly status: number, readonly retry = false) {
    super("Webhook request refused");
  }
}
async function read(
  stream: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
) {
  if (!stream) throw Error("Missing body");
  const reader = stream.getReader(), parts: Uint8Array[] = [];
  let size = 0;
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw Error("Deadline");
    while (true) {
      const part = await abortable(reader.read(), signal);
      if (signal.aborted) throw Error("Deadline");
      if (part.done) break;
      if ((size += part.value.length) > maximum) throw Error("Input bound");
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
    abort();
    throw error;
  } finally {
    signal.removeEventListener("abort", abort);
    try {
      reader.releaseLock();
    } catch { /* Cancelled read still unwinding. */ }
  }
}
function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error("Invalid response");
  }
  return value as Record<string, unknown>;
}
function receipt(value: unknown) {
  const row = record(value);
  // Metadata/history must remain revocable if an old destination is no longer
  // publicly routable. Public-address authorization belongs at network sends.
  const origin = typeof row.origin === "string" ? new URL(row.origin) : null;
  if (
    typeof row.id !== "string" || !uuid.test(row.id) || row.id === nil ||
    typeof row.revision !== "string" || !uuid.test(row.revision) ||
    row.revision === nil ||
    typeof row.name !== "string" || !row.name.trim() ||
    Array.from(row.name).length > 80 || typeof row.origin !== "string" ||
    !origin || origin.protocol !== "https:" || origin.origin !== row.origin ||
    origin.pathname !== "/" || origin.search || origin.hash ||
    origin.username || origin.password ||
    !["all", "inbox", "project"].includes(row.scope as string) ||
    !Array.isArray(row.events) || row.events.length < 1 ||
    row.events.length > 5 || row.events.some((e) => !events.includes(e)) ||
    new Set(row.events).size !== row.events.length ||
    !["pending", "active", "paused", "revoked", "expired"].includes(
      row.state as string,
    )
  ) throw Error("Invalid receipt");
  if (
    row.scope === "project"
      ? typeof row.project_id !== "string" || !uuid.test(row.project_id)
      : row.project_id !== null
  ) throw Error("Invalid scope");
  for (
    const field of ["created_at", "expires_at", "verified_at", "revoked_at"]
  ) {
    const value = row[field];
    if (
      value === null && ["verified_at", "revoked_at"].includes(field)
    ) continue;
    if (
      typeof value !== "string" || value.length > 40 ||
      !/^\d{4}-\d{2}-\d{2}T/.test(value) || !Number.isFinite(Date.parse(value))
    ) throw Error("Invalid receipt date");
  }
  return Object.fromEntries(
    [
      "id",
      "revision",
      "name",
      "origin",
      "scope",
      "project_id",
      "events",
      "state",
      "created_at",
      "expires_at",
      "verified_at",
      "revoked_at",
    ].map((key) => [key, row[key]]),
  );
}
function decodedSecret(text: unknown) {
  if (typeof text !== "string" || !/^tfwh_v1_[A-Za-z0-9_-]{43}$/.test(text)) {
    throw new Refusal(400);
  }
  const suffix = text.slice(8);
  const bytes = Uint8Array.from(
    atob(suffix.replaceAll("-", "+").replaceAll("_", "/") + "="),
    (c) => c.charCodeAt(0),
  );
  const canonical = btoa(String.fromCharCode(...bytes)).replaceAll("+", "-")
    .replaceAll("/", "_").replace(/=+$/, "");
  if (bytes.length !== 32 || canonical !== suffix) throw new Refusal(400);
  return bytes;
}
function projection(
  value: Record<string, unknown>,
  action: string,
  body: Record<string, unknown>,
  account: string,
) {
  if (value.account !== account) throw Error("Wrong owner");
  if (action === "list") {
    if (
      !Array.isArray(value.subscriptions) || value.subscriptions.length > 100
    ) throw Error("Invalid page");
    const subscriptions = value.subscriptions.map(receipt),
      ids = subscriptions.map((s) => s.id);
    if (
      new Set(ids).size !== ids.length ||
      !(value.next_cursor === null ||
        typeof value.next_cursor === "string" &&
          value.next_cursor === ids.at(-1))
    ) throw Error("Invalid page cursor");
    return { account, subscriptions, next_cursor: value.next_cursor };
  }
  if (action === "cancel") {
    if (value.id !== body.id || value.cancelled !== true) {
      throw Error("Discard unconfirmed");
    }
    return { account, id: body.id, cancelled: true };
  }
  const subscription = receipt(value.subscription);
  if (subscription.id !== body.id) throw Error("Wrong setup");
  const output: Record<string, unknown> = { account, subscription };
  if (["pause", "resume"].includes(action)) {
    const command = record(value.command);
    if (command.request_id !== body.request_id || command.applied !== true) {
      throw Error("Control unconfirmed");
    }
    output.command = { request_id: body.request_id, applied: true };
  }
  if (action === "details") {
    const destination = typeof value.endpoint === "string"
      ? new URL(value.endpoint)
      : null;
    if (
      !destination || destination.protocol !== "https:" ||
      destination.username || destination.password || destination.hash ||
      destination.href !== value.endpoint ||
      destination.origin !== subscription.origin
    ) throw Error("Wrong destination");
    output.endpoint = value.endpoint;
  }
  if (action === "verify") {
    const verification = record(value.verification);
    if (
      verification.attempt_id !== body.attempt_id ||
      ![
        "pending",
        "verified",
        "retry",
        "refused",
        "gone",
        "expired",
        "cancelled",
        "unavailable",
      ].includes(verification.outcome as string)
    ) throw Error("Wrong verification");
    output.verification = {
      attempt_id: verification.attempt_id,
      outcome: verification.outcome,
    };
  }
  return output;
}
export function createWebhookHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch,
    deliver = dependencies.deliver ?? createWebhookTransport();
  // Share the independently bounded management ingress budget with key setup.
  // Verification quotas below are separate, durable per-account SQL budgets.
  const admit = dependencies.admit ?? createAdmission(config, "keys", send);
  return async (request: Request) => {
    const started = performance.now(), blocked = await admit(request);
    if (blocked) return blocked;
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers":
            "Authorization, Content-Type, X-Taskfold-Automation",
          "Cache-Control": "no-store",
        },
      });
    }
    if (request.method !== "POST") {
      return json({ error: "Use POST to manage webhooks." }, 405);
    }
    const token = /^Bearer ([^\s]{1,8192})$/i.exec(
      request.headers.get("Authorization") ?? "",
    )?.[1];
    if (!token) return json({ error: "Sign in to manage webhooks." }, 401);
    if (request.headers.get("X-Taskfold-Automation") !== "1") {
      return json({ error: "Update Taskfold to manage webhooks." }, 428);
    }
    const deadline = AbortSignal.any([
      request.signal,
      AbortSignal.timeout(Math.max(1, 25000 - (performance.now() - started))),
    ]);
    try {
      const url = new URL(config.url);
      if (
        url.protocol !== "https:" || url.username || url.password ||
        url.pathname !== "/" || url.search || url.hash || !config.serviceKey
      ) throw Error("Invalid backend");
      const inputDeadline = AbortSignal.any([
        deadline,
        AbortSignal.timeout(2000),
      ]);
      let input: Record<string, unknown>;
      try {
        input = record(await read(request.body, 8192, inputDeadline));
      } catch {
        throw new Refusal(inputDeadline.aborted ? 408 : 400);
      }
      if (
        Object.keys(input).sort().join(",") !== "action,body" ||
        ![
          "list",
          "create",
          "details",
          "pause",
          "resume",
          "revoke",
          "cancel",
          "verify",
        ].includes(input.action as string)
      ) throw new Refusal(400);
      if (
        !input.body || typeof input.body !== "object" ||
        Array.isArray(input.body)
      ) throw new Refusal(400);
      const action = input.action as string, body = record(input.body);
      if (
        action !== "list" &&
        (typeof body.id !== "string" || !uuid.test(body.id) || body.id === nil)
      ) throw new Refusal(400);
      if (action === "verify") {
        if (
          Object.keys(body).sort().join(",") !== "attempt_id,id" ||
          typeof body.attempt_id !== "string" || !uuid.test(body.attempt_id) ||
          body.attempt_id === nil
        ) throw new Refusal(400);
      } else if (["pause", "resume"].includes(action)) {
        if (
          Object.keys(body).sort().join(",") !== "id,request_id,revision" ||
          [body.request_id, body.revision].some((value) =>
            typeof value !== "string" || !uuid.test(value) || value === nil
          )
        ) throw new Refusal(400);
      } else if (
        !["list", "create"].includes(action) &&
        Object.keys(body).join(",") !== "id"
      ) throw new Refusal(400);
      const api = async (path: string, bearer: string, value?: unknown) => {
        if (deadline.aborted) throw Error("Deadline");
        const response = await abortable(
          send(
            new Request(url.origin + path, {
              method: value === undefined ? "GET" : "POST",
              redirect: "error",
              signal: deadline,
              headers: {
                apikey: config.serviceKey,
                Authorization: "Bearer " + bearer,
                "Content-Type": "application/json",
              },
              body: value === undefined ? undefined : JSON.stringify(value),
            }),
          ),
          deadline,
        );
        return {
          status: response.status,
          value: record(await read(response.body, 131072, deadline)),
        };
      };
      const user = await api("/auth/v1/user", token);
      if ([401, 403].includes(user.status)) throw new Refusal(401);
      if (
        user.status !== 200 || typeof user.value.id !== "string" ||
        !uuid.test(user.value.id)
      ) throw Error("Auth unavailable");
      const account = user.value.id;
      let claims: Record<string, unknown>;
      try {
        const text = token.split(".")[1].replaceAll("-", "+").replaceAll(
          "_",
          "/",
        );
        claims = record(
          JSON.parse(atob(text + "=".repeat((4 - text.length % 4) % 4))),
        );
      } catch {
        throw new Refusal(401);
      }
      if (
        claims.sub !== account || typeof claims.session_id !== "string" ||
        !uuid.test(claims.session_id)
      ) throw new Refusal(401);
      const rpc = async (
        operation: string,
        document: Record<string, unknown>,
      ) => {
        const result = await api(
          "/rest/v1/rpc/taskfold_webhooks",
          config.serviceKey,
          {
            _account: account,
            _session: claims.session_id,
            _action: operation,
            _body: document,
          },
        );
        if (result.status < 200 || result.status >= 300) {
          const code = typeof result.value.code === "string"
            ? result.value.code
            : "";
          throw new Refusal(
            ({
              "28000": 401,
              "42501": 403,
              "PT404": 404,
              "22023": 400,
              "PT409": 409,
              "PT429": 429,
            } as Record<string, number>)[code] ?? 503,
            ["40P01", "40001", "55P03", "57014"].includes(code),
          );
        }
        if (result.value.account !== account) throw Error("Wrong account");
        return result.value;
      };
      let value: Record<string, unknown>;
      if (action === "create") {
        if (
          Object.keys(body).sort().join(",") !==
            "endpoint,events,id,name,project_id,scope,secret,ttl_days"
        ) throw new Refusal(400);
        let endpoint: string;
        try {
          endpoint = webhookTarget(body.endpoint as string).url;
        } catch {
          throw new Refusal(400);
        }
        const keyVersion = config.currentMasterVersion,
          master = config.masterKeys[keyVersion];
        if (!master || !/^[a-z0-9-]{1,32}$/.test(keyVersion)) {
          throw Error("Master unavailable");
        }
        const secret = decodedSecret(body.secret);
        try {
          const digest = new Uint8Array(
            await crypto.subtle.digest("SHA-256", secret),
          );
          const { secret: _private, ...settings } = body;
          value = await rpc("create", {
            ...settings,
            endpoint,
            secret_hash: Array.from(
              digest,
              (b) => b.toString(16).padStart(2, "0"),
            ).join(""),
            secret_envelope: await sealWebhookSecret(
              secret,
              master,
              account,
              body.id as string,
              keyVersion,
            ),
          });
        } finally {
          secret.fill(0);
        }
      } else if (action === "verify") {
        value = await rpc("begin_verify", body);
        // Check all returned identities/metadata before selecting a receiver.
        projection(value, "verify", body, account);
        if (record(value.verification).outcome === "pending") {
          const challenge = record(value.challenge),
            envelope = record(
              value.secret_envelope,
            ) as unknown as WebhookSecretEnvelope;
          if (
            typeof challenge.nonce !== "string" ||
            !/^[a-f0-9]{64}$/.test(challenge.nonce) ||
            typeof challenge.expires_at !== "string" ||
            !Number.isFinite(Date.parse(challenge.expires_at)) ||
            Date.parse(challenge.expires_at) <= Date.now() ||
            typeof value.endpoint !== "string" ||
            new URL(webhookTarget(value.endpoint).url).origin !==
              receipt(value.subscription).origin
          ) throw Error("Invalid challenge");
          const master = config.masterKeys[envelope.keyVersion];
          if (!master) throw Error("Master unavailable");
          const secret = await openWebhookSecret(
            envelope,
            master,
            account,
            body.id as string,
          );
          try {
            const result = await abortable(
              deliver(value.endpoint, {
                subscription: body.id as string,
                event: body.attempt_id as string,
                timestamp: Math.floor(Date.now() / 1000),
                body: JSON.stringify({
                  version: 1,
                  type: "taskfold.webhook.verify",
                  subscription_id: body.id,
                  attempt_id: body.attempt_id,
                  challenge: challenge.nonce,
                }),
                secret,
              }, { signal: deadline, challenge: true }),
              deadline,
            );
            const outcome = result.outcome === "delivered"
              ? await verifyWebhookChallenge(
                  result.challengeResponse,
                  secret,
                  body.id as string,
                  body.attempt_id as string,
                  challenge.nonce,
                )
                ? "verified"
                : "refused"
              : result.outcome;
            value = await rpc("finish_verify", { ...body, outcome });
          } finally {
            secret.fill(0);
          }
        }
      } else value = await rpc(action, body);
      return json(projection(value, action, body, account));
    } catch (error) {
      const status = error instanceof Refusal ? error.status : 503;
      const messages: Record<number, string> = {
        400: "Review the webhook settings and try again.",
        401: "Sign in again to manage webhooks.",
        403: "That webhook is unavailable in this account.",
        404: "That webhook or project is unavailable.",
        408:
          "The request took too long. Retry the same setup or verification attempt.",
        409:
          "This webhook changed or its setup was discarded. Refresh it before starting a new action.",
        429:
          "The webhook setup or verification limit was reached. Unused connections can still be revoked.",
      };
      return json(
        {
          error: messages[status] ??
            "Could not confirm the result. Retry the same action with the same setup and verification identities.",
        },
        status,
        error instanceof Refusal && error.retry ? { "Retry-After": "1" } : {},
      );
    }
  };
}

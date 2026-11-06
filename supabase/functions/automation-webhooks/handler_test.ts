import { createWebhookHandler } from "./handler.ts";
import { webhookChallengeProof } from "./challenge.ts";
import {
  openWebhookSecret,
  sealWebhookSecret,
  type WebhookSecretEnvelope,
} from "./secret.ts";
import type { WebhookMessage, WebhookResult } from "./transport.ts";
const id = (n: number) =>
  "f09ecafe-0000-4000-8000-" + String(n).padStart(12, "0");
const owner = id(1),
  other = id(2),
  session = id(11),
  subscription = id(21),
  attempt = id(31),
  nonce = "f".repeat(64);
const master = new Uint8Array(32).fill(74),
  entropy = new Uint8Array(32).fill(23);
const secretText = "tfwh_v1_" +
  btoa(String.fromCharCode(...entropy)).replace(/=+$/, "");
const config = {
  url: "https://backend.example",
  serviceKey: "private-service-fixture",
  currentMasterVersion: "fixture-1",
  masterKeys: { "fixture-1": master },
};
const endpoint =
  "https://receiver.example/events?token=private-destination-fixture";
const token = (account = owner, sid = session) =>
  "header." + btoa(JSON.stringify({ sub: account, session_id: sid })) +
  ".signature";
const request = (
  action = "list",
  body: unknown = {},
  authorization = token(),
  signal?: AbortSignal,
) =>
  new Request("https://edge.example", {
    method: "POST",
    signal,
    headers: {
      Authorization: "Bearer " + authorization,
      "X-Taskfold-Automation": "1",
    },
    body: JSON.stringify({ action, body }),
  });
const settings = () => ({
  id: subscription,
  name: "Synthetic receiver",
  endpoint,
  scope: "inbox",
  project_id: null,
  events: ["task.created"],
  ttl_days: 30,
  secret: secretText,
});
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const assert = (ok: unknown, label: string) => {
  if (!ok) throw Error(label);
};
const receipt = () => ({
  id: subscription,
  revision: id(41),
  name: "Synthetic receiver",
  origin: "https://receiver.example",
  scope: "inbox",
  project_id: null,
  events: ["task.created"],
  state: "pending",
  created_at: "2026-10-23T05:00:00Z",
  expires_at: "2027-10-23T05:00:00Z",
  verified_at: null as string | null,
  revoked_at: null as string | null,
});
async function fixture(options: {
  masterMissing?: boolean;
  result?: (action: string, value: Record<string, unknown>) => unknown;
  rpcError?: (action: string) => string | undefined;
  deliver?: (message: WebhookMessage) => Promise<WebhookResult>;
} = {}) {
  let sealed = await sealWebhookSecret(
    entropy,
    master,
    owner,
    subscription,
    "fixture-1",
  );
  const state = receipt(),
    calls: { operation: string; value: Record<string, unknown> }[] = [];
  let auth = 0, deliveries = 0;
  const handler = createWebhookHandler({
    ...config,
    masterKeys: options.masterMissing ? {} : config.masterKeys,
  }, {
    admit: () => Promise.resolve(null),
    send: async (incoming) => {
      const url = new URL(incoming.url);
      assert(
        url.origin === config.url && incoming.redirect === "error",
        "Fixed backend with no redirects",
      );
      assert(
        incoming.headers.get("apikey") === config.serviceKey,
        "Private backend API header",
      );
      if (url.pathname === "/auth/v1/user") {
        auth++;
        return json({ id: owner });
      }
      assert(
        url.pathname === "/rest/v1/rpc/taskfold_webhooks",
        "Only owned RPC",
      );
      const args = await incoming.json();
      assert(
        args._account === owner && args._session === session &&
          incoming.headers.get("Authorization") ===
            "Bearer " + config.serviceKey,
        "Verified account/session bound to service RPC",
      );
      const operation = args._action, body = args._body;
      calls.push({ operation, value: body });
      const error = options.rpcError?.(operation);
      if (error) {
        return json({
          code: error,
          message: "PRIVATE SQL DIAGNOSTIC",
          secret: config.serviceKey,
        }, 400);
      }
      let result: Record<string, unknown> = {
        account: owner,
        subscription: {
          ...state,
          secret_hash: "PRIVATE HASH",
          secret_envelope: sealed,
        },
      };
      if (operation === "create") sealed = body.secret_envelope;
      if (operation === "list") {
        result = {
          account: owner,
          subscriptions: [state],
          next_cursor: null,
          secret_envelope: sealed,
        };
      }
      if (operation === "cancel") {
        result = {
          account: owner,
          id: subscription,
          cancelled: true,
          secret_envelope: sealed,
        };
      }
      if (operation === "details") result.endpoint = endpoint;
      if (operation === "begin_verify") {
        result = {
          ...result,
          endpoint,
          secret_envelope: sealed,
          challenge: {
            nonce,
            expires_at: new Date(Date.now() + 240000).toISOString(),
          },
          verification: { attempt_id: attempt, outcome: "pending" },
        };
      }
      if (operation === "finish_verify") {
        if (body.outcome === "verified") {
          state.state = "active";
          state.verified_at = new Date().toISOString();
        }
        result = {
          account: owner,
          subscription: state,
          verification: { attempt_id: attempt, outcome: body.outcome },
          secret_envelope: sealed,
        };
      }
      if (["pause", "resume"].includes(operation)) {
        result = {
          ...result,
          subscription: {
            ...state,
            state: operation === "pause" ? "paused" : "active",
          },
          command: { request_id: body.request_id, applied: true },
        };
      }
      if (operation === "revoke") {
        result.subscription = {
          ...state,
          state: "revoked",
          revoked_at: new Date().toISOString(),
        };
      }
      return json(options.result ? options.result(operation, result) : result);
    },
    deliver: async (destination, message, input) => {
      deliveries++;
      assert(
        destination === endpoint && input?.challenge && input.signal &&
          message.subscription === subscription && message.event === attempt,
        "Checked private destination and stable attempt identity",
      );
      const body = JSON.parse(message.body);
      assert(
        Object.keys(body).sort().join(",") ===
            "attempt_id,challenge,subscription_id,type,version" &&
          body.challenge === nonce && body.type === "taskfold.webhook.verify",
        "Challenge contains no task content or expected proof",
      );
      if (options.deliver) return await options.deliver(message);
      return {
        outcome: "delivered",
        status: 200,
        challengeResponse: JSON.stringify({
          challenge: nonce,
          proof: await webhookChallengeProof(
            message.secret,
            subscription,
            attempt,
            nonce,
          ),
        }),
      };
    },
  });
  return { handler, state, calls, counts: () => ({ auth, deliveries }) };
}
async function answer(response: Response) {
  const text = await response.text();
  assert(
    !text.includes(config.serviceKey) && !text.includes("ciphertext") &&
      !text.includes("secret_hash") && !text.includes("PRIVATE SQL"),
    "No private upstream fields escape",
  );
  return JSON.parse(text);
}

Deno.test("webhook HTTP enrollment encrypts receiver secret before RPC and projects metadata only", async () => {
  const f = await fixture(),
    response = await f.handler(request("create", settings()));
  assert(
    response.status === 200 &&
      response.headers.get("Cache-Control") === "no-store",
    "Private success",
  );
  const data = await answer(response), call = f.calls[0].value;
  assert(
    data.subscription.state === "pending" &&
      !JSON.stringify(data).includes("private-destination-fixture") &&
      !JSON.stringify(data).includes(secretText),
    "Pending and redacted",
  );
  assert(
    !("secret" in call) && !JSON.stringify(call).includes(secretText),
    "Raw native secret never reaches SQL",
  );
  assert(
    (await openWebhookSecret(
      call.secret_envelope as WebhookSecretEnvelope,
      master,
      owner,
      subscription,
    )).every((b, i) => b === entropy[i]),
    "Actual account-bound encryption",
  );
  assert(f.counts().deliveries === 0, "Create never contacts a receiver");
});
Deno.test("webhook HTTP native callers cannot forge internal begin/finish outcomes", async () => {
  for (
    const [action, body] of [["begin_verify", {
      id: subscription,
      attempt_id: attempt,
    }], ["finish_verify", {
      id: subscription,
      attempt_id: attempt,
      outcome: "verified",
    }], ["verify", {
      id: subscription,
      attempt_id: attempt,
      outcome: "verified",
    }], ["list", []]]
  ) {
    const f = await fixture();
    assert(
      (await f.handler(request(action as string, body))).status === 400 &&
        f.calls.length === 0,
      "No client-supplied trusted outcome",
    );
  }
});
Deno.test("webhook HTTP verification requires a valid secret-possession proof and binds the verified session", async () => {
  const f = await fixture(),
    response = await f.handler(
      request("verify", { id: subscription, attempt_id: attempt }),
    );
  const data = await answer(response);
  assert(
    response.status === 200 && data.subscription.state === "active" &&
      data.verification.outcome === "verified",
    "Receiver proof activated",
  );
  assert(
    f.calls.map((c) => c.operation).join(",") ===
        "begin_verify,finish_verify" && f.calls[1].value.outcome === "verified",
    "Only server validated outcome",
  );
});
Deno.test("webhook HTTP public echoes, wrong nonce/key/attempt and malformed proof never connect", async () => {
  for (
    const kind of [
      "echo",
      "wrong-key",
      "wrong-nonce",
      "wrong-attempt",
      "extra-field",
      "garbage",
    ]
  ) {
    const f = await fixture({
      deliver: async (message) => {
        const proof = await webhookChallengeProof(
          kind === "wrong-key" ? new Uint8Array(32) : message.secret,
          subscription,
          kind === "wrong-attempt" ? id(32) : attempt,
          kind === "wrong-nonce" ? "e".repeat(64) : nonce,
        );
        return {
          outcome: "delivered",
          challengeResponse: kind === "echo"
            ? JSON.stringify({ challenge: nonce })
            : kind === "garbage"
            ? "invalid"
            : JSON.stringify({
              challenge: nonce,
              proof,
              ...(kind === "extra-field" ? { task: "unreviewed" } : {}),
            }),
        };
      },
    });
    const response = await f.handler(
        request("verify", { id: subscription, attempt_id: attempt }),
      ),
      data = await answer(response);
    assert(
      response.status === 200 && data.subscription.state === "pending" &&
        data.verification.outcome === "refused",
      kind + " must remain pending",
    );
  }
});
Deno.test("webhook HTTP temporary/refused/gone receiver outcomes cannot be mistaken for verified", async () => {
  for (const outcome of ["retry", "refused", "gone"] as const) {
    const f = await fixture({ deliver: () => Promise.resolve({ outcome }) });
    const data = await answer(
      await f.handler(
        request("verify", { id: subscription, attempt_id: attempt }),
      ),
    );
    assert(
      data.verification.outcome === outcome &&
        data.subscription.state === "pending",
      "Actual non-success outcome",
    );
  }
});
Deno.test("webhook HTTP missing masters fail create/verify closed while list/revoke/discard stay available", async () => {
  for (
    const [action, body, status] of [
      ["create", settings(), 503],
      ["verify", { id: subscription, attempt_id: attempt }, 503],
      ["list", {}, 200],
      ["revoke", { id: subscription }, 200],
      ["cancel", { id: subscription }, 200],
    ] as const
  ) {
    const f = await fixture({ masterMissing: true });
    assert(
      (await f.handler(request(action, body))).status === status &&
        f.counts().deliveries === 0,
      "No missing-master activation; cleanup survives",
    );
  }
});
Deno.test("webhook HTTP wrong identities, destination substitution and expired challenge never reach a receiver", async () => {
  for (
    const change of [
      (value: Record<string, unknown>) => ({ ...value, account: other }),
      (value: Record<string, unknown>) => ({
        ...value,
        subscription: { ...receipt(), id: id(22) },
      }),
      (value: Record<string, unknown>) => ({
        ...value,
        endpoint: "https://attacker.example/",
      }),
      (value: Record<string, unknown>) => ({
        ...value,
        challenge: {
          nonce,
          expires_at: new Date(Date.now() - 1000).toISOString(),
        },
      }),
    ]
  ) {
    const f = await fixture({ result: (_action, value) => change(value) });
    assert(
      (await f.handler(
            request("verify", { id: subscription, attempt_id: attempt }),
          )).status === 503 && f.counts().deliveries === 0,
      "Invalid owned setup refused before payload",
    );
  }
});
Deno.test("webhook HTTP terminal verification retry returns metadata without another network call", async () => {
  const f = await fixture({
    result: (action, value) =>
      action === "begin_verify"
        ? {
          ...value,
          verification: { attempt_id: attempt, outcome: "cancelled" },
        }
        : value,
  });
  const data = await answer(
    await f.handler(
      request("verify", { id: subscription, attempt_id: attempt }),
    ),
  );
  assert(
    data.verification.outcome === "cancelled" && f.counts().deliveries === 0 &&
      f.calls.length === 1,
    "No terminal replay network call",
  );
});
Deno.test("webhook HTTP signout or membership loss during proof prevents trusted activation acknowledgement", async () => {
  for (const [code, status] of [["28000", 401], ["PT404", 404]] as const) {
    const f = await fixture({
      rpcError: (action) => action === "finish_verify" ? code : undefined,
    });
    const response = await f.handler(
      request("verify", { id: subscription, attempt_id: attempt }),
    );
    await answer(response);
    assert(
      response.status === status && f.state.state === "pending",
      "Final SQL rechecks authority",
    );
  }
});
Deno.test("webhook HTTP cancelled request never submits a late verified result", async () => {
  const controller = new AbortController();
  const f = await fixture({
    deliver: async (message) => {
      const proof = await webhookChallengeProof(
        message.secret,
        subscription,
        attempt,
        nonce,
      );
      controller.abort();
      return {
        outcome: "delivered",
        challengeResponse: JSON.stringify({ challenge: nonce, proof }),
      };
    },
  });
  assert(
    (await f.handler(
          request(
            "verify",
            { id: subscription, attempt_id: attempt },
            token(),
            controller.signal,
          ),
        )).status === 503 &&
      !f.calls.some((c) => c.operation === "finish_verify"),
    "No finish after abort",
  );
});
Deno.test("webhook HTTP SQL failures expose only safe status and bounded retry guidance", async () => {
  for (
    const [code, status] of [
      ["28000", 401],
      ["PT404", 404],
      ["PT409", 409],
      ["PT429", 429],
      ["57014", 503],
      ["55P03", 503],
      ["unknown", 503],
    ] as const
  ) {
    const f = await fixture({ rpcError: () => code }),
      response = await f.handler(request());
    await answer(response);
    assert(
      response.status === status &&
        response.headers.get("Retry-After") ===
          (["57014", "55P03"].includes(code) ? "1" : null),
      "Mapped safe error",
    );
  }
});
Deno.test("webhook HTTP authentication, session mismatch and oversized input cannot reach management", async () => {
  for (
    const incoming of [
      request("list", {}, token(other)),
      request("list", {}, token(owner, "not-a-session")),
      request("create", { ...settings(), name: "x".repeat(9000) }),
    ]
  ) {
    const f = await fixture(), response = await f.handler(incoming);
    assert(
      [400, 401].includes(response.status) && f.calls.length === 0,
      "No unverified/big input RPC",
    );
  }
});
Deno.test("webhook HTTP metadata list stays redacted and details requires explicit owned action", async () => {
  const f = await fixture();
  const list = await answer(await f.handler(request()));
  assert(
    list.subscriptions.length === 1 &&
      !JSON.stringify(list).includes("private-destination-fixture"),
    "Redacted list",
  );
  assert(
    (await answer(await f.handler(request("details", { id: subscription }))))
      .endpoint === endpoint,
    "Explicit destination review only",
  );
});

Deno.test("webhook HTTP retired private-address metadata stays revocable without a network request", async () => {
  const f = await fixture({
    result: (action, value) =>
      action === "revoke"
        ? {
          ...value,
          subscription: {
            ...receipt(),
            origin: "https://127.0.0.1",
            state: "revoked",
            revoked_at: new Date().toISOString(),
          },
        }
        : value,
  });
  const response = await f.handler(request("revoke", { id: subscription }));
  assert(
    response.status === 200 &&
      (await answer(response)).subscription.state === "revoked" &&
      f.counts().deliveries === 0,
    "History validation never contacts or re-enables an old address",
  );
});

Deno.test("webhook HTTP state controls require a baseline and preserve the command identity", async () => {
  for (const action of ["pause", "resume"]) {
    const f = await fixture();
    assert(
      (await f.handler(request(action, { id: subscription }))).status === 400 &&
        f.calls.length === 0,
      "No unguarded state control",
    );
    const body = { id: subscription, request_id: id(51), revision: id(41) };
    const response = await f.handler(request(action, body));
    const result = await answer(response);
    assert(
      response.status === 200 &&
        result.command.request_id === body.request_id &&
        JSON.stringify(f.calls[0].value) === JSON.stringify(body),
      "Same intent and baseline forwarded and confirmed",
    );
  }
});

const deliveryFixture = () => ({
  version: 1,
  pending: 1,
  retained_bytes: 120,
  missed: 2,
  capture_issue: "event_quota",
  missed_since: "2026-10-23T05:00:00Z",
  missed_until: "2026-10-23T05:01:00Z",
  blocked_reason: null,
  last_error: null,
  last_success: null,
  last_failure: null,
  delivered: 3,
  failed: 0,
  payload: "PRIVATE PAYLOAD",
});
const eventFixture = () => ({
  id: id(81),
  task_id: id(82),
  task_generation: id(83),
  type: "task.updated",
  status: "failed",
  created_at: "2026-10-23T05:00:00Z",
  expires_at: "2026-10-24T05:00:00Z",
  next_attempt_at: "2026-10-23T05:01:00Z",
  finished_at: "2026-10-23T05:02:00Z",
  parts: 1,
  parts_delivered: 0,
  attempts: 12,
  manual_retries: 0,
  error: "temporary",
  http_status: 503,
  payload: "PRIVATE PAYLOAD",
  endpoint,
});
Deno.test("webhook HTTP delivery history and quota warnings project metadata only", async () => {
  const f = await fixture({
    result: (_action, value) => ({
      ...value,
      subscription: { ...receipt(), delivery: deliveryFixture() },
      events: [eventFixture()],
      next_cursor: id(81),
      payload: "PRIVATE PAYLOAD",
    }),
  });
  const response = await f.handler(
    request("history", { id: subscription, limit: 1 }),
  );
  const result = await answer(response), text = JSON.stringify(result);
  assert(
    response.status === 200 && result.events.length === 1 &&
      result.next_cursor === id(81) &&
      result.subscription.delivery.missed === 2,
    "Bounded history and capture warning reach native API",
  );
  assert(
    !text.includes("PRIVATE") && !text.includes("private-destination"),
    "No task payload, secret or destination from metadata projection",
  );
  assert(f.counts().deliveries === 0, "History makes no receiver request");
});
Deno.test("webhook HTTP manual delivery retry requires and confirms the same intent", async () => {
  const body = { id: subscription, event_id: id(81), request_id: id(84) };
  const f = await fixture({
    result: (_action, value) => ({
      ...value,
      event: eventFixture(),
      retry: {
        event_id: id(81),
        request_id: id(84),
        applied: true,
        secret: "PRIVATE",
      },
    }),
  });
  assert(
    (await f.handler(
          request("retry_delivery", { id: subscription, event_id: id(81) }),
        )).status === 400 && f.calls.length === 0,
    "No retry without durable identity",
  );
  const response = await f.handler(request("retry_delivery", body));
  const result = await answer(response);
  assert(
    response.status === 200 && result.retry.request_id === body.request_id &&
      JSON.stringify(f.calls[0].value) === JSON.stringify(body),
    "Exact retry intent forwarded",
  );
  assert(
    !JSON.stringify(result).includes("PRIVATE") && f.counts().deliveries === 0,
    "Retry only queues, never exposes retained payload",
  );
  const wrong = await fixture({
    result: (_action, value) => ({
      ...value,
      event: eventFixture(),
      retry: { event_id: id(81), request_id: id(85), applied: true },
    }),
  });
  assert(
    (await wrong.handler(request("retry_delivery", body))).status === 503,
    "Wrong receipt fails closed",
  );
});
Deno.test("webhook HTTP history rejects unbounded requests and corrupt progress", async () => {
  const f = await fixture();
  for (
    const body of [{ id: subscription, limit: 51 }, {
      id: subscription,
      cursor: "bad",
    }, { id: subscription, payload: true }]
  ) {
    assert(
      (await f.handler(request("history", body))).status === 400,
      "Invalid page refused",
    );
  }
  assert(f.calls.length === 0, "Invalid pages never reach SQL");
  const wrong = await fixture({
    result: (_action, value) => ({
      ...value,
      events: [{ ...eventFixture(), parts_delivered: 2 }],
      next_cursor: null,
    }),
  });
  assert(
    (await wrong.handler(request("history", { id: subscription }))).status ===
      503,
    "Corrupt metadata fails closed",
  );
});

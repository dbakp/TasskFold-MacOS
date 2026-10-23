import { createWebhookWorker } from "./worker.ts";
import { sealWebhookSecret } from "./secret.ts";
import { webhookMasterCatalog } from "./master-config.ts";
import type { WebhookMessage, WebhookResult } from "./transport.ts";
const id = (n: number) =>
  "f0a1cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const event = id(1),
  lease = id(2),
  owner = id(3),
  subscription = id(4),
  task = id(5),
  generation = id(6);
const master = new Uint8Array(32).fill(74),
  entropy = new Uint8Array(32).fill(23),
  workerToken = "b".repeat(64),
  service = "private-worker-service";
const source = JSON.stringify({
  version: 1,
  event_id: event,
  type: "task.created",
  occurred_at: new Date().toISOString(),
  task: {
    id: task,
    task_generation: generation,
    title: "Synthetic worker proof",
  },
});
const assert = (ok: unknown, label: string) => {
  if (!ok) throw Error(label);
};
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const request = (token = workerToken, body: unknown = {}) =>
  new Request("https://worker.example", {
    method: "POST",
    headers: { Authorization: "Bearer " + token },
    body: JSON.stringify(body),
  });
async function fixture(
  options: {
    disabled?: boolean;
    missingMaster?: boolean;
    change?: (value: Record<string, unknown>) => Record<string, unknown>;
    authorization?: boolean;
    ackFailure?: boolean;
    stale?: boolean;
    skipAuthorization?: boolean;
    deliver?: (message: WebhookMessage) => Promise<WebhookResult>;
  } = {},
) {
  const envelope = await sealWebhookSecret(
    entropy,
    master,
    owner,
    subscription,
    "fixture-1",
  );
  const calls: { action: string; body: Record<string, unknown> }[] = [],
    sent: WebhookMessage[] = [];
  let claims = 0;
  const worker = createWebhookWorker({
    url: "https://backend.example",
    serviceKey: service,
    workerToken,
    enabled: !options.disabled,
    masterKeys: options.missingMaster ? {} : { "fixture-1": master },
  }, {
    send: async (input) => {
      assert(
        input.url ===
            "https://backend.example/rest/v1/rpc/taskfold_webhook_dispatch" &&
          input.redirect === "error",
        "Fixed worker RPC",
      );
      assert(
        input.headers.get("Authorization") === "Bearer " + service &&
          input.headers.get("apikey") === service,
        "Only private backend headers",
      );
      const args = await input.json();
      calls.push({ action: args._action, body: args._body });
      if (args._action === "claim") {
        return json(
          claims++ === 0
            ? { event_id: event, lease_id: lease, maintenance: 2 }
            : { event_id: null, maintenance: 0 },
        );
      }
      assert(
        args._body.event_id === event && args._body.lease_id === lease,
        "Exact lease binding",
      );
      if (args._action === "prepare") {
        const packet = {
          ready: true,
          event_id: event,
          part_id: event,
          account: owner,
          subscription_id: subscription,
          endpoint: "https://receiver.example/events",
          body: source,
          secret_envelope: envelope,
          lease_until: new Date(Date.now() + 40000).toISOString(),
        };
        return json(options.change ? options.change(packet) : packet);
      }
      if (args._action === "authorize") {
        return json({ ready: options.authorization !== false });
      }
      assert(
        args._action === "ack",
        "Only prepared/authorized acknowledgement",
      );
      if (options.ackFailure) {
        return json({ code: "XX000", message: "PRIVATE SQL DETAIL" }, 503);
      }
      return json({ applied: !options.stale });
    },
    deliver: async (destination, message, settings) => {
      assert(
        destination === "https://receiver.example/events" &&
          settings?.beforeWrite && settings.signal,
        "Authorized checked transport",
      );
      if (!options.skipAuthorization) {
        try {
          await settings!.beforeWrite!();
        } catch {
          return { outcome: "retry" };
        }
      }
      sent.push({ ...message, secret: message.secret.slice() });
      return options.deliver
        ? await options.deliver(message)
        : { outcome: "delivered", status: 204 };
    },
  });
  return { worker, calls, sent };
}
async function output(response: Response) {
  const text = await response.text();
  assert(
    !text.includes(service) && !text.includes(workerToken) &&
      !text.includes("Synthetic worker proof") &&
      !text.includes("secret_envelope") && !text.includes("PRIVATE SQL"),
    "Worker response exposes counters only",
  );
  return JSON.parse(text);
}
Deno.test("webhook worker authenticates its separate private token and stays disabled by default", async () => {
  const off = await fixture({ disabled: true });
  assert(
    (await off.worker(request())).status === 503 && off.calls.length === 0,
    "Disabled worker has no database effect",
  );
  const f = await fixture();
  for (const token of ["a".repeat(64), "native.jwt.token", ""]) {
    assert(
      (await f.worker(request(token))).status === 401,
      "No native/unverified worker access",
    );
  }
  assert(f.calls.length === 0, "Unauthorized requests never claim");
});
Deno.test("webhook worker rejects caller-selected destinations or event bodies", async () => {
  const f = await fixture();
  assert(
    (await f.worker(
          request(workerToken, { endpoint: "https://attacker.example/" }),
        )).status === 400 && f.calls.length === 0,
    "Request cannot choose a recipient",
  );
});
Deno.test("webhook worker decrypts only the bound secret and authorizes immediately before write", async () => {
  const f = await fixture(),
    response = await f.worker(request()),
    data = await output(response);
  assert(
    response.status === 200 && data.delivered === 1 && data.maintenance === 2,
    "Confirmed delivery counters",
  );
  assert(
    f.calls.map((c) => c.action).join(",") ===
      "claim,prepare,authorize,ack,claim",
    "Fresh final authorization before ACK",
  );
  assert(
    f.sent[0].body === source && f.sent[0].event === event &&
      f.sent[0].secret.every((b, i) => b === entropy[i]),
    "Exact immutable body/part and secret",
  );
});
Deno.test("webhook worker final authorization denial sends no body or late acknowledgement", async () => {
  const f = await fixture({ authorization: false }),
    data = await output(await f.worker(request()));
  assert(
    data.skipped === 1 && f.sent.length === 0 &&
      !f.calls.some((c) => c.action === "ack"),
    "Denied packet stays under server state",
  );
});
Deno.test("webhook worker does not accept a transport success that skipped final authorization", async () => {
  const f = await fixture({ skipAuthorization: true }),
    data = await output(await f.worker(request()));
  assert(
    data.delivered === 0 &&
      f.calls.find((c) => c.action === "ack")?.body.outcome === "configuration",
    "No false successful ACK",
  );
});
Deno.test("webhook worker missing/corrupt master packets block without network content", async () => {
  for (
    const options of [{ missingMaster: true }, {
      change: (p: Record<string, unknown>) => ({ ...p, account: id(99) }),
    }, { change: (p: Record<string, unknown>) => ({ ...p, event_id: id(99) }) }]
  ) {
    const f = await fixture(options),
      data = await output(await f.worker(request()));
    assert(
      f.sent.length === 0 && data.failed === 1 &&
        f.calls.find((c) => c.action === "ack")?.body.outcome ===
          "configuration",
      "Configuration remains visible and fail closed",
    );
  }
});
Deno.test("webhook worker carries bounded receiver retry hints with the same event and lease", async () => {
  const f = await fixture({
      deliver: () =>
        Promise.resolve({
          outcome: "retry",
          status: 429,
          retryAfterSeconds: 120,
        }),
    }),
    data = await output(await f.worker(request()));
  const ack = f.calls.find((c) => c.action === "ack")!;
  assert(
    data.retrying === 1 && ack.body.retry_after === 120 &&
      ack.body.status === 429 && ack.body.event_id === event &&
      ack.body.lease_id === lease,
    "Durable retry projection",
  );
});
Deno.test("webhook worker stale or lost ACK never claims confirmed delivery", async () => {
  const stale = await fixture({ stale: true }),
    data = await output(await stale.worker(request()));
  assert(
    data.delivered === 0 && data.skipped === 1,
    "Stale lease acknowledged nowhere",
  );
  const lost = await fixture({ ackFailure: true }),
    response = await lost.worker(request());
  await output(response);
  assert(
    response.status === 503 && lost.sent.length === 1,
    "Uncertain ACK leaves server lease for recovery",
  );
});
Deno.test("webhook worker rejects a packet too close to lease expiry before opening receiver", async () => {
  const f = await fixture({
      change: (p) => ({
        ...p,
        lease_until: new Date(Date.now() + 500).toISOString(),
      }),
    }),
    data = await output(await f.worker(request()));
  assert(
    data.skipped === 1 && f.sent.length === 0 &&
      f.calls.find((c) => c.action === "ack")?.body.outcome === "retry",
    "Near-expiry lease requeues without content",
  );
});
Deno.test("webhook master catalog pins versions and rejects partial invalid catalogs", () => {
  assert(
    webhookMasterCatalog(
      JSON.stringify({ "fixture-1": "a".repeat(64) }),
    )["fixture-1"].length === 32,
    "Valid master bytes",
  );
  for (
    const value of [
      "[]",
      "invalid",
      JSON.stringify({ good: "a".repeat(64), bad: "oops" }),
      JSON.stringify({
        a: "a".repeat(64),
        b: "b".repeat(64),
        c: "c".repeat(64),
        d: "d".repeat(64),
      }),
    ]
  ) {
    assert(
      Object.keys(webhookMasterCatalog(value)).length === 0,
      "No partially enabled malformed catalog",
    );
  }
});

Deno.test("webhook worker sends multipart bytes unchanged under the part identity", async () => {
  const frame = JSON.stringify({
    version: 1,
    type: "taskfold.event.part",
    event_id: event,
    part_id: id(41),
    part_index: 0,
    part_count: 2,
    encoding: "base64",
    sha256: "a".repeat(64),
    data: "8J+TnQ==",
  });
  const f = await fixture({
    change: (p) => ({ ...p, part_id: id(41), body: frame }),
  });
  const result = await output(await f.worker(request()));
  assert(
    result.delivered === 1 && f.sent[0].event === id(41) &&
      f.sent[0].body === frame,
    "Transport signs exact part bytes and stable part identity",
  );
  const wrong = await fixture({
    change: (p) => ({ ...p, part_id: id(42), body: frame }),
  });
  const bad = await output(await wrong.worker(request()));
  assert(
    bad.failed === 1 && wrong.sent.length === 0,
    "Mismatched part never leaves worker",
  );
});

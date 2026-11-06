function assert(v: unknown): asserts v {
  if (!v) throw Error("Assertion failed");
}
namespace assert {
  export function equal(a: unknown, b: unknown) {
    if (a !== b) {
      throw Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
    }
  }
  export function deepEqual(a: unknown, b: unknown) {
    equal(JSON.stringify(a), JSON.stringify(b));
  }
}
import { createProjectFilesHandler } from "./handler.ts";
const actor = "11111111-1111-4111-8111-111111111111",
  session = "22222222-2222-4222-8222-222222222222",
  planID = "33333333-3333-4333-8333-333333333333",
  operation = "44444444-4444-4444-8444-444444444444",
  nonce = "55555555-5555-4555-8555-555555555555";
const token = "x." +
  btoa(JSON.stringify({ sub: actor, session_id: session })).replaceAll("=", "")
    .replaceAll("+", "-").replaceAll("/", "_") +
  ".x";
const bytes = new TextEncoder().encode("private source");
const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
  .map((v) => v.toString(16).padStart(2, "0")).join("");
const destination = "team-task-files/v1/" + operation + "/" + nonce;
const plan = () => ({
  protocol: 1,
  plan_id: planID,
  request_id: nonce,
  scope: {
    team_id: nonce,
    roots: [nonce],
    visibility: "private",
    folder_id: null,
    parent_id: null,
  },
  state: "ready",
  total: 1,
  prepared: 1,
  expires_at: "2026-11-06T10:00:00Z",
  items: [{
    operation_id: operation,
    label: "Design.pdf",
    byte_count: bytes.length,
    type: "application/pdf",
    state: "ready",
  }],
  next: null,
  project_transferred: false,
});
const response = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
type Faults = {
  enabled?: boolean;
  source?: string;
  reserved?: string;
  corrupt?: boolean;
  lost?: boolean;
  reserveLost?: boolean;
  missingCopy?: boolean;
  terminalLost?: boolean;
  abortReserve?: AbortController;
  plan?: (p: ReturnType<typeof plan>) => unknown;
  auth?: unknown;
  blocked?: boolean;
  throwSecret?: boolean;
  abort?: AbortController;
};
function fixture(f: Faults = {}) {
  const calls: { path: string; method: string }[] = [];
  const observations: Record<string, unknown>[] = [], producers: string[] = [];
  const handler = createProjectFilesHandler({
    url: "https://project-files.example.invalid",
    serviceKey: "private-service-key",
    enabled: f.enabled ?? true,
    timeoutMilliseconds: 100,
  }, {
    send: async (req) => {
      const path = new URL(req.url).pathname;
      calls.push({ path, method: req.method });
      assert.equal(req.redirect, "error");
      if (f.throwSecret) {
        throw Error("private-service-key original-secret-provider-path");
      }
      if (path === "/auth/v1/user") return response(f.auth ?? { id: actor });
      assert.equal(
        req.headers.get("Authorization"),
        "Bearer private-service-key",
      );
      if (path.startsWith("/rest/v1/rpc/")) {
        const b = await req.json();
        assert.equal(b._actor, actor);
        if (path.endsWith("taskfold_project_file_producer_terminal")) {
          observations.push(b._body);
          assert.equal(req.signal.aborted, false);
          if (f.terminalLost) throw Error("lost terminal acknowledgement");
          return response({ protocol: 1, settled: true });
        }
        assert.equal(b._session, session);
        if (b._action === "source") {
          return response(
            f.blocked ? { status: "source_changed" } : {
              status: "source",
              source_name: f.source ?? actor + "/design.pdf",
              byte_count: bytes.length,
              mime: "application/pdf",
            },
          );
        }
        if (b._action === "reserve_producer") {
          producers.push(b._body.producer_id);
          if (f.reserveLost) throw Error("lost reservation acknowledgement");
          f.abortReserve?.abort();
          return response({
            status: f.reserved ?? "upload",
            object_name: destination,
            sha256: digest,
            byte_count: bytes.length,
            mime: "application/pdf",
            ticket_id: nonce,
          });
        }
        if (b._action === "upload_reconcile") {
          return response({ protocol: 1, settled: true });
        }
        const p = plan();
        return response({ status: "plan", plan: f.plan ? f.plan(p) : p });
      }
      if (req.method === "POST") {
        assert.equal(req.headers.get("x-upsert"), "false");
        assert.deepEqual(new Uint8Array(await req.arrayBuffer()), bytes);
        if (f.abort) {
          f.abort.abort();
        }
        if (f.lost) throw Error("lost response");
        return response({ ok: true });
      }
      if (f.missingCopy && path.endsWith(nonce)) return response({}, 404);
      return new Response(
        f.corrupt && path.endsWith(nonce)
          ? new Uint8Array(bytes.length).fill(1)
          : bytes,
      );
    },
  });
  const call = async (
    action = "copy",
    body: unknown = { plan_id: planID, operation_id: operation },
    auth = token,
  ) => {
    const r = await handler(
      new Request("https://client.invalid/?action=" + action, {
        method: "POST",
        headers: { Authorization: "Bearer " + auth },
        body: JSON.stringify(body),
        signal: (f.abortReserve ?? f.abort)?.signal,
      }),
    );
    return { status: r.status, value: await r.json(), headers: r.headers };
  };
  return { call, calls, observations, producers };
}
Deno.test("copy verifies committed bytes and hides all grants", async () => {
  const f = fixture();
  const r = await f.call();
  assert.equal(r.status, 200);
  assert.equal(r.value.plan.project_transferred, false);
  assert.equal(JSON.stringify(r.value).includes(destination), false);
  assert.equal(r.headers.get("Cache-Control"), "private, no-store");
  assert.equal(
    f.calls.filter((c) => c.method === "POST" && c.path.startsWith("/storage/"))
      .length,
    1,
  );
});
Deno.test("lost upload reply is recovered by readback without another write", async () => {
  const f = fixture({ lost: true });
  assert.equal((await f.call()).status, 200);
  assert.equal(
    f.calls.filter((c) => c.method === "POST" && c.path.startsWith("/storage/"))
      .length,
    1,
  );
});
Deno.test("open ticket grants verification only", async () => {
  const f = fixture({ reserved: "verify" });
  assert.equal((await f.call()).status, 200);
  assert.equal(
    f.calls.some((c) => c.method === "POST" && c.path.startsWith("/storage/")),
    false,
  );
});
Deno.test("corrupt copied bytes cannot mark ready or positively reconcile", async () => {
  const f = fixture({ corrupt: true });
  assert.equal((await f.call()).status, 409);
  assert.equal(
    f.calls.filter((c) => c.path.endsWith("taskfold_task_file_command")).length,
    0,
  );
});
for (
  const source of [
    actor + "/../other.pdf",
    actor + "/%2e%2e/other.pdf",
    actor + "/\\other.pdf",
    actor + "//other.pdf",
    actor + "/./other.pdf",
    actor + "/\u0000.pdf",
    "99999999-9999-4999-8999-999999999999/private.pdf",
  ]
) {
  Deno.test(
    "refuses unsafe or foreign source " + JSON.stringify(source),
    async () => {
      const f = fixture({ source });
      assert((await f.call()).status >= 400);
      assert.equal(f.calls.some((c) => c.path.startsWith("/storage/")), false);
    },
  );
}
Deno.test("source revision refusal cannot access bytes", async () => {
  const f = fixture({ blocked: true });
  assert.equal((await f.call()).status, 409);
  assert.equal(f.calls.some((c) => c.path.startsWith("/storage/")), false);
});
Deno.test("abort cannot continue into readback or settlement", async () => {
  const abort = new AbortController(), f = fixture({ abort });
  assert.equal((await f.call()).status, 503);
  assert.equal(
    f.calls.filter((c) => c.path.includes("/authenticated/")).length,
    1,
  );
  assert.equal(
    f.calls.some((c) => c.path.endsWith("taskfold_task_file_command")),
    false,
  );
});
Deno.test("untrusted actor mismatch is refused before RPC", async () => {
  const f = fixture({ auth: { id: nonce } });
  assert.equal((await f.call()).status, 401);
  assert.equal(f.calls.length, 1);
});
Deno.test("unknown client fields cannot request a provider object", async () => {
  const f = fixture();
  assert.equal(
    (await f.call("copy", {
      plan_id: planID,
      operation_id: operation,
      object_name: destination,
    })).status,
    400,
  );
  assert.equal(f.calls.length, 1);
});
Deno.test("internal errors never leak provider paths or keys", async () => {
  const f = fixture({ throwSecret: true });
  const r = await f.call();
  assert.equal(r.status, 503);
  assert.deepEqual(r.value, { code: "retry" });
});
for (
  const mutate of [
    (p: ReturnType<typeof plan>) => ({ ...p, source_name: actor + "/secret" }),
    (p: ReturnType<typeof plan>) => ({ ...p, project_transferred: true }),
    (p: ReturnType<typeof plan>) => ({ ...p, plan_id: nonce }),
    (p: ReturnType<typeof plan>) => ({ ...p, prepared: 0 }),
    (p: ReturnType<typeof plan>) => ({
      ...p,
      items: [{ ...p.items[0], copy_object: nonce }],
    }),
  ]
) {
  Deno.test(
    "rejects malformed or overexposed plan " + String(mutate),
    async () => {
      const f = fixture({ plan: mutate });
      assert(
        (await f.call("check", { plan_id: planID, after: null })).status >= 400,
      );
    },
  );
}
Deno.test("gate is disabled without network access", async () => {
  let calls = 0;
  const h = createProjectFilesHandler({
    url: "https://unused.invalid",
    serviceKey: "secret",
  }, {
    send: () => {
      calls++;
      throw Error("network");
    },
  });
  const r = await h(
    new Request("https://client.invalid/?action=copy", { method: "POST" }),
  );
  assert.equal(r.status, 503);
  assert.equal(calls, 0);
});

Deno.test("committed preparation requires explicit complete transfer facts", async () => {
  const f = fixture({
    plan: (p) => ({ ...p, state: "committed", project_transferred: true }),
  });
  const r = await f.call("check", { plan_id: planID, after: null });
  assert.equal(r.status, 200);
  assert.equal(r.value.plan.project_transferred, true);
});
Deno.test("committed preparation cannot conceal unfinished copies", async () => {
  for (
    const change of [{ prepared: 0 }, {
      items: [{ ...plan().items[0], state: "waiting" }],
    }]
  ) {
    const f = fixture({
      plan: (p) => ({
        ...p,
        ...change,
        state: "committed",
        project_transferred: true,
      }),
    });
    assert.equal(
      (await f.call("check", { plan_id: planID, after: null })).status,
      503,
    );
  }
});

Deno.test("disabled preparation still permits read-only recovery", async () => {
  const f = fixture({ enabled: false });
  const p = plan();
  const r = await f.call("resolve", {
    request_id: nonce,
    scope: p.scope,
    inspection_token: "a".repeat(64),
  });
  assert.equal(r.status, 200);
  assert.equal(f.calls.some((c) => c.path.startsWith("/storage/")), false);
});
Deno.test("cancelled empty identity can be recovered while disabled", async () => {
  const f = fixture({
    enabled: false,
    plan: (p) => ({
      ...p,
      state: "cancelled",
      total: 0,
      prepared: 0,
      items: [],
    }),
  });
  const r = await f.call("cancel_request", {
    request_id: nonce,
    scope: plan().scope,
    inspection_token: "a".repeat(64),
  });
  assert.equal(r.status, 200);
  assert.equal(r.value.plan.total, 0);
  assert.equal(r.value.plan.project_transferred, false);
});
Deno.test("empty identity never claims ready or committed", async () => {
  for (const state of ["ready", "committed"]) {
    const f = fixture({
      plan: (p) => ({
        ...p,
        state,
        total: 0,
        prepared: 0,
        items: [],
        project_transferred: state === "committed",
      }),
    });
    assert.equal(
      (await f.call("check", { plan_id: planID, after: null })).status,
      503,
    );
  }
});

Deno.test("unacknowledged reservation attests only this producer never posted", async () => {
  const f = fixture({ reserveLost: true });
  assert.equal((await f.call()).status, 503);
  assert.equal(f.producers.length, 1);
  assert(/^[a-f0-9-]{36}$/.test(f.producers[0]));
  assert.deepEqual(f.observations, [{
    plan_id: planID,
    operation_id: operation,
    producer_id: f.producers[0],
    proof: "not_started",
  }]);
  assert.equal(
    f.calls.some((c) => c.method === "POST" && c.path.startsWith("/storage/")),
    false,
  );
});
Deno.test("independent terminal observation survives request abort before POST", async () => {
  const f = fixture({ abortReserve: new AbortController() });
  assert.equal((await f.call()).status, 503);
  assert.equal(f.observations.length, 1);
  assert.equal(f.observations[0].proof, "not_started");
  assert.equal(
    f.calls.some((c) => c.method === "POST" && c.path.startsWith("/storage/")),
    false,
  );
});
Deno.test("provider acknowledgement remains terminal even if copied bytes are corrupt", async () => {
  const f = fixture({ corrupt: true });
  assert.equal((await f.call()).status, 409);
  assert.equal(f.observations[0].proof, "provider_terminal");
});
Deno.test("lost POST reply attests verified bytes only after positive reconcile", async () => {
  const f = fixture({ lost: true });
  assert.equal((await f.call()).status, 200);
  assert.equal(f.observations[0].proof, "verified");
});
Deno.test("an indeterminate POST and missing object produce no terminal claim", async () => {
  const f = fixture({ lost: true, missingCopy: true });
  assert.equal((await f.call()).status, 409);
  assert.equal(f.observations.length, 0);
});
Deno.test("lost terminal acknowledgement cannot change verified preparation outcome", async () => {
  const f = fixture({ terminalLost: true });
  assert.equal((await f.call()).status, 200);
  assert.equal(f.observations.length, 1);
  assert.equal(
    f.calls.filter((c) => c.method === "POST" && c.path.startsWith("/storage/"))
      .length,
    1,
  );
});
Deno.test("native callers cannot supply a producer identity", async () => {
  const f = fixture();
  assert.equal(
    (await f.call("copy", {
      plan_id: planID,
      operation_id: operation,
      producer_id: nonce,
    })).status,
    400,
  );
  assert.equal(f.producers.length, 0);
  assert.equal(f.observations.length, 0);
});

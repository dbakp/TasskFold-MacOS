import { createEmailRoutesHandler, emailInboundDomain } from "./handler.ts";
const owner = "f091cafe-0000-4000-8000-000000000001",
  session = "f091cafe-0000-4000-8000-000000000011",
  id = "f091cafe-0000-4000-8000-000000000021",
  next = "f091cafe-0000-4000-8000-000000000022";
const config = {
  url: "https://email.test",
  serviceKey: "private-service-fixture",
  inboundDomain: "mail.taskfold.test",
};
const token = (sub: unknown = owner, sid: unknown = session) =>
  "header." + btoa(JSON.stringify({ sub, session_id: sid })) + ".signature";
const stamp = "2026-10-23T16:00:00Z";
const setup = (routeID = id) => ({
  id: routeID,
  name: "Design inbox",
  alias_hash: "a".repeat(64),
  project_id: null,
  requested_at: stamp,
});
const route = (routeID = id, state = "active", revision = 1) => ({
  id: routeID,
  name: "Design inbox",
  project_id: null,
  sender_email: "owner@example.test",
  state,
  revision,
  rotated_to: null,
  created_at: stamp,
  updated_at: stamp,
  accept_after: stamp,
});
const response = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const request = (action = "list", body: unknown = {}, bearer = token()) =>
  new Request("https://edge.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + bearer,
      "X-Taskfold-Email": "1",
      "X-Taskfold-Email-Domain": config.inboundDomain,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ action, body }),
  });
const assert = (value: unknown, detail: string) => {
  if (!value) throw Error(detail);
};
function harness(
  result: unknown = { account: owner, available: true, routes: [route()] },
  cfg = config,
) {
  const calls: Request[] = [];
  const handler = createEmailRoutesHandler(cfg, {
    admit: () => Promise.resolve(null),
    send: (req) => {
      calls.push(req);
      return Promise.resolve(
        req.url.endsWith("/auth/v1/user")
          ? response({ id: owner })
          : response(result),
      );
    },
  });
  return { handler, calls };
}
Deno.test("domain configuration accepts only canonical bare DNS names", () => {
  assert(
    emailInboundDomain(config.inboundDomain) === config.inboundDomain,
    "canonical domain refused",
  );
  for (
    const value of [
      undefined,
      "",
      "https://mail.example.test",
      "user@example.test",
      "localhost",
      "Mail.example.test",
      "127.0.0.1",
      "mail..test",
      "mail.test.",
      "-mail.test",
      "mail.test/path",
      "a".repeat(64) + ".test",
    ]
  ) {
    assert(
      emailInboundDomain(value) === null,
      "invalid domain accepted " + value,
    );
  }
});
Deno.test("admission refusal precedes parsing/Auth and is returned unchanged", async () => {
  const refusal = response({ error: "budget" }, 429);
  const handler = createEmailRoutesHandler(config, {
    admit: () => Promise.resolve(refusal),
    send: () => {
      throw Error("must not send");
    },
  });
  assert(await handler(request()) === refusal, "admission bypassed");
});
Deno.test("default admission shares the durable management bucket and never sends raw bearer/IP", async () => {
  const calls: Request[] = [];
  const handler = createEmailRoutesHandler({
    ...config,
    forwardedForMode: "supabase-cloudflare-v1",
  }, {
    send: async (req) => {
      calls.push(req);
      if (req.url.endsWith("taskfold_automation_admit")) {
        const body = await req.clone().json();
        assert(
          body._route === "keys" && /^[a-f0-9]{64}$/.test(body._ip_hash) &&
            /^[a-f0-9]{64}$/.test(body._credential_hash),
          "management budget/hash missing",
        );
        assert(
          !JSON.stringify(body).includes(token()) &&
            !JSON.stringify(body).includes("198.51.100.10"),
          "raw admission identity leaked",
        );
        return response({
          allowed: false,
          retry_after: 10,
          limited_by: "credential",
        });
      }
      throw Error("denied request reached Auth");
    },
  });
  const req = request();
  req.headers.set("X-Forwarded-For", "198.51.100.10");
  req.headers.set("CF-Connecting-IP", "198.51.100.10");
  const result = await handler(req);
  assert(
    result.status === 429 && result.headers.get("Retry-After") === "10" &&
      calls.length === 1,
    "durable refusal lost",
  );
});
Deno.test("default admission fails closed without verified gateway forwarding", async () => {
  let called = false;
  const result = await createEmailRoutesHandler(config, {
    send: () => {
      called = true;
      throw Error();
    },
  })(request());
  assert(result.status === 503 && !called, "unverified IP admitted");
});
Deno.test("methods, missing bearer and protocol mismatch stop before Auth", async () => {
  const { handler, calls } = harness();
  assert(
    (await handler(new Request("https://edge.test"))).status === 405,
    "GET allowed",
  );
  const noToken = request();
  noToken.headers.delete("Authorization");
  assert((await handler(noToken)).status === 401, "missing bearer allowed");
  const old = request();
  old.headers.delete("X-Taskfold-Email");
  assert(
    (await handler(old)).status === 428 && calls.length === 0,
    "protocol mismatch reached Auth",
  );
});
Deno.test("invalid project origin never forwards privileged headers", async () => {
  for (
    const url of [
      "http://email.test",
      "https://user:pass@email.test",
      "https://email.test/path",
      "https://email.test/?q=x",
      "https://email.test/#x",
    ]
  ) {
    const { handler, calls } = harness(undefined, { ...config, url });
    assert(
      (await handler(request())).status === 503 && calls.length === 0,
      "unsafe origin used",
    );
  }
});
Deno.test("malformed envelopes/actions/setup/revisions cannot reach Auth or SQL", async () => {
  const bad: [string, unknown][] = [
    ["list", { account: owner }],
    ["deliver", {}],
    ["create", { ...setup(), raw_alias: "secret" }],
    ["create", { ...setup(), sender_email: "forged@example.test" }],
    ["create", { ...setup(), alias_hash: "a".repeat(63) }],
    ["create", { ...setup(), project_id: owner.toUpperCase() }],
    ["create", { ...setup(), name: "x\nset admin" }],
    ["create", { ...setup(), name: "🙂".repeat(81) }],
    ["create", { ...setup(), requested_at: "yesterday" }],
    ["create", { ...setup(), id: "00000000-0000-0000-0000-000000000000" }],
    ["pause", { id, revision: 0 }],
    ["revoke", { id, revision: -1 }],
    ["resume", { id, revision: 1.5 }],
    ["revoke", { id, revision: 2147483647 }],
    ["rotate", { id, revision: 1, replacement: setup() }],
    ["rotate", {
      id,
      revision: 1,
      replacement: { ...setup(next), project_id: "missing" },
    }],
  ];
  for (const [action, body] of bad) {
    const { handler, calls } = harness();
    assert(
      (await handler(request(action, body))).status === 400 &&
        calls.length === 0,
      "bad request admitted " + action,
    );
  }
  for (
    const value of [null, [], { action: "list", body: {}, account: owner }]
  ) {
    const { handler, calls } = harness();
    assert(
      (await handler(new Request(request(), { body: JSON.stringify(value) })))
            .status === 400 && calls.length === 0,
      "bad envelope admitted",
    );
  }
});
Deno.test("oversize and invalid UTF8 request bodies stop before Auth", async () => {
  for (const body of ["x".repeat(8193), new Uint8Array([0xff, 0xfe])]) {
    const { handler, calls } = harness();
    assert(
      (await handler(new Request(request(), { body }))).status === 400 &&
        calls.length === 0,
      "invalid body admitted",
    );
  }
});
Deno.test("live Auth identity and native session bind service-only management", async () => {
  const { handler, calls } = harness();
  const result = await handler(request());
  assert(result.status === 200 && calls.length === 2, "list failed");
  assert(
    calls[0].headers.get("Authorization") === "Bearer " + token() &&
      calls[0].redirect === "error",
    "live Auth detached",
  );
  assert(
    calls[1].headers.get("Authorization") === "Bearer " + config.serviceKey &&
      calls[1].url.endsWith("/rpc/taskfold_email_routes"),
    "privileged RPC changed",
  );
  const body = await calls[1].json();
  assert(
    body._account === owner && body._session === session &&
      body._action === "list",
    "account/session not derived from verified token",
  );
  assert(
    result.headers.get("Cache-Control") === "no-store",
    "private receipt cacheable",
  );
});
Deno.test("subject mismatch, malformed JWT/session and anonymous Auth refuse SQL", async () => {
  for (
    const bearer of [
      token(next),
      token(owner, null),
      token(owner, "invalid"),
      "broken",
      "header.bnVsbA.signature",
    ]
  ) {
    const { handler, calls } = harness();
    assert(
      (await handler(request("list", {}, bearer))).status === 401 &&
        calls.length === 1,
      "unverified claims reached SQL",
    );
  }
  for (const status of [401, 403, 500]) {
    let calls = 0;
    const handler = createEmailRoutesHandler(config, {
      admit: () => Promise.resolve(null),
      send: () => {
        calls++;
        return Promise.resolve(
          response({ id: owner, diagnostic: "PRIVATE" }, status),
        );
      },
    });
    const result = await handler(request());
    assert(
      result.status === (status === 500 ? 503 : 401) && calls === 1 &&
        !(await result.text()).includes("PRIVATE"),
      "Auth refusal leaked or reached SQL",
    );
  }
  const handler = createEmailRoutesHandler(config, {
    admit: () => Promise.resolve(null),
    send: () => Promise.resolve(response({ id: owner, is_anonymous: true })),
  });
  assert((await handler(request())).status === 401, "anonymous user admitted");
});
Deno.test("list strips private/future SQL fields and rejects foreign/duplicate/broken receipts", async () => {
  const result = await harness({
    account: owner,
    available: true,
    routes: [{ ...route(), alias_hash: "PRIVATE", raw_alias: "PRIVATE" }],
    provider_secret: "PRIVATE",
  }).handler(request());
  const text = await result.text();
  assert(
    result.status === 200 && !text.includes("PRIVATE") &&
      JSON.parse(text).domain === config.inboundDomain,
    "private SQL fields escaped",
  );
  for (
    const value of [
      { account: next, available: true, routes: [] },
      { account: owner, available: "true", routes: [] },
      { account: owner, available: true, routes: [route(), route()] },
      {
        account: owner,
        available: true,
        routes: [{ ...route(), revision: 0 }],
      },
      {
        account: owner,
        available: true,
        routes: [{ ...route(), state: "unknown" }],
      },
      {
        account: owner,
        available: true,
        routes: [{ ...route(), created_at: "invalid" }],
      },
    ]
  ) {
    assert(
      (await harness(value).handler(request())).status === 503,
      "bad receipt trusted",
    );
  }
});
Deno.test("missing domain/disabled DB never advertises an address; pause/revoke remain usable", async () => {
  const cfg = { ...config, inboundDomain: "" };
  let h = harness(undefined, cfg);
  let result = await h.handler(request());
  let value = await result.json();
  assert(
    result.status === 200 && value.available === false &&
      value.domain === null && value.routes.length === 1,
    "metadata hidden or unusable domain advertised",
  );
  for (const action of ["create", "resume", "rotate"]) {
    h = harness(undefined, cfg);
    const body = action === "create"
      ? setup()
      : action === "rotate"
      ? { id, revision: 1, replacement: setup(next) }
      : { id, revision: 1 };
    assert(
      (await h.handler(request(action, body))).status === 503 &&
        h.calls.length === 1,
      "missing domain reached mutation SQL",
    );
  }
  for (const [action, state] of [["pause", "paused"], ["revoke", "revoked"]]) {
    h = harness({ account: owner, route: route(id, state, 2) }, cfg);
    assert(
      (await h.handler(request(action, { id, revision: 1 }))).status === 200 &&
        h.calls.length === 2,
      "missing domain blocked safety action",
    );
  }
  result = await harness({ account: owner, available: false, routes: [] })
    .handler(request());
  value = await result.json();
  assert(
    value.available === false && value.domain === null,
    "disabled database gate ignored",
  );
});
Deno.test("create forwards hash-only setup and preserves exact retry identity", async () => {
  const { handler, calls } = harness({ account: owner, route: route() });
  assert(
    (await handler(request("create", setup()))).status === 200,
    "create failed",
  );
  const body = await calls[1].json();
  assert(
    JSON.stringify(body._body) === JSON.stringify(setup()) &&
      body._action === "create",
    "retry identity changed",
  );
});
Deno.test("pause/resume/revoke must acknowledge expected address and state", async () => {
  for (
    const [action, state] of [["pause", "paused"], ["resume", "active"], [
      "revoke",
      "revoked",
    ]]
  ) {
    assert(
      (await harness({ account: owner, route: route(id, state, 2) }).handler(
        request(action, { id, revision: 1 }),
      )).status === 200,
      "action failed",
    );
    assert(
      (await harness({ account: owner, route: route(next, state, 2) }).handler(
        request(action, { id, revision: 1 }),
      )).status === 503,
      "wrong address acknowledged",
    );
  }
  assert(
    (await harness({ account: owner, route: route() }).handler(
      request("pause", { id, revision: 1 }),
    )).status === 503,
    "wrong state acknowledged",
  );
});
Deno.test("cancel-before-create requires matching ID and revision zero", async () => {
  for (
    const [resultID, revision, status] of [[id, 0, 200], [next, 0, 503], [
      id,
      1,
      503,
    ]] as const
  ) {
    const result = await harness({
      account: owner,
      id: resultID,
      cancelled: true,
      private: "PRIVATE",
    }).handler(request("revoke", { id, revision }));
    assert(
      result.status === status && !(await result.text()).includes("PRIVATE"),
      "cancellation result not bound",
    );
  }
});
Deno.test("rotation validates both replacement and terminal old-route receipt", async () => {
  const replaced = { ...route(id, "revoked", 2), rotated_to: next };
  const command = request("rotate", {
    id,
    revision: 1,
    replacement: setup(next),
  });
  const result = await harness({ account: owner, route: route(next), replaced })
    .handler(command);
  assert(result.status === 200, "rotation failed");
  for (
    const bad of [{ ...replaced, state: "active" }, {
      ...replaced,
      rotated_to: id,
    }, { ...replaced, id: next }]
  ) {
    assert(
      (await harness({ account: owner, route: route(next), replaced: bad })
        .handler(
          request("rotate", { id, revision: 1, replacement: setup(next) }),
        )).status === 503,
      "rotation mismatch accepted",
    );
  }
});
Deno.test("database error codes map to safe actionable messages without SQL diagnostics", async () => {
  for (
    const [code, status] of Object.entries({
      "28000": 401,
      "42501": 403,
      "PT404": 404,
      "22023": 400,
      "PT409": 409,
      "PT429": 429,
      "PT503": 503,
      "55P03": 503,
      "XX000": 503,
    })
  ) {
    let calls = 0;
    const handler = createEmailRoutesHandler(config, {
      admit: () => Promise.resolve(null),
      send: () =>
        Promise.resolve(
          ++calls === 1
            ? response({ id: owner })
            : response({ code, message: "PRIVATE", detail: "PRIVATE" }, 400),
        ),
    });
    const result = await handler(request("create", setup()));
    assert(
      result.status === status && !(await result.text()).includes("PRIVATE"),
      "error mapping failed " + code,
    );
    if (code === "55P03") {
      assert(
        result.headers.get("Retry-After") === "1",
        "transient retry hint lost",
      );
    }
  }
});
Deno.test("caller cancellation closes a stalled input stream before Auth", async () => {
  const controller = new AbortController();
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull() {
      queueMicrotask(() => controller.abort());
    },
    cancel() {
      cancelled = true;
    },
  });
  const { handler, calls } = harness();
  const result = await handler(
    new Request(
      request(),
      { body, signal: controller.signal, duplex: "half" } as RequestInit,
    ),
  );
  assert(
    result.status === 408 && cancelled && calls.length === 0,
    "input cancellation not bounded",
  );
});
Deno.test("cancellation bounds Auth/RPC even with a transport that ignores its signal", async () => {
  for (const stage of ["auth", "rpc"]) {
    const controller = new AbortController();
    let calls = 0;
    const handler = createEmailRoutesHandler(config, {
      admit: () => Promise.resolve(null),
      send: (req) => {
        calls++;
        if (
          stage === "rpc" && req.url.endsWith("/auth/v1/user")
        ) return Promise.resolve(response({ id: owner }));
        queueMicrotask(() => controller.abort());
        return new Promise<Response>(() => {});
      },
    });
    const began = performance.now();
    const result = await handler(
      new Request(request("create", setup()), { signal: controller.signal }),
    );
    assert(
      result.status === 503 && calls === (stage === "auth" ? 1 : 2) &&
        performance.now() - began < 1000 &&
        (await result.text()).includes("same address setup and revision"),
      "uncertain mutation/cancellation lost",
    );
  }
});
Deno.test("stalled upstream response bodies cancel without leaking partial data", async () => {
  for (const stage of ["auth", "rpc"]) {
    const controller = new AbortController();
    let cancelled = false, pull = 0;
    const handler = createEmailRoutesHandler(config, {
      admit: () => Promise.resolve(null),
      send: (req) => {
        if (
          stage === "rpc" && req.url.endsWith("/auth/v1/user")
        ) return Promise.resolve(response({ id: owner }));
        return Promise.resolve(
          new Response(
            new ReadableStream<Uint8Array>({
              pull(destination) {
                if (pull++ === 0) {
                  destination.enqueue(new TextEncoder().encode('{"PRIVATE":'));
                } else queueMicrotask(() => controller.abort());
              },
              cancel() {
                cancelled = true;
              },
            }),
          ),
        );
      },
    });
    const result = await handler(
      new Request(request(), { signal: controller.signal }),
    );
    assert(
      result.status === 503 && cancelled &&
        !(await result.text()).includes("PRIVATE"),
      "upstream stream cancellation failed",
    );
  }
});
Deno.test("oversized/invalid upstream response is refused without claiming mutation success", async () => {
  for (const payload of ["x".repeat(512001), new Uint8Array([0xff]), "null"]) {
    let calls = 0;
    const handler = createEmailRoutesHandler(config, {
      admit: () => Promise.resolve(null),
      send: () =>
        Promise.resolve(
          ++calls === 1 ? response({ id: owner }) : new Response(payload),
        ),
    });
    const result = await handler(request("create", setup()));
    assert(
      result.status === 503 &&
        (await result.text()).includes("same address setup"),
      "bad upstream confirmed",
    );
  }
});

Deno.test("setup, rotation and resume bind the reviewed domain", async () => {
  for (const action of ["create", "resume", "rotate"]) {
    const body = action === "create"
      ? setup()
      : action === "rotate"
      ? { id, revision: 1, replacement: setup(next) }
      : { id, revision: 1 };
    const { handler, calls } = harness();
    const req = request(action, body);
    req.headers.set("X-Taskfold-Email-Domain", "old.example.test");
    assert(
      (await handler(req)).status === 409 && calls.length === 1,
      "changed domain reached SQL",
    );
  }
});

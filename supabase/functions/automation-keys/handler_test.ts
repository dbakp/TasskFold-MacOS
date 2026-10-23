import { createHandler } from "./handler.ts";
const owner = "f091cafe-0000-4000-8000-000000000001",
  other = "f091cafe-0000-4000-8000-000000000002",
  session = "f091cafe-0000-4000-8000-000000000011",
  keyID = "f091cafe-0000-4000-8000-000000000021";
const config = {
  url: "https://automation.test",
  serviceKey: "private-service-fixture",
};
const token = (sub = owner, sessionID: unknown = session) =>
  "header." + btoa(JSON.stringify({ sub, session_id: sessionID })) +
  ".signature";
const key = {
  id: keyID,
  name: "Build script",
  prefix: "tfk_v1_f091cafe",
  scopes: ["tasks:create"],
  created_at: "2026-10-22T12:00:00+00:00",
  expires_at: "2026-11-21T12:00:00+00:00",
  revoked_at: null,
  last_used_at: null,
};
const request = (action = "list", body: unknown = {}, secret = token()) =>
  new Request("https://edge.test", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + secret,
      "X-Taskfold-Automation": "1",
    },
    body: JSON.stringify({ action, body }),
  });
const assert = (ok: unknown, message: string) => {
  if (!ok) throw new Error(message);
};
const response = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status });

Deno.test("caller cancellation closes a stalled key body before Auth", async () => {
  const controller = new AbortController();
  const began = performance.now();
  let cancelled = false, calls = 0;
  const body = new ReadableStream<Uint8Array>({
    pull() {
      queueMicrotask(() => controller.abort());
    },
    cancel() {
      cancelled = true;
    },
  });
  const handler = createHandler(config, {
    admit: () => Promise.resolve(null),
    send: () => {
      calls++;
      return Promise.resolve(response({}));
    },
  });
  const result = await handler(
    new Request("https://edge.test", {
      method: "POST",
      signal: controller.signal,
      headers: {
        Authorization: "Bearer " + token(),
        "X-Taskfold-Automation": "1",
      },
      body,
      duplex: "half",
    } as RequestInit),
  );
  assert(
    result.status === 408 && cancelled && calls === 0 &&
      performance.now() - began < 1000,
    "Cancelled input reached Auth or retained its stream",
  );
});
Deno.test("caller cancellation reaches both Auth and key RPC without confirming an uncertain mutation", async () => {
  for (const stage of ["auth", "rpc"]) {
    const controller = new AbortController();
    const began = performance.now();
    let calls = 0, cancelled = false;
    const handler = createHandler(config, {
      admit: () => Promise.resolve(null),
      send: (req) => {
        calls++;
        if (stage === "rpc" && req.url.endsWith("/auth/v1/user")) {
          return Promise.resolve(response({ id: owner }));
        }
        return new Promise((_resolve, reject) => {
          req.signal.addEventListener("abort", () => {
            cancelled = true;
            reject(Error("PRIVATE upstream diagnostic"));
          }, { once: true });
          queueMicrotask(() => controller.abort());
        });
      },
    });
    const result = await handler(
      new Request(request("create", { id: keyID }), {
        signal: controller.signal,
      }),
    );
    const text = await result.text();
    assert(
      result.status === 503 && cancelled && performance.now() - began < 1000 &&
        calls === (stage === "auth" ? 1 : 2),
      "Cancellation was detached from upstream work",
    );
    assert(
      text.includes("same key ID") && !text.includes("PRIVATE"),
      "Uncertain change lost its retry identity or exposed diagnostics",
    );
  }
});
Deno.test("stalled Auth response body is cancelled even when transport does not wire its stream to the signal", async () => {
  const controller = new AbortController();
  let cancelled = false, calls = 0, pulls = 0;
  const handler = createHandler(config, {
    admit: () => Promise.resolve(null),
    send: () => {
      calls++;
      return Promise.resolve(
        new Response(
          new ReadableStream<Uint8Array>({
            pull(destination) {
              if (pulls++ === 0) {
                destination.enqueue(new TextEncoder().encode('{"id":'));
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
    result.status === 503 && cancelled && calls === 1,
    "Stalled Auth response retained work or reached RPC",
  );
});
Deno.test("oversized upstream reply cannot hang on an unresolved cancellation acknowledgement", async () => {
  let cancelled = false;
  const handler = createHandler(config, {
    admit: () => Promise.resolve(null),
    send: () =>
      Promise.resolve(
        new Response(
          new ReadableStream<Uint8Array>({
            start(destination) {
              destination.enqueue(new Uint8Array(256001));
            },
            cancel() {
              cancelled = true;
              return new Promise(() => {});
            },
          }),
        ),
      ),
  });
  const result = await handler(request());
  assert(
    result.status === 503 && cancelled,
    "Oversized stream was not promptly rejected and cancelled",
  );
});
Deno.test("temporary management failures expose a retry hint and preserve the exact key intent", async () => {
  for (const code of ["40P01", "40001", "55P03", "57014"]) {
    const f = fixture({ code });
    const result = await f.handler(request("create", { id: keyID }));
    assert(
      result.status === 503 && result.headers.get("Retry-After") === "1",
      "Missing bounded management retry",
    );
    assert(
      result.headers.get("Cache-Control") === "no-store",
      "Cached uncertain result",
    );
    assert(
      (await result.text()).includes("same key ID"),
      "Retry could mint a second key",
    );
  }
});
function fixture(
  options: {
    auth?: number;
    code?: string;
    account?: string;
    value?: unknown;
    throws?: boolean;
  } = {},
) {
  const calls: string[] = [];
  const send = async (req: Request) => {
    calls.push(new URL(req.url).pathname);
    assert(req.redirect === "error", "Redirects allowed");
    assert(
      req.headers.get("apikey") === config.serviceKey,
      "Wrong server API key",
    );
    if (options.throws) throw new Error("PRIVATE SERVICE DETAIL");
    if (req.url.endsWith("/auth/v1/user")) {
      assert(
        req.headers.get("Authorization")?.startsWith("Bearer header."),
        "Actual caller not forwarded for Auth",
      );
      return response({
        id: owner,
        user_metadata: { account: other, admin: true },
      }, options.auth ?? 200);
    }
    assert(
      req.headers.get("Authorization") === "Bearer " + config.serviceKey,
      "Admin credential absent on server RPC",
    );
    const body = await req.json();
    assert(
      body._account === owner && body._session === session,
      "Unverified identity or editable metadata selected owner",
    );
    if (options.code) {
      return response({
        code: options.code,
        message: "PRIVATE SQL DETAIL",
        details: "PRIVATE HASH",
      }, 400);
    }
    if (options.value !== undefined) return response(options.value);
    return response(
      body._action === "list"
        ? { account: options.account ?? owner, keys: [key], next_cursor: null }
        : { account: options.account ?? owner, key },
    );
  };
  return {
    handler: createHandler(config, {
      admit: () => Promise.resolve(null),
      send,
    }),
    calls,
  };
}
Deno.test("method, missing/legacy protocol, anonymous and malformed body fail before service calls", async () => {
  const f = fixture();
  assert(
    (await f.handler(new Request("https://edge.test"))).status === 405,
    "GET accepted",
  );
  assert(
    (await f.handler(new Request("https://edge.test", { method: "POST" })))
      .status === 401,
    "Anonymous accepted",
  );
  const old = request();
  old.headers.delete("X-Taskfold-Automation");
  assert((await f.handler(old)).status === 428, "Legacy accepted");
  for (
    const [action, body] of [["other", {}], ["list", null], [
      "list",
      [],
    ]] as const
  ) {
    assert(
      (await f.handler(request(action, body))).status === 400,
      "Invalid request accepted",
    );
  }
  assert(f.calls.length === 0, "Rejected request touched service");
});
Deno.test("verified Auth subject/session alone bind management, never user metadata", async () => {
  const f = fixture(), r = await f.handler(request());
  assert(r.status === 200, "List failed");
  const value = await r.json();
  assert(
    value.account === owner && value.keys[0].id === keyID,
    "Identity changed",
  );
  assert(
    r.headers.get("Cache-Control") === "no-store",
    "Credential metadata cacheable",
  );
  assert(
    f.calls.join(",") === "/auth/v1/user,/rest/v1/rpc/taskfold_automation_keys",
    "Unexpected endpoint",
  );
});
Deno.test("create and revoke only acknowledge the exact key request", async () => {
  for (const action of ["create", "revoke"]) {
    assert(
      (await fixture().handler(request(action, { id: keyID }))).status === 200,
      "Valid key request failed",
    );
    assert(
      (await fixture().handler(request(action, { id: other }))).status === 503,
      "Foreign key acknowledgement accepted",
    );
  }
});
Deno.test("expired Auth, mismatched subjects and missing sessions cannot reach management RPC", async () => {
  const expired = fixture({ auth: 401 });
  assert(
    (await expired.handler(request())).status === 401,
    "Expired Auth accepted",
  );
  for (
    const secret of [token(other), token(owner, null), token(owner, "invalid")]
  ) {
    const f = fixture();
    assert(
      (await f.handler(request("list", {}, secret))).status === 401,
      "Unverified claims accepted",
    );
    assert(f.calls.length === 1, "Unverified claims reached SQL");
  }
});
Deno.test("scope/session/quota/conflict refusal is bounded and never returns private SQL details", async () => {
  for (
    const [code, status] of [
      ["28000", 401],
      ["42501", 403],
      ["PT429", 429],
      ["22023", 400],
      ["23505", 409],
      ["XX000", 503],
    ] as const
  ) {
    const r = await fixture({ code }).handler(request());
    assert(r.status === status, "Wrong refusal status");
    assert(!(await r.text()).includes("PRIVATE"), "Private SQL detail leaked");
  }
});
Deno.test("service outage, foreign account and malformed metadata never report success", async () => {
  for (
    const options of [
      { auth: 503 },
      { throws: true },
      { account: other },
      {
        value: {
          account: owner,
          keys: [{ ...key, scopes: ["admin"] }],
          next_cursor: null,
        },
      },
      { value: { account: owner, keys: [key, key], next_cursor: null } },
      { value: { account: owner, keys: [key], next_cursor: other } },
    ]
  ) {
    const r = await fixture(options).handler(request());
    assert(r.status === 503, "Untrusted reply accepted");
    assert(
      !(await r.text()).includes("PRIVATE"),
      "Private service detail leaked",
    );
  }
});
Deno.test("metadata projection strips hashes, secrets and account-private counters", async () => {
  const f = fixture({
    value: {
      account: owner,
      keys: [{
        ...key,
        token_hash: "PRIVATE HASH",
        secret: "PRIVATE TOKEN",
        day_requests: 123,
      }],
      next_cursor: null,
      service_key: "PRIVATE SERVICE",
    },
  });
  const r = await f.handler(request());
  assert(r.status === 200, "Projected receipt failed");
  assert(
    !(await r.text()).includes("PRIVATE"),
    "Unexpected private field forwarded",
  );
});
Deno.test("oversized and stalled caller bodies are bounded before authentication", async () => {
  const f = fixture();
  assert(
    (await f.handler(request("create", { text: "x".repeat(9000) }))).status ===
      400,
    "Oversized request accepted",
  );
  const body = new ReadableStream<Uint8Array>({ start() {}, cancel() {} });
  const req = new Request(
    "https://edge.test",
    {
      method: "POST",
      headers: {
        Authorization: "Bearer " + token(),
        "X-Taskfold-Automation": "1",
      },
      body,
      duplex: "half",
    } as RequestInit,
  );
  assert((await f.handler(req)).status === 408, "Stalled body not bounded");
  assert(f.calls.length === 0, "Unbounded input reached Auth");
});

Deno.test("cancel uses verified owner/session and fixed RPC; projects only confirmed cancellation", async () => {
  let count = 0;
  const handler = createHandler(config, {
    admit: () => Promise.resolve(null),
    send: async (req) => {
      count++;
      if (req.url.endsWith("/auth/v1/user")) {
        return response({ id: owner, user_metadata: { account: other } });
      }
      assert(
        req.url === config.url + "/rest/v1/rpc/taskfold_automation_cancel_key",
        "Wrong cancellation RPC",
      );
      assert(
        req.headers.get("Authorization") === "Bearer " + config.serviceKey,
        "No service authorization",
      );
      const body = await req.json();
      assert(
        JSON.stringify(body) ===
          JSON.stringify({ _account: owner, _session: session, _id: keyID }),
        "Unverified/extra cancellation identity",
      );
      return response({
        account: owner,
        id: keyID,
        cancelled: true,
        secret: "PRIVATE",
        token_hash: "PRIVATE",
      });
    },
  });
  const result = await handler(request("cancel", { id: keyID }));
  assert(result.status === 200 && count === 2, "Cancellation failed");
  assert(
    JSON.stringify(await result.json()) ===
      JSON.stringify({ account: owner, id: keyID, cancelled: true }),
    "Private cancellation fields exposed",
  );
});
Deno.test("cancel refuses malformed intent before Auth and unconfirmed receipts after Auth", async () => {
  for (
    const body of [{}, { id: keyID, account: other }, { id: "bad" }, {
      id: "00000000-0000-0000-0000-000000000000",
    }]
  ) {
    const f = fixture();
    assert(
      (await f.handler(request("cancel", body))).status === 400 &&
        f.calls.length === 0,
      "Malformed cancellation sent",
    );
  }
  for (
    const receipt of [
      { account: other, id: keyID, cancelled: true },
      { account: owner, id: other, cancelled: true },
      { account: owner, id: keyID, cancelled: false },
      { account: owner, id: keyID, cancelled: "true" },
      { account: owner, id: keyID },
    ]
  ) {
    const handler = createHandler(config, {
      admit: () => Promise.resolve(null),
      send: (req) =>
        Promise.resolve(
          req.url.endsWith("/auth/v1/user")
            ? response({ id: owner })
            : response(receipt),
        ),
    });
    assert(
      (await handler(request("cancel", { id: keyID }))).status === 503,
      "Unconfirmed cancellation acknowledged",
    );
  }
});

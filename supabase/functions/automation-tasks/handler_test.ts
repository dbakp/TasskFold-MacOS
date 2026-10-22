import { createHandler } from "./handler.ts";
const owner = "f093cafe-0000-4000-8000-000000000001",
  id = "f093cafe-0000-4000-8000-000000000041";
const keyID = "f093cafe-0000-4000-8000-000000000021";
const secret = "tfk_v1_" + keyID.replaceAll("-", "") +
  "_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const config = {
  url: "https://task-api.test",
  serviceKey: "private-fixture-service",
};
const assert = (value: unknown, message: string) => {
  if (!value) throw new Error(message);
};
const response = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status });
function task(taskID = id) {
  return {
    id: taskID,
    user_id: owner,
    task_generation: "f093cafe-0000-4000-8000-000000000091",
    completion_version: 0,
    title: "Synthetic task",
    description: null,
    completed: false,
    completed_at: null,
    created_at: "2026-10-23T12:00:00Z",
    priority: 4,
    due_date: null,
    due_time: null,
    project_id: null,
    section_id: null,
    labels: [],
    subtasks: [],
    reminders: [],
    reminder_specs: [],
    attachments: [],
    comments: [],
    is_recurring: false,
    recurrence_pattern: null,
    recurrence_parent_id: null,
    recurrence_end_date: null,
    notification_sent_at: null,
    assigned_to: null,
    deadline_date: null,
    duration_minutes: null,
    time_zone: null,
    scheduled_at: null,
    source_metadata: {},
  };
}
const request = (action = "get", body: unknown = { id }, token = secret) =>
  new Request("https://edge.test", {
    method: "POST",
    headers: { Authorization: "Bearer " + token, "X-Taskfold-Automation": "1" },
    body: JSON.stringify({ action, body }),
  });
function fixture(value: unknown = { task: task() }, status = 200) {
  const calls: Request[] = [];
  const handler = createHandler(config, {
    send: (req) => {
      calls.push(req.clone());
      return Promise.resolve(response(value, status));
    },
  });
  return { handler, calls };
}
Deno.test("invalid method, token, protocol and input cannot reach service", async () => {
  const f = fixture();
  assert(
    (await f.handler(new Request("https://edge.test"))).status === 405,
    "GET accepted",
  );
  for (
    const token of [
      "",
      "header.jwt.signature",
      secret.toUpperCase(),
      secret + "x",
      secret.replace("tfk_v1_", "tfk_v2_"),
      "tfk_v1_" + "0".repeat(32) + "_" + "A".repeat(43),
    ]
  ) {
    assert(
      (await f.handler(request("get", { id }, token))).status === 401,
      "Invalid key accepted",
    );
  }
  const legacy = request();
  legacy.headers.delete("X-Taskfold-Automation");
  assert((await f.handler(legacy)).status === 428, "Missing protocol accepted");
  for (
    const [action, body] of [
      ["create", {}],
      ["get", {}],
      ["get", { id, account: owner }],
      ["get", { id: "no" }],
      ["list", { limit: 0 }],
      ["list", { limit: 51 }],
      ["list", { limit: 1.5 }],
      ["list", { completed: null }],
      ["list", { project_id: 2 }],
      ["list", { after: null }],
      ["list", { future: true }],
    ]
  ) {
    assert(
      (await f.handler(request(action as string, body))).status === 400,
      "Unsupported input accepted",
    );
  }
  assert(f.calls.length === 0, "Invalid caller reached privileged service");
});
Deno.test("exact token hash and parsed key ID go only to fixed service RPC", async () => {
  const f = fixture();
  const reply = await f.handler(request());
  assert(reply.status === 200, "Read failed");
  assert(
    reply.headers.get("Cache-Control") === "no-store",
    "Response may be cached",
  );
  assert(f.calls.length === 1, "Unexpected auth/session or data requests");
  const req = f.calls[0];
  assert(
    req.url === "https://task-api.test/rest/v1/rpc/taskfold_automation_read",
    "Wrong service path",
  );
  assert(req.redirect === "error", "Redirects allowed");
  assert(
    req.headers.get("apikey") === config.serviceKey &&
      req.headers.get("Authorization") === "Bearer " + config.serviceKey,
    "Incorrect service authorization",
  );
  const input = await req.json(),
    hash = Array.from(
      new Uint8Array(
        await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret)),
      ),
    ).map((b) => b.toString(16).padStart(2, "0")).join("");
  assert(
    input._key === keyID && input._hash === hash && input._action === "get" &&
      input._body.id === id,
    "Identity/hash/body changed",
  );
  assert(!JSON.stringify(input).includes(secret), "Raw secret forwarded");
  assert(
    Object.keys(input).sort().join(",") === "_action,_body,_hash,_key",
    "Caller supplied authorization metadata",
  );
});
Deno.test("projection drops unrecognized task and response fields", async () => {
  const f = fixture({
    task: {
      ...task(),
      token_hash: "PRIVATE HASH",
      future_private_column: "PRIVATE COLUMN",
    },
    admin_secret: "PRIVATE SERVICE",
  });
  const reply = await f.handler(request()), text = await reply.text();
  assert(reply.status === 200, "Projection failed");
  assert(!text.includes("PRIVATE"), "Unknown private fields escaped");
});
Deno.test("get refuses wrong task, missing fields and rounded revisions", async () => {
  const missing: Record<string, unknown> = { ...task() };
  delete missing.title;
  for (
    const row of [{ ...task(), id: owner }, missing, {
      ...task(),
      completion_version: 9007199254740992,
    }, { ...task(), task_generation: "no" }]
  ) {
    assert(
      (await fixture({ task: row }).handler(request())).status === 503,
      "Unconfirmed/malformed task escaped",
    );
  }
});
Deno.test("list filters, ordered bounded pages and cursor are confirmed", async () => {
  const second = "f093cafe-0000-4000-8000-000000000042";
  const good = fixture({ tasks: [task(), task(second)], next_cursor: second });
  assert(
    (await good.handler(
      request("list", { limit: 2, project_id: null, completed: false }),
    )).status === 200,
    "Valid page refused",
  );
  for (
    const value of [
      { tasks: [task(), task()], next_cursor: id },
      { tasks: [task(second), task()], next_cursor: id },
      { tasks: [task()], next_cursor: second },
      { tasks: [task()], next_cursor: undefined },
      { tasks: [task(), task(second)], next_cursor: null },
      { tasks: [{ ...task(), completed: true }], next_cursor: null },
    ]
  ) {
    assert(
      (await fixture(value).handler(
        request("list", { limit: 1, completed: false }),
      )).status === 503,
      "Unconfirmed page escaped",
    );
  }
  assert(
    (await fixture({ tasks: [task()], next_cursor: null }).handler(
      request("list", { after: id }),
    )).status === 503,
    "Non-advancing cursor accepted",
  );
  assert(
    (await fixture({
      tasks: [{ ...task(), project_id: owner }],
      next_cursor: null,
    }).handler(request("list", { project_id: null }))).status === 503,
    "Wrong project escaped",
  );
});
Deno.test("SQL failures map to bounded safe errors without forwarding private details", async () => {
  for (
    const [code, status] of [
      ["28000", 401],
      ["42501", 403],
      ["22023", 400],
      ["PT404", 404],
      ["PT409", 409],
      ["PT413", 413],
      ["PT429", 429],
      ["XX000", 503],
    ]
  ) {
    const f = fixture({
      code,
      message: "PRIVATE SQL",
      details: "PRIVATE HASH",
      hint: secret,
    }, 400);
    const reply = await f.handler(request());
    assert(reply.status === status, "Wrong status for " + code);
    assert(
      !(await reply.text()).includes("PRIVATE"),
      "Private upstream error escaped",
    );
  }
});
Deno.test("oversized and invalid UTF-8 incoming streams refuse before service", async () => {
  const f = fixture();
  const headers = {
    Authorization: "Bearer " + secret,
    "X-Taskfold-Automation": "1",
  };
  for (const body of ["x".repeat(8193), new Uint8Array([255, 255])]) {
    assert(
      (await f.handler(
        new Request("https://edge.test", { method: "POST", headers, body }),
      )).status === 400,
      "Malformed body accepted",
    );
  }
  assert(f.calls.length === 0, "Invalid body reached server");
});
Deno.test("upstream body bound, redirects/network errors and server configuration fail closed", async () => {
  const oversized = createHandler(config, {
    send: () => Promise.resolve(new Response("x".repeat(256001))),
  });
  assert(
    (await oversized(request())).status === 503,
    "Oversized response accepted",
  );
  const failure = createHandler(config, {
    send: () => {
      throw new Error("PRIVATE SERVICE FAILURE " + secret);
    },
  });
  const reply = await failure(request());
  assert(
    reply.status === 503 && !(await reply.text()).includes(secret),
    "Network error escaped",
  );
  for (
    const url of [
      "http://task-api.test",
      "https://user:password@task-api.test",
      "https://task-api.test/path",
      "https://task-api.test/?secret=x",
    ]
  ) {
    let called = false;
    const handler = createHandler({ ...config, url }, {
      send: () => {
        called = true;
        throw new Error();
      },
    });
    assert(
      (await handler(request())).status === 503 && !called,
      "Unsafe service configuration accepted",
    );
  }
});
Deno.test("stalled incoming body is cancelled within input deadline", async () => {
  let cancelled = false;
  const f = fixture();
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(new TextEncoder().encode('{"action":'));
    },
    cancel() {
      cancelled = true;
    },
  });
  const reply = await f.handler(
    new Request("https://edge.test", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + secret,
        "X-Taskfold-Automation": "1",
      },
      body,
    }),
  );
  assert(
    reply.status === 408 && cancelled && f.calls.length === 0,
    "Input deadline failed",
  );
});

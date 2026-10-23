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
    revision: "a".repeat(64),
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
    send: () =>
      Promise.resolve(
        response({ task: { ...task(), description: "x".repeat(1048577) } }),
      ),
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

const generation = "f093cafe-0000-4000-8000-000000000091";
const requestID = "f093cafe-0000-4000-8000-000000000061";
function writeBody(action: string = "create"): Record<string, unknown> {
  const common = {
    id,
    request_id: requestID,
    task_generation: generation,
    time_zone: "UTC",
  };
  return action === "create"
    ? { ...common, fields: { title: "Synthetic create" } }
    : action === "update"
    ? {
      ...common,
      base: { task_generation: generation, title: "Before" },
      fields: { title: "After" },
    }
    : action === "delete"
    ? { ...common, revision: "a".repeat(64), descendants: [] }
    : {
      ...common,
      base: {
        task_generation: generation,
        completed: false,
        completed_at: null,
        completion_version: 0,
      },
    };
}
function writeRequest(
  action = "create",
  body = writeBody(action),
  route = "/write",
) {
  return new Request("https://edge.test" + route, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + secret,
      "X-Taskfold-Automation": "1",
    },
    body: JSON.stringify({ action, body }),
  });
}
function acknowledgement(
  action = "create",
  overrides: Record<string, unknown> = {},
) {
  return {
    replayed: false,
    receipt: {
      request_id: requestID,
      operation: action,
      task_id: id,
      task_generation: action === "delete" ? null : generation,
      completion_version: action === "delete" ? null : 0,
      successor_id: null,
      successor_generation: null,
      deleted: action === "delete",
      applied_at: "2026-10-23T12:00:00Z",
      ...overrides,
    },
  };
}
Deno.test("write actions use their dedicated fixed transaction RPC and hashed key", async () => {
  for (const action of ["create", "update", "complete", "reopen", "delete"]) {
    const f = fixture(acknowledgement(action));
    const reply = await f.handler(writeRequest(action));
    assert(reply.status === 200, "Write refused: " + action);
    assert(
      f.calls.length === 1 &&
        f.calls[0].url ===
          "https://task-api.test/rest/v1/rpc/taskfold_automation_write",
      "Write split into unsafe service calls",
    );
    const input = await f.calls[0].json();
    assert(
      input._action === action && input._key === keyID &&
        input._body.request_id === requestID,
      "Write identity changed",
    );
    assert(
      !JSON.stringify(input).includes(secret),
      "Authorization secret forwarded",
    );
    assert(reply.headers.get("Cache-Control") === "no-store", "Write cached");
  }
});
Deno.test("write and read routes cannot silently accept each other's operations", async () => {
  const f = fixture();
  assert(
    (await f.handler(writeRequest("create", writeBody(), "/"))).status === 400,
    "Write accepted on read route",
  );
  const get = new Request("https://edge.test/write", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + secret,
      "X-Taskfold-Automation": "1",
    },
    body: JSON.stringify({ action: "get", body: { id } }),
  });
  assert(
    (await f.handler(get)).status === 400 && f.calls.length === 0,
    "Read accepted on write route",
  );
});
Deno.test("write identities, baseline binding and unknown envelope fields fail before service", async () => {
  const f = fixture();
  for (
    const body of [
      { ...writeBody(), account: owner },
      { ...writeBody(), task_generation: null },
      { ...writeBody(), id: "00000000-0000-0000-0000-000000000000" },
      { ...writeBody(), request_id: "no" },
      { ...writeBody(), time_zone: "" },
      { ...writeBody(), fields: null },
    ]
  ) {
    assert(
      (await f.handler(writeRequest("create", body))).status === 400,
      "Malformed write accepted",
    );
  }
  assert(
    (await f.handler(
      writeRequest("update", {
        ...writeBody("update"),
        base: { task_generation: owner },
      }),
    )).status === 400,
    "Foreign baseline generation accepted",
  );
  assert(f.calls.length === 0, "Malformed write reached service");
});
Deno.test("write receipt binds nonce, operation, task, generation and deletion state", async () => {
  for (
    const overrides of [
      { request_id: owner },
      { task_id: owner },
      { operation: "delete" },
      { task_generation: owner },
      { completion_version: 9007199254740992 },
      { deleted: true },
      { applied_at: "not a date" },
      { successor_id: owner, successor_generation: generation },
    ]
  ) {
    assert(
      (await fixture(acknowledgement("create", overrides)).handler(
        writeRequest(),
      )).status === 503,
      "Unconfirmed receipt accepted",
    );
  }
  assert(
    (await fixture(acknowledgement("delete", { task_generation: generation }))
      .handler(writeRequest("delete"))).status === 503,
    "Unconfirmed deletion accepted",
  );
});
Deno.test("write acknowledgements strip full task/private fields and preserve exact replay status", async () => {
  const value = acknowledgement();
  value.replayed = true;
  Object.assign(value, {
    task: { title: "PRIVATE TASK" },
    token_hash: "PRIVATE HASH",
  });
  Object.assign(value.receipt, { private_secret: "PRIVATE SECRET" });
  const reply = await fixture(value).handler(writeRequest()),
    text = await reply.text();
  assert(
    reply.status === 200 && !text.includes("PRIVATE") &&
      JSON.parse(text).replayed === true,
    "Replay projection leaked private state",
  );
});
Deno.test("write body permits reviewed content above read bound but stops at one MiB", async () => {
  const body = {
    ...writeBody(),
    fields: { title: "Synthetic", description: "x".repeat(9000) },
  };
  const f = fixture(acknowledgement());
  assert(
    (await f.handler(writeRequest("create", body))).status === 200,
    "Write incorrectly uses read input bound",
  );
  const tooBig = {
    ...writeBody(),
    fields: { title: "Synthetic", description: "x".repeat(1048577) },
  };
  assert(
    (await f.handler(writeRequest("create", tooBig))).status === 400 &&
      f.calls.length === 1,
    "Oversized write reached service",
  );
});
Deno.test("complete acknowledgements confirm paired successor generations", async () => {
  assert(
    (await fixture(
      acknowledgement("complete", {
        successor_id: owner,
        successor_generation: generation,
      }),
    ).handler(writeRequest("complete"))).status === 200,
    "Confirmed successor refused",
  );
  assert(
    (await fixture(
      acknowledgement("complete", {
        successor_id: owner,
        successor_generation: null,
      }),
    ).handler(writeRequest("complete"))).status === 503,
    "Unpaired successor accepted",
  );
});
Deno.test("browser preflight exposes only bearer protocol and no credential cookie support", async () => {
  const f = fixture();
  const result = await f.handler(
    new Request("https://edge.test/write", { method: "OPTIONS" }),
  );
  assert(
    result.status === 204 && f.calls.length === 0,
    "Preflight reached private service",
  );
  assert(
    result.headers.get("Access-Control-Allow-Origin") === "*" &&
      result.headers.get("Access-Control-Allow-Credentials") === null,
    "Unsafe credential CORS",
  );
  assert(
    (await f.handler(request())).headers.get("Access-Control-Allow-Origin") ===
      "*",
    "Authorized browser read missing CORS",
  );
});

const projectRow = (projectID = id) => ({
  id: projectID,
  name: "Synthetic project",
  color: "purple",
  order_index: 4,
  parent_id: null,
  parent_unavailable: false,
  is_archived: false,
  ancestor_archived: false,
  accepts_tasks: true,
});
const projectPage = (
  rows: unknown[] = [projectRow()],
  next: string | null = null,
) => ({
  projects: rows,
  next_cursor: next,
  inbox: { name: "Inbox", project_id: null, section_id: null },
});
Deno.test("destination actions use only the fixed hashed-key RPC and reviewed projection", async () => {
  const f = fixture({
    ...projectPage([{
      ...projectRow(),
      owner_email: "PRIVATE",
      source_metadata: { private: true },
    }]),
    private: "PRIVATE",
  });
  const result = await f.handler(request("projects", {}));
  assert(result.status === 200, "Project page rejected");
  assert(
    !JSON.stringify(await result.json()).includes("PRIVATE"),
    "Private project fields escaped",
  );
  assert(
    f.calls[0].url ===
      "https://task-api.test/rest/v1/rpc/taskfold_automation_destinations",
    "Wrong destination RPC",
  );
  const sent = await f.calls[0].text();
  assert(
    !sent.includes(secret) && sent.includes(keyID),
    "Wrong credential transport",
  );
  assert(
    result.headers.get("Cache-Control") === "no-store",
    "Cached destinations",
  );
});
Deno.test("destination input rejects ambiguous Inbox, foreign envelope fields and invalid paging before service", async () => {
  const f = fixture();
  for (
    const [action, body] of [
      ["sections", {}],
      ["sections", { project_id: null }],
      ["projects", { project_id: id }],
      ["projects", { owner: owner }],
      ["projects", { limit: 0 }],
      ["projects", { limit: 51 }],
      ["projects", { limit: 1.5 }],
      ["projects", { after: null }],
      ["sections", { project_id: id, after: "nope" }],
    ] as const
  ) {
    assert(
      (await f.handler(request(action, body))).status === 400,
      "Invalid destinations accepted",
    );
  }
  const wrongRoute = request("projects", {});
  assert(
    (await f.handler(new Request("https://edge.test/write", wrongRoute)))
      .status === 400,
    "Discovery accepted on write route",
  );
  assert(f.calls.length === 0, "Invalid request reached service");
});
Deno.test("destination response rejects inconsistent archive, hidden parent and pagination metadata", async () => {
  for (
    const page of [
      projectPage([{ ...projectRow(), is_archived: true }]),
      projectPage([{
        ...projectRow(),
        parent_id: owner,
        parent_unavailable: true,
      }]),
      projectPage([{ ...projectRow(), order_index: 1.5 }]),
      projectPage([projectRow(), projectRow()]),
      projectPage([projectRow()], owner),
      {
        ...projectPage(),
        inbox: { name: "Inbox", project_id: owner, section_id: null },
      },
      { ...projectPage(), next_cursor: undefined },
    ]
  ) {
    assert(
      (await fixture(page).handler(request("projects", {}))).status === 503,
      "Invalid metadata accepted",
    );
  }
  const f = fixture(projectPage([projectRow()], id));
  assert(
    (await f.handler(request("projects", { limit: 1 }))).status === 200,
    "Valid next page rejected",
  );
  assert(
    (await fixture(projectPage()).handler(request("projects", { after: id })))
      .status === 503,
    "Cursor order not checked",
  );
});
Deno.test("section response binds every row and page to the requested project", async () => {
  const section = { id, project_id: owner, name: "Section", order_index: null };
  const page = {
    project_id: owner,
    sections: [{ ...section, user_id: "PRIVATE" }],
    next_cursor: null,
  };
  const result = await fixture(page).handler(
    request("sections", { project_id: owner }),
  );
  assert(result.status === 200, "Valid section rejected");
  assert(
    !JSON.stringify(await result.json()).includes("PRIVATE"),
    "Section owner escaped",
  );
  for (
    const broken of [{ ...page, project_id: id }, {
      ...page,
      sections: [{ ...section, project_id: id }],
    }]
  ) {
    assert(
      (await fixture(broken).handler(
        request("sections", { project_id: owner }),
      )).status === 503,
      "Cross-project section accepted",
    );
  }
  assert(
    (await fixture({ project_id: owner, sections: [], next_cursor: null })
      .handler(request("sections", { project_id: owner }))).status === 200,
    "Empty sections rejected",
  );
});

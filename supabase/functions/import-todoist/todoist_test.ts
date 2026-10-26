import {
  color,
  ImportError,
  planning,
  prepare,
  type Snapshot,
  stableID,
  TodoistClient,
} from "./todoist.ts";
import { createHandler } from "./handler.ts";
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}
function assert(
  condition: unknown,
  message = "Assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}
async function rejects(run: () => Promise<unknown>, part: string) {
  try {
    await run();
  } catch (e) {
    assert(e instanceof Error && e.message.includes(part));
    return;
  }
  throw new Error("Expected rejection");
}
const reply = (
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
) => new Response(JSON.stringify(body), { status, headers });
const snapshot = (): Snapshot => ({
  account: "account-a",
  projects: [{ id: "p", name: "Same", color: "mint_green" }, {
    id: "inbox",
    name: "Inbox",
    inbox_project: true,
  }],
  sections: [{ id: "s", name: "Draft", project_id: "p" }],
  labels: [{ id: "l", name: "unused", color: "berry_red" }],
  tasks: [
    {
      id: "a",
      content: "Same",
      project_id: "p",
      section_id: "s",
      priority: 4,
      labels: ["shared"],
      due: { date: "2026-10-06T08:00:00Z", timezone: "Europe/Copenhagen" },
      deadline: { date: "2026-10-09" },
      duration: { amount: 30, unit: "minute" },
    },
    { id: "b", content: "Same", project_id: "p", priority: 1 },
    {
      id: "c",
      content: "Child",
      parent_id: "a",
      project_id: "p",
      description: "Kept",
    },
    { id: "d", content: "Grandchild", parent_id: "c", project_id: "p" },
    { id: "e", content: "Inbox task", project_id: "inbox" },
  ],
  comments: new Map([["a", [{
    id: "note-a",
    content: "Note",
    posted_at: "2026-10-01T10:00:00Z",
    file_attachment: {
      file_url: "https://example.com/file.pdf",
      file_name: "file.pdf",
    },
  }]], ["d", [{ id: "note-d", content: "Nested note" }]]]),
});
Deno.test("API v1 pagination follows cursor, deduplicates overlapping pages and honors rate limit", async () => {
  const calls: URL[] = [];
  const waits: number[] = [];
  let requests = 0;
  const fetcher = (async (input) => {
    const url = new URL(String(input));
    calls.push(url);
    requests++;
    if (requests === 1) return reply({}, 429, { "Retry-After": "0" });
    return url.searchParams.has("cursor")
      ? reply({ results: [{ id: "a" }, { id: "b" }], next_cursor: null })
      : reply({ results: [{ id: "a" }], next_cursor: "next" });
  }) as typeof fetch;
  equal(
    (await new TodoistClient("token", fetcher, async (ms) => {
      waits.push(ms);
    }).all("tasks")).map((x) => x.id),
    ["a", "b"],
  );
  equal(calls[0].pathname, "/api/v1/tasks");
  equal(calls[2].searchParams.get("cursor"), "next");
  equal(waits, [0]);
});
Deno.test("invalid pagination and cursor cycles fail instead of silently returning incomplete data", async () => {
  await rejects(
    () =>
      new TodoistClient("token", (async () => reply([])) as typeof fetch).all(
        "tasks",
      ),
    "pagination",
  );
  await rejects(
    () =>
      new TodoistClient(
        "token",
        (async () =>
          reply({ results: [], next_cursor: "loop" })) as typeof fetch,
      ).all("tasks"),
    "repeated",
  );
});
Deno.test("source identity separates same titles, users and source accounts", async () => {
  const prepared = await prepare(snapshot(), "user-a");
  equal(prepared.bundle.tasks.length, 3);
  equal(prepared.bundle.labels.length, 2);
  assert(
    prepared.bundle.tasks[0].record.id !== prepared.bundle.tasks[1].record.id,
  );
  equal(
    await stableID("u", "a", "tasks", "t"),
    await stableID("u", "a", "tasks", "t"),
  );
  assert(
    await stableID("u", "a", "tasks", "t") !==
      await stableID("v", "a", "tasks", "t"),
  );
  assert(
    await stableID("u", "a", "tasks", "t") !==
      await stableID("u", "b", "tasks", "t"),
  );
  equal(prepared.bundle.tasks[2].record.project_id, null);
  equal(color("mint_green"), "#6accbc");
});
Deno.test("nested children retain planning, descriptions and their own comments; preview counts are exact", async () => {
  const { bundle, preview } = await prepare(snapshot(), "user");
  const task = bundle.tasks[0].record;
  equal(task.priority, 1);
  equal(task.due_date, "2026-10-06");
  equal(task.due_time, "10:00");
  equal(task.time_zone, "Europe/Copenhagen");
  equal(task.deadline_date, "2026-10-09");
  equal(task.duration_minutes, 30);
  equal(task.subtasks[0].description, "Kept");
  equal(task.subtasks[0].subtasks[0].comments[0].text, "Nested note");
  equal(preview.counts.comments, 2);
  equal(preview.counts.subtasks, 2);
  equal(bundle.tasks[0].subtask_count, 2);
  equal(bundle.tasks[0].comment_count, 2);
  assert(preview.warnings.some((x) => x.includes("expire")));
});
Deno.test("date-only, floating, timezone rollover and DST remain distinct from deadlines", () => {
  const warnings = new Set<string>();
  equal(
    planning({
      due: { date: "2026-10-06T09:30:00" },
      deadline: { date: "2026-10-09" },
    }, warnings).due_time,
    "09:30",
  );
  equal(
    planning({
      due: { date: "2026-10-25T01:30:00Z", timezone: "Europe/Copenhagen" },
    }, warnings).due_time,
    "02:30",
  );
  equal(
    planning({
      due: { date: "2026-10-25T01:30:00Z", timezone: "Europe/Copenhagen" },
    }, warnings).scheduled_at,
    "2026-10-25T01:30:00.000Z",
  );
  equal(
    planning({ due: { date: "2026-10-05T09:00:00+02:00" } }, warnings).due_time,
    "07:00",
  );
  equal(
    planning(
      { due: { date: "2026-10-05T23:00:00Z", timezone: "Asia/Tokyo" } },
      warnings,
    ).due_date,
    "2026-10-06",
  );
  equal(planning({ due: { date: "2026-10-05" } }, warnings).due_time, null);
  equal(
    planning({ deadline: { date: "2026-02-30" } }, warnings).deadline_date,
    null,
  );
  assert(warnings.size > 0);
});
Deno.test("supported recurrence converts; unsupported rules stay explicit and preserved", async () => {
  const warnings = new Set<string>();
  equal(
    planning({
      due: { date: "2026-10-05", is_recurring: true, string: "every 2 weeks" },
    }, warnings).recurrence_pattern,
    { type: "weekly", interval: 2 },
  );
  equal(
    planning({
      due: { date: "2026-10-05", is_recurring: true, string: "every monday" },
    }, warnings).recurrence_pattern,
    { type: "weekly", interval: 1, daysOfWeek: [1] },
  );
  equal(
    planning({
      due: {
        date: "2026-10-05",
        is_recurring: true,
        string: "every last business day",
      },
    }, warnings).is_recurring,
    false,
  );
  assert(warnings.size > 0);
  const data = snapshot();
  data.tasks[0].due = {
    date: "2026-10-05",
    is_recurring: true,
    string: "every last business day",
  };
  equal(
    (await prepare(data, "u")).bundle.tasks[0].record.source_metadata.original
      .due.string,
    "every last business day",
  );
});
Deno.test("missing parents are recoverable, cycles fail, empty preview never estimates NaN", async () => {
  const data = snapshot();
  data.tasks[2].parent_id = "missing";
  assert(
    (await prepare(data, "u")).preview.warnings.some((x) =>
      x.includes("standalone")
    ),
  );
  data.tasks[2].parent_id = "d";
  await rejects(() => prepare(data, "u"), "cyclic");
  const empty: Snapshot = {
    account: "a",
    projects: [],
    sections: [],
    labels: [],
    tasks: [],
    comments: new Map(),
  };
  equal((await prepare(empty, "u")).preview.counts.comments, 0);
});
Deno.test("comments failure aborts snapshot; all tasks including children are queried", async () => {
  const ids: string[] = [];
  const fetcher = (async (input) => {
    const url = new URL(String(input));
    const path = url.pathname.split("/").pop();
    if (path === "user") return reply({ id: "a" });
    if (path === "tasks") {
      return reply({
        results: [{ id: "parent" }, { id: "child", parent_id: "parent" }],
        next_cursor: null,
      });
    }
    if (path === "comments") {
      ids.push(url.searchParams.get("task_id")!);
      return reply({}, 404);
    }
    return reply({ results: [], next_cursor: null });
  }) as typeof fetch;
  await rejects(
    () => new TodoistClient("token", fetcher).snapshot(),
    "comments",
  );
  equal(ids.sort(), ["child", "parent"]);
});
Deno.test("native JSON and explicit SSE both report committed result; provider identity is checked", async () => {
  let writes = 0;
  const fetcher = (async (input) => {
    const url = new URL(String(input));
    if (url.pathname === "/auth/v1/user") return reply({ id: "u" });
    if (url.pathname.includes("/rpc/")) {
      writes++;
      return reply({ success: true, tasksImported: 0 });
    }
    if (url.pathname.endsWith("/user")) return reply({ id: "a" });
    return reply({ results: [], next_cursor: null });
  }) as typeof fetch;
  const handler = createHandler({
    url: "https://fixture.invalid",
    key: "public",
  }, fetcher);
  const request = (extra: Record<string, unknown>) =>
    new Request("https://fixture.invalid", {
      method: "POST",
      headers: {
        Authorization: "Bearer fixture",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        userToken: "fixture-token-123456",
        stream: false,
        ...extra,
      }),
    });
  const native = await handler(request({}));
  equal(native.headers.get("Content-Type"), "application/json");
  equal((await native.json()).success, true);
  const sse = await handler(request({ stream: true }));
  equal(sse.headers.get("Content-Type"), "text/event-stream");
  assert((await sse.text()).includes('"message":"completed"'));
  const changed = await handler(request({ sourceAccount: "other" }));
  equal(changed.status, 409);
  equal(writes, 2);
  const preview = await handler(request({ preview: true }));
  equal((await preview.json()).preview, true);
  equal(writes, 2);
});
Deno.test("unauthenticated requests never call Todoist or save; persistence failure never reports success", async () => {
  let calls = 0;
  const fetcher = (async (input) => {
    calls++;
    const path = new URL(String(input)).pathname;
    if (path === "/auth/v1/user") return reply({ id: "u" });
    if (path.includes("/rpc/")) return reply({ message: "fixture" }, 400);
    if (path.endsWith("/user")) return reply({ id: "a" });
    return reply({ results: [], next_cursor: null });
  }) as typeof fetch;
  const handler = createHandler({
    url: "https://fixture.invalid",
    key: "public",
  }, fetcher);
  equal(
    (await handler(new Request("https://fixture.invalid", { method: "POST" })))
      .status,
    401,
  );
  equal(calls, 0);
  const response = await handler(
    new Request("https://fixture.invalid", {
      method: "POST",
      headers: { Authorization: "Bearer fixture" },
      body: JSON.stringify({
        userToken: "fixture-token-123456",
        stream: false,
      }),
    }),
  );
  equal(response.status, 503);
  assert((await response.json()).error.includes("No partial"));
});

Deno.test("source-only heading mapping preserves identity, notes, files, dates and hierarchy", async () => {
  const source = snapshot();
  source.tasks[0].content = "* Review notes";
  source.tasks[0].description = "Complete instructions";
  source.tasks[2].content = "* Child context";
  const original = structuredClone(source.tasks);
  const prepared = await prepare(source, "user");
  const root = prepared.bundle.tasks[0].record;
  equal(prepared.bundle.version, 2);
  equal(prepared.bundle.capabilities, ["task_headings"]);
  equal(prepared.preview.headings, {
    version: 1,
    roots: 1,
    subtasks: 1,
    available: false,
  });
  equal(root.title, "Review notes");
  equal(root.is_heading, true);
  equal(root.completed, false);
  equal(root.completed_at, null);
  equal(root.description, "Complete instructions");
  equal(root.attachments.length, 1);
  equal(root.comments.length, 1);
  equal(root.due_date, "2026-10-06");
  equal(root.subtasks[0].is_heading, true);
  equal(root.subtasks[0].subtasks[0].title, "Grandchild");
  equal(root.source_metadata.original.content, "* Review notes");
  equal(source.tasks, original);
  equal(root.id, await stableID("user", source.account, "tasks", "a"));
  const retry = await prepare(source, "user");
  equal(retry.bundle, prepared.bundle);
  assert(
    prepared.preview.warnings.some((x) => x.includes("existing Taskfold type")),
  );
});
Deno.test("only exact Todoist leading asterisk-space maps, empty headings refuse, completed source state stays explicit", async () => {
  const source = snapshot();
  source.tasks = [{
    id: "ordinary",
    content: " * Literal",
    project_id: "inbox",
  }, { id: "tab", content: "*\tLiteral", project_id: "inbox" }];
  let p = await prepare(source, "user");
  equal(p.bundle.version, undefined);
  assert(p.bundle.tasks.every((x) => x.record.is_heading === undefined));
  source.tasks = [{ id: "header", content: "* ", project_id: "inbox" }];
  await rejects(() => prepare(source, "user"), "no title");
  source.tasks[0] = {
    id: "header",
    content: "* * Reference",
    project_id: "inbox",
    checked: true,
    completed_at: "2026-10-20T10:00:00Z",
  };
  p = await prepare(source, "user");
  equal(p.bundle.tasks[0].record.title, "* Reference");
  equal(p.bundle.tasks[0].record.completed, false);
  equal(p.bundle.tasks[0].record.completed_at, null);
  equal(p.bundle.tasks[0].record.source_metadata.original.checked, true);
  assert(p.preview.warnings.some((x) => x.includes("completed state")));
});
Deno.test("heading imports fail before write unless server, client and reviewed counts agree", async () => {
  let writes = 0, typedReceipt = true;
  const source = snapshot();
  source.tasks[0].content = "* Header";
  const fetcher = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input));
    if (url.pathname === "/auth/v1/user") return reply({ id: "user" });
    if (url.pathname.includes("/rpc/")) {
      writes++;
      const body = JSON.parse(String(init?.body));
      equal(body._bundle.version, 2);
      equal(body._bundle.tasks[0].record.is_heading, true);
      return reply({
        success: true,
        ...(typedReceipt
          ? { formatVersion: 2, capabilities: ["task_headings"] }
          : {}),
      });
    }
    if (url.pathname.endsWith("/user")) return reply({ id: source.account });
    const endpoint = url.pathname.split("/").pop();
    if (endpoint === "comments") {
      return reply({ results: [], next_cursor: null });
    }
    return reply({
      results: (source as any)[endpoint!] ?? [],
      next_cursor: null,
    });
  }) as typeof fetch;
  const request = (extra: Record<string, unknown>) =>
    new Request("https://fixture.invalid", {
      method: "POST",
      headers: {
        Authorization: "Bearer fixture",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        userToken: "fixture-token-123456",
        stream: false,
        sourceAccount: source.account,
        ...extra,
      }),
    });
  const disabled = createHandler({
    url: "https://fixture.invalid",
    key: "public",
  }, fetcher);
  const enabled = createHandler({
    url: "https://fixture.invalid",
    key: "public",
    headingsEnabled: true,
  }, fetcher);
  const approval = {
    capabilities: ["task_headings"],
    headingApproval: { roots: 1, subtasks: 0 },
  };
  const preview = await disabled(request({ preview: true, ...approval }));
  const row = await preview.json();
  equal(row.headings.available, false);
  equal(row.headings.roots, 1);
  equal(writes, 0);
  equal((await disabled(request(approval))).status, 409);
  equal((await enabled(request({}))).status, 409);
  equal(
    (await enabled(request({ capabilities: ["task_headings"] }))).status,
    409,
  );
  equal(
    (await enabled(
      request({ ...approval, headingApproval: { roots: 0, subtasks: 0 } }),
    )).status,
    409,
  );
  equal(writes, 0);
  const ready = await enabled(request({ preview: true, ...approval }));
  equal((await ready.json()).headings.available, true);
  equal(writes, 0);
  equal((await enabled(request(approval))).status, 200);
  equal(writes, 1);
  typedReceipt = false;
  equal((await enabled(request(approval))).status, 503);
  equal(writes, 2);
});
Deno.test("heading nesting outside current reader capacity refuses before partial preparation", async () => {
  const source = snapshot();
  source.tasks = Array.from(
    { length: 34 },
    (_, n) => ({
      id: String(n),
      content: n === 0 ? "* Header" : "Child",
      project_id: "inbox",
      parent_id: n ? String(n - 1) : null,
    }),
  );
  await rejects(() => prepare(source, "user"), "nesting exceeds");
  source.tasks.pop();
  const boundary = await prepare(source, "user");
  equal(boundary.preview.headings.roots, 1);
  equal(boundary.preview.counts.subtasks, 32);
});

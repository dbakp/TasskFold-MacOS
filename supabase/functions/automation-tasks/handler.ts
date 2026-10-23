type Config = { url: string; serviceKey: string };
type Dependencies = { send?: (request: Request) => Promise<Response> };
const uuid = /^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
const fields = [
  "id",
  "user_id",
  "task_generation",
  "completion_version",
  "title",
  "description",
  "completed",
  "completed_at",
  "created_at",
  "priority",
  "due_date",
  "due_time",
  "project_id",
  "section_id",
  "labels",
  "subtasks",
  "reminders",
  "reminder_specs",
  "attachments",
  "comments",
  "is_recurring",
  "recurrence_pattern",
  "recurrence_parent_id",
  "recurrence_end_date",
  "notification_sent_at",
  "assigned_to",
  "deadline_date",
  "duration_minutes",
  "time_zone",
  "scheduled_at",
  "source_metadata",
  "revision",
];
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    },
  });
function object(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}
async function read(
  stream: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
): Promise<unknown> {
  if (!stream) throw new Error("Missing JSON");
  const reader = stream.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw new Error("Deadline");
    while (true) {
      const part = await reader.read();
      if (signal.aborted) throw new Error("Deadline");
      if (part.done) break;
      size += part.value.length;
      if (size > maximum) throw new Error("Body limit");
      chunks.push(part.value);
    }
    const data = new Uint8Array(size);
    let offset = 0;
    for (const part of chunks) {
      data.set(part, offset);
      offset += part.length;
    }
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data));
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
  } finally {
    signal.removeEventListener("abort", abort);
    reader.releaseLock();
  }
}
function task(value: unknown): Record<string, unknown> {
  if (
    !object(value) || fields.some((k) => !Object.hasOwn(value, k)) ||
    typeof value.id !== "string" || !uuid.test(value.id) ||
    typeof value.user_id !== "string" || !uuid.test(value.user_id) ||
    typeof value.title !== "string" || typeof value.completed !== "boolean" ||
    !Number.isSafeInteger(value.completion_version) ||
    (value.completion_version as number) < 0
  ) throw new Error("Invalid task");
  for (
    const key of [
      "task_generation",
      "project_id",
      "section_id",
      "recurrence_parent_id",
      "assigned_to",
    ]
  ) {
    if (
      value[key] !== null &&
      (typeof value[key] !== "string" || !uuid.test(value[key] as string))
    ) throw new Error("Invalid identity");
  }
  if (
    typeof value.revision !== "string" || !/^[0-9a-f]{64}$/.test(value.revision)
  ) throw new Error("Invalid revision");
  return Object.fromEntries(fields.map((k) => [k, value[k]]));
}
function inputValid(
  action: unknown,
  body: unknown,
): body is Record<string, unknown> {
  if (!object(body)) return false;
  if (action === "projects" || action === "sections") {
    if (
      Object.keys(body).some((k) =>
        !["after", "limit", "project_id"].includes(k)
      )
    ) return false;
    if (action === "projects" && Object.hasOwn(body, "project_id")) {
      return false;
    }
    if (
      action === "sections" &&
      (typeof body.project_id !== "string" || !uuid.test(body.project_id))
    ) return false;
    return (!Object.hasOwn(body, "after") ||
      (typeof body.after === "string" && uuid.test(body.after))) &&
      (!Object.hasOwn(body, "limit") ||
        (Number.isInteger(body.limit) && (body.limit as number) >= 1 &&
          (body.limit as number) <= 50));
  }
  if (action === "get") {
    return Object.keys(body).join(",") === "id" &&
      typeof body.id === "string" && uuid.test(body.id);
  }
  if (
    action !== "list" ||
    Object.keys(body).some((k) =>
      !["after", "limit", "project_id", "completed"].includes(k)
    )
  ) return false;
  if (
    Object.hasOwn(body, "after") &&
    (typeof body.after !== "string" || !uuid.test(body.after))
  ) return false;
  if (
    Object.hasOwn(body, "project_id") && body.project_id !== null &&
    (typeof body.project_id !== "string" || !uuid.test(body.project_id))
  ) return false;
  if (Object.hasOwn(body, "completed") && typeof body.completed !== "boolean") {
    return false;
  }
  if (
    Object.hasOwn(body, "limit") &&
    (!Number.isInteger(body.limit) || (body.limit as number) < 1 ||
      (body.limit as number) > 50)
  ) return false;
  return true;
}
// Project only reviewed destination metadata, never owner/member/source fields.
function destinationProjection(
  value: unknown,
  action: string,
  body: Record<string, unknown>,
) {
  if (!object(value)) throw new Error("Invalid destinations");
  const key = action === "projects" ? "projects" : "sections";
  const raw = value[key];
  if (
    !Array.isArray(raw) ||
    raw.length > ((body.limit as number | undefined) ?? 25)
  ) throw new Error("Invalid destination page");
  const fields = action === "projects"
    ? [
      "id",
      "name",
      "color",
      "order_index",
      "parent_id",
      "parent_unavailable",
      "is_archived",
      "ancestor_archived",
      "accepts_tasks",
    ]
    : ["id", "project_id", "name", "order_index"];
  const rows = raw.map((row) => {
    if (
      !object(row) || fields.some((f) => !Object.hasOwn(row, f)) ||
      typeof row.id !== "string" || !uuid.test(row.id) ||
      typeof row.name !== "string" ||
      (row.order_index !== null && !Number.isSafeInteger(row.order_index))
    ) throw new Error("Invalid destination");
    if (action === "projects") {
      if (
        (row.color !== null && typeof row.color !== "string") ||
        (row.parent_id !== null &&
          (typeof row.parent_id !== "string" || !uuid.test(row.parent_id))) ||
        [
          "parent_unavailable",
          "is_archived",
          "ancestor_archived",
          "accepts_tasks",
        ].some((f) => typeof row[f] !== "boolean") ||
        (row.parent_unavailable && row.parent_id !== null) ||
        row.accepts_tasks !== !(row.is_archived || row.ancestor_archived)
      ) throw new Error("Invalid project");
    } else if (row.project_id !== body.project_id) {
      throw new Error("Wrong project");
    }
    return Object.fromEntries(fields.map((f) => [f, row[f]]));
  });
  const ids = rows.map((r) => r.id as string);
  if (
    ids.some((id, i) =>
      (i > 0 && id <= ids[i - 1]) ||
      (typeof body.after === "string" && id <= body.after)
    ) ||
    (value.next_cursor !== null &&
      (ids.length !== ((body.limit as number | undefined) ?? 25) ||
        value.next_cursor !== ids.at(-1)))
  ) throw new Error("Invalid destination cursor");
  if (action === "sections") {
    if (value.project_id !== body.project_id) throw new Error("Wrong project");
    return {
      project_id: body.project_id,
      sections: rows,
      next_cursor: value.next_cursor,
    };
  }
  if (
    !object(value.inbox) || value.inbox.name !== "Inbox" ||
    value.inbox.project_id !== null || value.inbox.section_id !== null
  ) throw new Error("Invalid Inbox");
  return {
    projects: rows,
    inbox: { name: "Inbox", project_id: null, section_id: null },
    next_cursor: value.next_cursor,
  };
}
function projection(
  value: unknown,
  action: string,
  body: Record<string, unknown>,
) {
  if (action === "projects" || action === "sections") {
    return destinationProjection(value, action, body);
  }
  if (!object(value)) throw new Error("Invalid response");
  if (action === "get") {
    const row = task(value.task);
    if (row.id !== body.id) throw new Error("Wrong task");
    return { task: row };
  }
  if (
    !Array.isArray(value.tasks) ||
    value.tasks.length > ((body.limit as number | undefined) ?? 25)
  ) throw new Error("Invalid page");
  const rows = value.tasks.map(task), ids = rows.map((t) => t.id as string);
  if (
    new Set(ids).size !== ids.length ||
    ids.some((id, i) => i > 0 && id <= ids[i - 1]) ||
    (typeof body.after === "string" && ids.some((id) => id <= body.after!))
  ) throw new Error("Invalid order");
  for (const row of rows) {
    if (
      Object.hasOwn(body, "project_id") && row.project_id !== body.project_id
    ) throw new Error("Wrong project");
    if (Object.hasOwn(body, "completed") && row.completed !== body.completed) {
      throw new Error("Wrong state");
    }
  }
  if (
    value.next_cursor !== null &&
    (value.next_cursor !== ids.at(-1) || !ids.length)
  ) throw new Error("Invalid cursor");
  return { tasks: rows, next_cursor: value.next_cursor };
}
function writeInputValid(
  action: unknown,
  body: unknown,
): body is Record<string, unknown> {
  if (
    !object(body) || typeof action !== "string" ||
    !["create", "update", "complete", "reopen", "delete"].includes(action)
  ) return false;
  const common = ["id", "request_id", "task_generation", "time_zone"];
  const keys = [
    ...common,
    ...(action === "create"
      ? ["fields"]
      : action === "update"
      ? ["base", "fields"]
      : action === "delete"
      ? ["revision", "descendants"]
      : ["base"]),
  ].sort().join(",");
  if (Object.keys(body).sort().join(",") !== keys) return false;
  for (const key of ["id", "request_id"]) {
    if (
      typeof body[key] !== "string" || !uuid.test(body[key] as string) ||
      body[key] === "00000000-0000-0000-0000-000000000000"
    ) return false;
  }
  if (
    body.task_generation !== null &&
    (typeof body.task_generation !== "string" ||
      !uuid.test(body.task_generation) ||
      body.task_generation === "00000000-0000-0000-0000-000000000000")
  ) return false;
  if (action === "create" && body.task_generation === null) return false;
  if (
    typeof body.time_zone !== "string" || body.time_zone.length < 1 ||
    body.time_zone.length > 128
  ) return false;
  if (["create", "update"].includes(action) && !object(body.fields)) {
    return false;
  }
  if (
    ["update", "complete", "reopen"].includes(action) &&
    (!object(body.base) || !Object.hasOwn(body.base, "task_generation") ||
      body.base.task_generation !== body.task_generation)
  ) return false;
  if (
    action === "delete" &&
    (typeof body.revision !== "string" ||
      !/^[0-9a-f]{64}$/.test(body.revision) ||
      !Array.isArray(body.descendants) || body.descendants.length > 1000)
  ) return false;
  return true;
}
function writeProjection(
  value: unknown,
  action: string,
  body: Record<string, unknown>,
) {
  if (
    !object(value) || typeof value.replayed !== "boolean" ||
    !object(value.receipt)
  ) throw new Error("Invalid acknowledgement");
  const r = value.receipt;
  if (
    r.request_id !== body.request_id || r.task_id !== body.id ||
    r.operation !== action || r.deleted !== (action === "delete") ||
    typeof r.applied_at !== "string" || r.applied_at.length > 40 ||
    !/^\d{4}-\d{2}-\d{2}T/.test(r.applied_at) ||
    !Number.isFinite(Date.parse(r.applied_at))
  ) throw new Error("Unconfirmed operation");
  if (action === "delete") {
    if (
      r.task_generation !== null || r.completion_version !== null ||
      r.successor_id !== null || r.successor_generation !== null
    ) throw new Error("Invalid deletion acknowledgement");
  } else {
    if (
      r.task_generation !== body.task_generation ||
      !Number.isSafeInteger(r.completion_version) ||
      (r.completion_version as number) < 0
    ) throw new Error("Invalid task result");
    if (r.successor_id !== null || r.successor_generation !== null) {
      if (
        action !== "complete" || typeof r.successor_id !== "string" ||
        !uuid.test(r.successor_id) ||
        typeof r.successor_generation !== "string" ||
        !uuid.test(r.successor_generation)
      ) throw new Error("Invalid successor result");
    }
  }
  return {
    replayed: value.replayed,
    receipt: Object.fromEntries(
      [
        "request_id",
        "operation",
        "task_id",
        "task_generation",
        "completion_version",
        "successor_id",
        "successor_generation",
        "deleted",
        "applied_at",
      ].map((k) => [k, r[k]]),
    ),
  };
}
export function createHandler(config: Config, dependencies: Dependencies = {}) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "POST, OPTIONS",
          "Access-Control-Allow-Headers":
            "authorization, content-type, x-taskfold-automation",
          "Access-Control-Max-Age": "600",
        },
      });
    }
    if (request.method !== "POST") {
      return json({ error: "Use POST for task operations." }, 405);
    }
    const raw = /^Bearer (tfk_v1_([0-9a-f]{32})_[A-Za-z0-9_-]{43})$/i.exec(
      request.headers.get("Authorization") ?? "",
    );
    // UUID/token spelling is canonical. Never normalize or forward the raw secret.
    if (
      !raw || !/^tfk_v1_[0-9a-f]{32}_[A-Za-z0-9_-]{43}$/.test(raw[1]) ||
      /^0{32}$/.test(raw[2])
    ) return json({ error: "Use a valid Taskfold task key." }, 401);
    if (request.headers.get("X-Taskfold-Automation") !== "1") {
      return json({ error: "Use Taskfold automation protocol 1." }, 428);
    }
    let origin: string;
    try {
      const url = new URL(config.url);
      if (
        url.protocol !== "https:" || url.username || url.password ||
        url.search || url.hash || url.pathname !== "/" || !config.serviceKey
      ) throw new Error();
      origin = url.origin;
    } catch {
      return json(
        { error: "Task operations are temporarily unavailable." },
        503,
      );
    }
    const writes = new URL(request.url).pathname.endsWith("/write");
    const deadline = AbortSignal.any([
      request.signal,
      AbortSignal.timeout(15000),
    ]);
    let input: unknown;
    const bodyDeadline = AbortSignal.any([deadline, AbortSignal.timeout(2000)]);
    try {
      input = await read(request.body, writes ? 1048576 : 8192, bodyDeadline);
    } catch {
      return json({
        error: bodyDeadline.aborted
          ? "The request took too long."
          : "Use a bounded JSON task request.",
      }, bodyDeadline.aborted ? 408 : 400);
    }
    if (
      !object(input) || Object.keys(input).sort().join(",") !== "action,body" ||
      !(writes
        ? writeInputValid(input.action, input.body)
        : inputValid(input.action, input.body))
    ) {
      return json({
        error: "Use a supported task operation on its matching route.",
      }, 400);
    }
    const action = input.action as string,
      body = input.body as Record<string, unknown>;
    const hex = raw[2],
      id = hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) +
        "-" + hex.slice(16, 20) + "-" + hex.slice(20);
    const hash = Array.from(
      new Uint8Array(
        await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw[1])),
      ),
    ).map((b) => b.toString(16).padStart(2, "0")).join("");
    try {
      const result = await send(
        new Request(
          origin +
            (writes
              ? "/rest/v1/rpc/taskfold_automation_write"
              : action === "projects" || action === "sections"
              ? "/rest/v1/rpc/taskfold_automation_destinations"
              : "/rest/v1/rpc/taskfold_automation_read"),
          {
            method: "POST",
            redirect: "error",
            signal: deadline,
            headers: {
              "Content-Type": "application/json",
              apikey: config.serviceKey,
              Authorization: "Bearer " + config.serviceKey,
            },
            body: JSON.stringify({
              _key: id,
              _hash: hash,
              _action: action,
              _body: body,
            }),
          },
        ),
      );
      const value = await read(result.body, 1048576, deadline);
      if (!result.ok) {
        const codes: Record<string, [number, string]> = {
          "28000": [401, "This task key is unavailable."],
          "42501": [403, "This key does not allow that action."],
          "22023": [400, "Check the task request."],
          "PT404": [404, "Task or project is unavailable."],
          "PT409": [409, "Review this request before trying again."],
          "PT413": [
            413,
            action === "get"
              ? "That task is too large for automation. Open it in Taskfold."
              : "Request a smaller task page.",
          ],
          "PT429": [429, "Automation request limit reached."],
        };
        const [status, message] = codes[
          object(value) && typeof value.code === "string" ? value.code : ""
        ] ?? [503, "Task operations are temporarily unavailable."];
        return json({ error: message }, status);
      }
      return json(
        writes
          ? writeProjection(value, action, body)
          : projection(value, action, body),
      );
    } catch {
      return json(
        { error: "Task operations are temporarily unavailable." },
        503,
      );
    }
  };
}

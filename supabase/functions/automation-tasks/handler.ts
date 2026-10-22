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
];
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
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
  return Object.fromEntries(fields.map((k) => [k, value[k]]));
}
function inputValid(
  action: unknown,
  body: unknown,
): body is Record<string, unknown> {
  if (!object(body)) return false;
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
function projection(
  value: unknown,
  action: string,
  body: Record<string, unknown>,
) {
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
export function createHandler(config: Config, dependencies: Dependencies = {}) {
  const send = dependencies.send ?? fetch;
  return async (request: Request): Promise<Response> => {
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
    const deadline = AbortSignal.any([
      request.signal,
      AbortSignal.timeout(15000),
    ]);
    let input: unknown;
    const bodyDeadline = AbortSignal.any([deadline, AbortSignal.timeout(2000)]);
    try {
      input = await read(request.body, 8192, bodyDeadline);
    } catch {
      return json({
        error: bodyDeadline.aborted
          ? "The request took too long."
          : "Use a bounded JSON task request.",
      }, bodyDeadline.aborted ? 408 : 400);
    }
    if (
      !object(input) || Object.keys(input).sort().join(",") !== "action,body" ||
      !inputValid(input.action, input.body)
    ) return json({ error: "Use a supported task read." }, 400);
    const action = input.action as string, body = input.body;
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
        new Request(origin + "/rest/v1/rpc/taskfold_automation_read", {
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
        }),
      );
      const value = await read(result.body, 256000, deadline);
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
      return json(projection(value, action, body));
    } catch {
      return json(
        { error: "Task operations are temporarily unavailable." },
        503,
      );
    }
  };
}

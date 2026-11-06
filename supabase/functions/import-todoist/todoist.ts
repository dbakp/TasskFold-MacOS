// Current unified Todoist API. No API tokens, task text, or attachments are logged.
export type Row = Record<string, any>;
export type SourceItem = {
  source_id: string;
  record: Row;
  subtask_count?: number;
  comment_count?: number;
};
export type Bundle = {
  version?: number;
  capabilities?: string[];
  projects: SourceItem[];
  sections: SourceItem[];
  labels: SourceItem[];
  tasks: SourceItem[];
};
export type Snapshot = {
  account: string;
  projects: Row[];
  sections: Row[];
  labels: Row[];
  tasks: Row[];
  comments: Map<string, Row[]>;
};
export class ImportError extends Error {
  constructor(message: string, public status = 502) {
    super(message);
  }
}
const colors: Record<string, string> = {
  berry_red: "#b8256f",
  red: "#db4035",
  orange: "#ff9933",
  yellow: "#fad000",
  olive_green: "#afb83b",
  lime_green: "#7ecc49",
  green: "#299438",
  mint_green: "#6accbc",
  teal: "#158fad",
  sky_blue: "#14aaf5",
  light_blue: "#96c3eb",
  blue: "#4073ff",
  grape: "#884dff",
  violet: "#af38eb",
  lavender: "#eb96eb",
  magenta: "#e05194",
  salmon: "#ff8d85",
  charcoal: "#808080",
  grey: "#b8b8b8",
  taupe: "#ccac93",
};
export const color = (name: unknown): string =>
  colors[String(name)] ?? "#808080";
export async function stableID(
  user: string,
  account: string,
  kind: string,
  source: string,
): Promise<string> {
  const bytes = new Uint8Array(
    await crypto.subtle.digest(
      "SHA-256",
      new TextEncoder().encode(
        JSON.stringify(["todoist", user, account, kind, source]),
      ),
    ),
  );
  bytes[6] = (bytes[6] & 15) | 80;
  bytes[8] = (bytes[8] & 63) | 128;
  const h = Array.from(
    bytes.slice(0, 16),
    (x) => x.toString(16).padStart(2, "0"),
  ).join("");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${
    h.slice(16, 20)
  }-${h.slice(20)}`;
}
export class TodoistClient {
  constructor(
    private token: string,
    private fetcher: typeof fetch = fetch,
    private sleep: (ms: number) => Promise<void> = (ms) =>
      new Promise((resolve) => setTimeout(resolve, ms)),
  ) {}
  async get(path: string, query: Record<string, string> = {}): Promise<any> {
    const url = new URL(`https://api.todoist.com/api/v1/${path}`);
    for (const [key, value] of Object.entries(query)) {
      url.searchParams.set(key, value);
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      let response: Response;
      try {
        response = await this.fetcher(url, {
          headers: { Authorization: `Bearer ${this.token}` },
          signal: AbortSignal.timeout(20000),
        });
      } catch {
        if (attempt === 3) {
          throw new ImportError(
            "Todoist could not be reached. Nothing has been imported. Try again.",
          );
        }
        await this.sleep(250 * (2 ** attempt));
        continue;
      }
      if (response.ok) {
        try {
          return await response.json();
        } catch {
          throw new ImportError(
            "Todoist returned an invalid response. Nothing has been imported.",
          );
        }
      }
      if (response.status === 401 || response.status === 403) {
        throw new ImportError(
          "Todoist rejected this API token. Check the token and its permissions.",
          400,
        );
      }
      if (response.status === 429 || response.status >= 500) {
        if (attempt < 3) {
          const after = response.headers.get("Retry-After");
          const seconds = after ? Number(after) : NaN;
          const wait = Number.isFinite(seconds)
            ? seconds * 1000
            : after
            ? Date.parse(after) - Date.now()
            : 250 * (2 ** attempt);
          if (wait <= 10000) {
            await this.sleep(Math.max(0, wait));
            continue;
          }
        }
        throw new ImportError(
          "Todoist is busy or rate limited. Nothing has been imported. Try again later.",
          503,
        );
      }
      throw new ImportError(
        `Todoist could not provide ${path} (HTTP ${response.status}). Nothing has been imported.`,
      );
    }
    throw new ImportError("Todoist could not be reached.");
  }
  async all(path: string, query: Record<string, string> = {}): Promise<Row[]> {
    const result: Row[] = [];
    const cursors = new Set<string>();
    const ids = new Set<string>();
    let cursor: string | null = null;
    do {
      const page = await this.get(path, {
        ...query,
        limit: "200",
        ...(cursor ? { cursor } : {}),
      });
      if (
        !Array.isArray(page?.results) ||
        (page.next_cursor != null && typeof page.next_cursor !== "string")
      ) {
        throw new ImportError(
          `Todoist returned invalid pagination for ${path}.`,
        );
      }
      for (const row of page.results) {
        if (!row || typeof row.id !== "string" || !row.id) {
          throw new ImportError(`Todoist returned an invalid ${path} record.`);
        }
        if (!ids.has(row.id) && !row.is_deleted && !row.is_archived) {
          result.push(row);
          ids.add(row.id);
        }
      }
      cursor = page.next_cursor || null;
      if (cursor && cursors.has(cursor)) {
        throw new ImportError(
          "Todoist repeated a pagination cursor. Nothing has been imported.",
        );
      }
      if (cursor) cursors.add(cursor);
      if (result.length > 20000 || cursors.size > 500) {
        throw new ImportError(
          "This import exceeds the supported size. Nothing has been imported.",
          413,
        );
      }
    } while (cursor);
    return result;
  }
  async snapshot(
    progress: (message: string) => void = () => {},
  ): Promise<Snapshot> {
    const user = await this.get("user");
    if (typeof user?.id !== "string" && typeof user?.id !== "number") {
      throw new ImportError("Todoist did not return an account identity.");
    }
    progress("Reading projects, sections, labels and tasks…");
    const [projects, sections, labels, tasks] = await Promise.all(
      ["projects", "sections", "labels", "tasks"].map((path) => this.all(path)),
    );
    const comments = new Map<string, Row[]>();
    // Bounded workers, including comments on nested children. A failed read aborts the
    // whole snapshot; partial data never looks like a successful import.
    let index = 0;
    await Promise.all(
      Array.from({ length: Math.min(3, tasks.length) }, async () => {
        while (index < tasks.length) {
          const task = tasks[index++];
          comments.set(
            task.id,
            await this.all("comments", { task_id: task.id }),
          );
        }
      }),
    );
    progress("Preparing a complete import preview…");
    return {
      account: String(user.id),
      projects,
      sections,
      labels,
      tasks,
      comments,
    };
  }
}
function dateOnly(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return null;
  }
  const d = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(d.valueOf()) && d.toISOString().slice(0, 10) === value
    ? value
    : null;
}
export function planning(task: Row, warnings: Set<string>): Row {
  const fields: Row = {
    due_date: null,
    due_time: null,
    time_zone: null,
    scheduled_at: null,
    deadline_date: null,
    duration_minutes: null,
    is_recurring: false,
    recurrence_pattern: null,
  };
  if (task.due?.date) {
    const value = String(task.due.date);
    if (dateOnly(value)) fields.due_date = value;
    else if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) {
      if (/(?:Z|[+-]\d{2}:\d{2})$/.test(value)) {
        try {
          const instant = new Date(value);
          const parts = new Intl.DateTimeFormat("en-CA", {
            timeZone: task.due.timezone ?? "UTC",
            year: "numeric",
            month: "2-digit",
            day: "2-digit",
            hour: "2-digit",
            minute: "2-digit",
            hourCycle: "h23",
          }).formatToParts(instant);
          const p = Object.fromEntries(parts.map((x) => [x.type, x.value]));
          fields.due_date = `${p.year}-${p.month}-${p.day}`;
          fields.due_time = `${p.hour}:${p.minute}`;
          fields.time_zone = task.due.timezone ?? "UTC";
          fields.scheduled_at = instant.toISOString();
        } catch {
          warnings.add(
            "Some fixed-time dates could not be interpreted. Their originals are retained in source metadata.",
          );
        }
      } else if (
        dateOnly(value.slice(0, 10)) && Number(value.slice(11, 13)) < 24 &&
        Number(value.slice(14, 16)) < 60
      ) {
        fields.due_date = value.slice(0, 10);
        fields.due_time = value.slice(11, 16);
      } else {warnings.add(
          "Some due dates could not be interpreted. Their originals are retained in source metadata.",
        );}
    } else {warnings.add(
        "Some due dates could not be interpreted. Their originals are retained in source metadata.",
      );}
    if (task.due.is_recurring) {
      const expression = String(task.due.string ?? "").trim().toLowerCase();
      const basic = expression.match(/^every (?:(\d+) )?(day|week|month)s?$/) ??
        expression.match(/^(daily|weekly|monthly)$/);
      const weekday = expression.match(
        /^every (sunday|monday|tuesday|wednesday|thursday|friday|saturday)$/,
      );
      if (basic && fields.due_date) {
        const type = basic.length === 2
          ? ({ daily: "daily", weekly: "weekly", monthly: "monthly" } as Row)[
            basic[1]
          ]
          : `${basic[2]}ly`.replace("dayly", "daily");
        fields.recurrence_pattern = {
          type,
          interval: Math.max(1, Number(basic.length === 2 ? 1 : basic[1] ?? 1)),
        };
        fields.is_recurring = true;
      } else if (weekday && fields.due_date) {
        fields.recurrence_pattern = {
          type: "weekly",
          interval: 1,
          daysOfWeek: [
            [
              "sunday",
              "monday",
              "tuesday",
              "wednesday",
              "thursday",
              "friday",
              "saturday",
            ].indexOf(weekday[1]),
          ],
        };
        fields.is_recurring = true;
      } else {warnings.add(
          "Some recurrence rules are not yet supported. Their next date is imported, their original rule is retained, and they will not repeat automatically.",
        );}
    }
  }
  if (task.deadline?.date) {
    fields.deadline_date = dateOnly(task.deadline.date);
    if (!fields.deadline_date) {
      warnings.add(
        "Some deadlines could not be interpreted. Their originals are retained.",
      );
    }
  }
  if (task.duration) {
    const minutes = Number(task.duration.amount) *
      (task.duration.unit === "minute"
        ? 1
        : task.duration.unit === "day"
        ? 1440
        : NaN);
    if (Number.isInteger(minutes) && minutes > 0 && minutes <= 10080) {
      fields.duration_minutes = minutes;
    } else {warnings.add(
        "Some durations exceed the supported range or use an unknown unit. Their originals are retained.",
      );}
  }
  return fields;
}
export async function prepare(snapshot: Snapshot, user: string) {
  const bundle: Bundle = { projects: [], sections: [], labels: [], tasks: [] };
  const warnings = new Set<string>([
    "Imports include active tasks and their comments. Archived projects and completed task history are not included.",
    "Todoist reminders, filters, collaborators, activity history and notification rules are not imported.",
    "Imports made by older Taskfold versions have no source-ID mapping. This import may create another copy of that data; names alone cannot safely identify it.",
  ]);
  const projects = new Map(snapshot.projects.map((p) => [p.id, p]));
  const sections = new Map(snapshot.sections.map((s) => [s.id, s]));
  const taskMap = new Map(snapshot.tasks.map((t) => [t.id, t]));
  const hasHeadings = snapshot.tasks.some((t) =>
    typeof t.content === "string" && t.content.startsWith("* ")
  );
  const projectIDs = new Map<string, string>();
  const sectionIDs = new Map<string, string>();
  for (const project of snapshot.projects) {
    if (project.inbox_project) continue;
    const id = await stableID(user, snapshot.account, "projects", project.id);
    projectIDs.set(project.id, id);
    bundle.projects.push({
      source_id: project.id,
      record: {
        id,
        name: project.name,
        description: project.description ?? "",
        color: color(project.color),
        order_index: project.child_order ?? 0,
        source_metadata: {
          provider: "todoist",
          account: snapshot.account,
          original: project,
        },
      },
    });
    if (project.parent_id) {
      warnings.add(
        "Nested projects are imported as separate projects. Their original parent links are retained.",
      );
    }
  }
  for (const section of snapshot.sections) {
    const project = projectIDs.get(section.project_id);
    if (!project) {
      warnings.add(
        "Sections without an active project are omitted. Their original links are retained on tasks.",
      );
      continue;
    }
    const id = await stableID(user, snapshot.account, "sections", section.id);
    sectionIDs.set(section.id, id);
    bundle.sections.push({
      source_id: section.id,
      record: {
        id,
        project_id: project,
        name: section.name,
        order_index: section.section_order ?? section.order ?? 0,
      },
    });
  }
  const labelNames = new Set(snapshot.labels.map((l) => String(l.name)));
  const labels = [...snapshot.labels];
  for (const task of snapshot.tasks) {
    for (const name of task.labels ?? []) {
      if (!labelNames.has(name)) {
        labelNames.add(name);
        labels.push({ id: `shared:${name}`, name, color: "grey" });
      }
    }
  }
  for (const label of labels) {
    bundle.labels.push({
      source_id: label.id,
      record: {
        id: await stableID(user, snapshot.account, "labels", label.id),
        name: label.name,
        color: color(label.color),
      },
    });
  }
  const children = new Map<string, Row[]>();
  const roots: Row[] = [];
  for (const task of snapshot.tasks) {
    const seen = new Set([task.id]);
    let parent = task.parent_id;
    while (parent && taskMap.has(parent)) {
      if (seen.has(parent)) {
        throw new ImportError(
          "Todoist returned a cyclic task hierarchy. Nothing has been imported.",
        );
      }
      seen.add(parent);
      if (hasHeadings && seen.size > 33) {
        throw new ImportError(
          "Heading task nesting exceeds this Taskfold version. Nothing has been imported.",
          413,
        );
      }
      parent = taskMap.get(parent)?.parent_id;
    }
    if (task.parent_id && taskMap.has(task.parent_id)) {
      const group = children.get(task.parent_id) ?? [];
      group.push(task);
      children.set(task.parent_id, group);
    } else {
      roots.push(task);
      if (task.parent_id) {
        warnings.add(
          "Children whose parent is unavailable are imported as standalone tasks with their original parent ID retained.",
        );
      }
    }
  }
  let rootHeadings = 0, nestedHeadings = 0;
  let allComments = 0;
  let attachments = 0;
  async function taskRecord(task: Row, depth = 0): Promise<Row> {
    if (depth > 100) {
      throw new ImportError(
        "Todoist task nesting exceeds the supported limit. Nothing has been imported.",
        413,
      );
    }
    const content = String(task.content ?? "");
    const heading = content.startsWith("* ");
    const title = heading ? content.slice(2) : content;
    if (heading && !title.trim()) {
      throw new ImportError(
        "A Todoist heading has no title. Review it in Todoist before importing.",
        422,
      );
    }
    if (heading) {
      if (depth === 0) rootHeadings++;
      else nestedHeadings++;
      if (task.checked || task.completed_at) {
        warnings.add(
          "Some Todoist headings carried a completed state. Imported headings stay open; their original state is retained in source metadata.",
        );
      }
    }
    const comments: Row[] = [];
    const files: Row[] = [];
    for (const comment of snapshot.comments.get(task.id) ?? []) {
      allComments++;
      comments.push({
        id: await stableID(user, snapshot.account, "comments", comment.id),
        text: comment.content ?? "",
        created_at: comment.posted_at,
        source_author: comment.posted_uid,
        source_metadata: { provider: "todoist", original: comment },
      });
      const file = comment.file_attachment ?? comment.attachment;
      if (file?.file_url) {
        try {
          const url = new URL(file.file_url);
          if (url.protocol !== "https:") throw new Error();
          files.push({
            id: await stableID(
              user,
              snapshot.account,
              "attachments",
              comment.id,
            ),
            url: url.href,
            name: file.file_name ?? "Attachment",
            type: file.file_type ?? "application/octet-stream",
            source: "todoist",
            external: true,
          });
          attachments++;
        } catch {
          warnings.add(
            "Some attachment links are invalid and are retained only in source metadata.",
          );
        }
      }
    }
    if (task.responsible_uid) {
      warnings.add(
        "Todoist assignees are retained in source metadata. Invite and assign collaborators in Taskfold after import.",
      );
    }
    const nested = await Promise.all(
      (children.get(task.id) ?? []).sort((a, b) =>
        (a.child_order ?? 0) - (b.child_order ?? 0)
      ).map((t) => taskRecord(t, depth + 1)),
    );
    if (depth > 1) {
      warnings.add(
        "Deeply nested children are retained. Some editors currently show only the first level.",
      );
    }
    const project = projects.get(task.project_id);
    if (!project) {
      warnings.add(
        "Tasks whose project is unavailable are imported into Inbox. Their original project IDs are retained.",
      );
    }
    const section = sections.get(task.section_id);
    return {
      id: await stableID(
        user,
        snapshot.account,
        depth ? "subtasks" : "tasks",
        task.id,
      ),
      title,
      ...(heading ? { is_heading: true } : {}),
      description: task.description ?? "",
      completed: heading ? false : !!task.checked,
      priority: 5 - Math.max(1, Math.min(4, Number(task.priority) || 1)),
      ...planning(task, warnings),
      project_id: projectIDs.get(task.project_id) ?? null,
      section_id: section && section.project_id === task.project_id
        ? sectionIDs.get(task.section_id) ?? null
        : null,
      labels: task.labels ?? [],
      subtasks: nested,
      comments,
      attachments: files,
      created_at: task.added_at ?? null,
      completed_at: heading ? null : task.completed_at ?? null,
      source_metadata: {
        provider: "todoist",
        account: snapshot.account,
        original: task,
      },
    };
  }
  function count(row: Row, key: string): number {
    return (key === "subtasks" ? row.subtasks.length : row.comments.length) +
      (row.subtasks as Row[]).reduce((n, child) => n + count(child, key), 0);
  }
  for (const task of roots) {
    const record = await taskRecord(task);
    bundle.tasks.push({
      source_id: task.id,
      record,
      subtask_count: count(record, "subtasks"),
      comment_count: count(record, "comments"),
    });
  }
  if (attachments) {
    warnings.add(
      "Attachments are preserved as original HTTPS links. Todoist may expire or revoke those links; download important files before leaving Todoist.",
    );
  }
  if (rootHeadings + nestedHeadings > 0) {
    bundle.version = 2;
    bundle.capabilities = ["task_headings"];
    warnings.add(
      "Previously imported items keep their existing Taskfold type and edits. This import does not convert them automatically.",
    );
    warnings.add(
      "Todoist’s leading asterisk and space become explicit Taskfold headings. Heading notes, dates, files and descendants are retained; headings stay open. The original titles remain in source metadata.",
    );
  }
  const headings = {
    version: 1,
    roots: rootHeadings,
    subtasks: nestedHeadings,
    available: false,
  };
  const counts = {
    projects: bundle.projects.length,
    sections: bundle.sections.length,
    labels: bundle.labels.length,
    tasks: bundle.tasks.length,
    subtasks: snapshot.tasks.length - bundle.tasks.length,
    comments: allComments,
  };
  const samples = {
    projects: bundle.projects.slice(0, 5).map((p) => ({
      name: p.record.name,
      color: p.record.color,
    })),
    sections: bundle.sections.slice(0, 5).map((s) => ({
      name: s.record.name,
      projectName:
        bundle.projects.find((p) => p.record.id === s.record.project_id)?.record
          .name ?? "",
    })),
    tasks: bundle.tasks.slice(0, 5).map((t) => ({
      title: t.record.title,
      completed: t.record.completed,
      hasDescription: !!t.record.description,
      hasDueDate: !!t.record.due_date,
      labelCount: t.record.labels.length,
    })),
  };
  return {
    bundle,
    preview: {
      preview: true,
      sourceAccount: snapshot.account,
      counts,
      headings,
      samples,
      warnings: [...warnings],
    },
  };
}

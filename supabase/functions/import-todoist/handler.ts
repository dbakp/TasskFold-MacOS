import { ImportError, prepare, TodoistClient } from "./todoist.ts";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
type Config = { url: string; key: string; headingsEnabled?: boolean };
/** The legitimate request is a Todoist token plus small approval fields. */
export const MAX_BODY_BYTES = 1_000_000;
export const ADMISSION_WINDOW_MS = 10 * 60_000;
export const ADMISSION_MAX_REQUESTS = 6;
const ADMISSION_MAX_USERS = 2048;
// deno-lint-ignore no-explicit-any
async function readBounded(req: Request): Promise<any> {
  const reader = req.body?.getReader();
  if (!reader) throw new Error("empty");
  const parts: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const item = await reader.read();
    if (item.done) break;
    size += item.value.length;
    if (size > MAX_BODY_BYTES) {
      await reader.cancel().catch(() => {});
      throw new ImportError("The import request is too large.", 413);
    }
    parts.push(item.value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}
export function createHandler(
  config: Config,
  fetcher: typeof fetch = fetch,
  clock: () => number = Date.now,
) {
  // Best-effort per-isolate admission: one import per user at a time and a
  // sliding request budget. Todoist and the database remain the durable limits.
  const admissions = new Map<string, { at: number[]; active: number }>();
  const admit = (user: string): number => {
    const now = clock();
    for (const [id, entry] of admissions) {
      entry.at = entry.at.filter((t) => now - t < ADMISSION_WINDOW_MS);
      if (!entry.active && !entry.at.length) admissions.delete(id);
    }
    const entry = admissions.get(user) ?? { at: [], active: 0 };
    if (entry.active >= 1 || entry.at.length >= ADMISSION_MAX_REQUESTS) {
      const wait = entry.active >= 1
        ? 5_000
        : ADMISSION_WINDOW_MS - (now - entry.at[0]);
      return Math.max(1, Math.ceil(wait / 1000));
    }
    if (!admissions.has(user) && admissions.size >= ADMISSION_MAX_USERS) {
      return 30;
    }
    entry.at.push(now);
    entry.active++;
    admissions.set(user, entry);
    return 0;
  };
  const release = (user: string) => {
    const entry = admissions.get(user);
    if (entry) entry.active = Math.max(0, entry.active - 1);
  };
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return new Response(null, { headers: cors });
    if (req.method !== "POST") {
      return json({ error: "Use POST to preview or import." }, 405);
    }
    const authorization = req.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) {
      return json({ error: "Sign in to import from Todoist." }, 401);
    }
    if (Number(req.headers.get("Content-Length") ?? 0) > MAX_BODY_BYTES) {
      void req.body?.cancel().catch(() => {});
      return json({ error: "The import request is too large." }, 413);
    }
    let admitted: string | null = null, streaming = false;
    try {
      const auth = await fetcher(`${config.url}/auth/v1/user`, {
        headers: { apikey: config.key, Authorization: authorization },
        signal: AbortSignal.timeout(15000),
      });
      if (!auth.ok) {
        return json(
          { error: "Your Taskfold session expired. Sign in again." },
          401,
        );
      }
      const user = await auth.json();
      if (typeof user?.id !== "string") {
        return json({ error: "Sign in to import from Todoist." }, 401);
      }
      const wait = admit(user.id);
      if (wait) {
        void req.body?.cancel().catch(() => {});
        const limited = json(
          { error: "Too many import requests. Try again shortly." },
          429,
        );
        limited.headers.set("Retry-After", String(wait));
        return limited;
      }
      admitted = user.id;
      let body;
      try {
        body = await readBounded(req);
      } catch (error) {
        if (error instanceof ImportError) {
          return json({ error: error.message }, error.status);
        }
        return json({ error: "Invalid request body." }, 400);
      }
      if (
        typeof body?.userToken !== "string" ||
        body.userToken.trim().length < 16 || body.userToken.length > 512
      ) return json({ error: "Enter your Todoist API token." }, 400);
      const run = async (progress: (message: string) => void) => {
        const client = new TodoistClient(body.userToken.trim(), fetcher);
        const snapshot = await client.snapshot(progress);
        if (body.sourceAccount && body.sourceAccount !== snapshot.account) {
          throw new ImportError(
            "The Todoist account changed. Preview the import again.",
            409,
          );
        }
        const prepared = await prepare(snapshot, user.id);
        const supportsHeadings = Array.isArray(body.capabilities) &&
          body.capabilities.length === 1 &&
          body.capabilities[0] === "task_headings";
        prepared.preview.headings.available = config.headingsEnabled === true &&
          supportsHeadings;
        if (
          prepared.bundle.version === 2 && !prepared.preview.headings.available
        ) {
          prepared.preview.warnings.push(
            "Heading import is not available in this app or service yet. Your Todoist data is unchanged; use a supported Taskfold version after heading support is enabled.",
          );
        }
        if (body.preview === true) return prepared.preview;
        if (
          prepared.bundle.version === 2 && !prepared.preview.headings.available
        ) {
          throw new ImportError(
            "This import contains headings. Preview it in a supported Taskfold app after heading import is enabled. Nothing was saved.",
            409,
          );
        }
        if (
          prepared.bundle.version === 2 &&
          (!body.headingApproval ||
            body.headingApproval.roots !== prepared.preview.headings.roots ||
            body.headingApproval.subtasks !==
              prepared.preview.headings.subtasks)
        ) {
          throw new ImportError(
            "The source headings changed. Preview the import again before saving. Nothing was saved.",
            409,
          );
        }
        progress("Saving projects, sections, labels and tasks together…");
        let response: Response;
        try {
          response = await fetcher(
            `${config.url}/rest/v1/rpc/taskfold_import_todoist`,
            {
              method: "POST",
              headers: {
                apikey: config.key,
                Authorization: authorization,
                "Content-Type": "application/json",
              },
              body: JSON.stringify({
                _account: snapshot.account,
                _bundle: prepared.bundle,
              }),
              signal: AbortSignal.timeout(45000),
            },
          );
        } catch {
          throw new ImportError(
            "The connection was lost while saving. Preview and retry: source IDs prevent duplicate imports.",
            503,
          );
        }
        if (!response.ok) {
          throw new ImportError(
            "Taskfold could not save the import. No partial changes were saved. Retry, or contact support if this continues.",
            503,
          );
        }
        const result = await response.json();
        if (
          result?.success !== true ||
          prepared.bundle.version === 2 &&
            (result.formatVersion !== 2 ||
              JSON.stringify(result.capabilities) !== '["task_headings"]')
        ) {
          throw new ImportError(
            "Taskfold did not confirm the import. Retry safely using the same account.",
            503,
          );
        }
        return {
          ...result,
          warnings: prepared.preview.warnings,
          sourceAccount: snapshot.account,
        };
      };
      // Existing web builds use SSE by default. New native/web clients explicitly request JSON.
      if (body.stream !== false && body.preview !== true) {
        const stream = new ReadableStream({
          async start(controller) {
            const encoder = new TextEncoder();
            const send = (value: unknown) =>
              controller.enqueue(
                encoder.encode(`data: ${JSON.stringify(value)}\n\n`),
              );
            try {
              const result = await run((message) => send({ message }));
              send({ message: "completed", ...result });
            } catch (error) {
              send({
                message: "error",
                error: error instanceof ImportError
                  ? error.message
                  : "The import could not finish. Retry safely using the same account.",
              });
            } finally {
              if (admitted) release(admitted);
              controller.close();
            }
          },
        });
        streaming = true;
        return new Response(stream, {
          headers: {
            ...cors,
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
          },
        });
      }
      return json(await run(() => {}));
    } catch (error) {
      return json({
        error: error instanceof ImportError
          ? error.message
          : "The import could not finish. Retry safely using the same account.",
      }, error instanceof ImportError ? error.status : 502);
    } finally {
      if (admitted && !streaming) release(admitted);
    }
  };
}

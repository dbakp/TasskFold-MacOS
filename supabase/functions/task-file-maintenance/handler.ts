// Disabled candidate. Paths originate only in leased SQL claims, never callers.
import {
  boundTaskFileWork as bounded,
  readTaskFileBytes as read,
  taskFileDigest as hash,
  taskFileFields as exact,
  taskFileIdentity as id,
  taskFileObject as row,
  taskFileSHA as sha,
  taskFileSize as size,
} from "../task-files/handler.ts";
type Config = {
  url: string;
  serviceKey: string;
  maintenanceKey: string;
  enabled?: boolean;
  timeoutMilliseconds?: number;
};
type Dependencies = { send?: (request: Request) => Promise<Response> };
const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
export function createTaskFileMaintenanceHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  return async (request: Request) => {
    if (request.method !== "POST" || new URL(request.url).search) {
      return json({ code: "invalid" }, 400);
    }
    if (
      config.enabled !== true || !config.serviceKey ||
      config.maintenanceKey.length < 32 || config.maintenanceKey.length > 256
    ) return json({ code: "disabled" }, 503);
    const presented = request.headers.get("X-Taskfold-File-Maintenance") ?? "";
    if (presented.length > 256) return json({ code: "unauthorized" }, 401);
    const [a, b] = await Promise.all([
      hash(new TextEncoder().encode(presented)),
      hash(new TextEncoder().encode(config.maintenanceKey)),
    ]);
    let difference = 0;
    for (let i = 0; i < a.length; i++) {
      difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
    }
    if (difference) return json({ code: "unauthorized" }, 401);
    const abort = new AbortController(),
      timer = setTimeout(
        () => abort.abort(),
        Math.min(55000, Math.max(10, config.timeoutMilliseconds ?? 45000)),
      );
    const signal = abort.signal;
    try {
      const origin = new URL(config.url);
      if (
        origin.protocol !== "https:" || origin.username || origin.password ||
        origin.search || origin.hash || origin.pathname !== "/"
      ) throw Error("configuration");
      if (request.body) {
        const body = await read(request.body, 16, signal);
        if (body.length) {
          const value = row(JSON.parse(new TextDecoder().decode(body)));
          exact(value, []);
        }
      }
      const headers = {
        "Authorization": `Bearer ${config.serviceKey}`,
        "apikey": config.serviceKey,
      };
      const call = async (path: string, method: string, body?: unknown) =>
        await bounded(
          send(
            new Request(new URL(path, origin), {
              method,
              headers: {
                ...headers,
                ...(body === undefined
                  ? {}
                  : { "Content-Type": "application/json" }),
              },
              body: body === undefined ? undefined : JSON.stringify(body),
              redirect: "error",
              signal,
            }),
          ),
          signal,
        );
      const rpc = async (action: string, body: unknown) => {
        const response = await call(
          "/rest/v1/rpc/taskfold_task_file_maintenance",
          "POST",
          { _action: action, _body: body },
        );
        if (!response.ok) throw Error("rpc");
        return row(
          JSON.parse(
            new TextDecoder().decode(await read(response.body, 65536, signal)),
          ),
        );
      };
      const items = async (action: "probe" | "claim") => {
        const result = await rpc(action, {});
        exact(result, ["protocol", "items"]);
        if (
          result.protocol !== 1 || !Array.isArray(result.items) ||
          result.items.length > 25
        ) throw Error("contract");
        const seen = new Set<string>();
        return result.items.map((value) => {
          const item = row(value);
          exact(item, [
            "operation_id",
            "object_name",
            "sha256",
            "byte_count",
            action === "probe" ? "ticket_id" : "token",
          ]);
          if (
            !id(item.operation_id) ||
            !id(item[action === "probe" ? "ticket_id" : "token"]) ||
            !sha(item.sha256) || !size(item.byte_count) ||
            typeof item.object_name !== "string"
          ) throw Error("contract");
          const parts = item.object_name.split("/");
          if (
            parts.length !== 4 || parts[0] !== "team-task-files" ||
            parts[1] !== "v1" || parts[2] !== item.operation_id ||
            !id(parts[3]) || seen.has(item.operation_id)
          ) throw Error("contract");
          seen.add(item.operation_id);
          return item;
        });
      };
      const object = async (item: Record<string, unknown>) => {
        const response = await call(
          "/storage/v1/object/authenticated/task-attachments/" +
            item.object_name,
          "GET",
        );
        if (response.status === 404 || response.status === 400) {
          // Reject arbitrary proxy/tenant/bucket errors; SQL also checks metadata.
          const failure = row(
            JSON.parse(
              new TextDecoder().decode(await read(response.body, 4096, signal)),
            ),
          );
          // Storage v1.87 also wraps NoSuchKey in HTTP 400, carrying the
          // underlying 404 as a string. Neither a generic 400 nor another
          // provider error establishes absence. SQL still checks metadata.
          if (
            failure.code !== "NoSuchKey" ||
            response.status === 400 && failure.statusCode !== "404"
          ) throw Error("unverified absence");
          return false;
        }
        if (response.status !== 200) throw Error("storage");
        const bytes = await read(
          response.body,
          item.byte_count as number,
          signal,
        );
        if (
          bytes.length !== item.byte_count || await hash(bytes) !== item.sha256
        ) throw Error("bytes");
        return true;
      };
      const counts = {
        probed: 0,
        recovered: 0,
        claimed: 0,
        purged: 0,
        unresolved: 0,
      };
      for (const item of await items("probe")) {
        counts.probed++;
        try {
          if (!await object(item)) throw Error("writer still unresolved");
          const result = await rpc("reconcile", {
            operation_id: item.operation_id,
            ticket_id: item.ticket_id,
            stored_sha256: item.sha256,
            stored_bytes: item.byte_count,
          });
          exact(result, ["protocol", "settled"]);
          if (result.protocol !== 1 || result.settled !== true) {
            throw Error("unsettled");
          }
          counts.recovered++;
        } catch {
          counts.unresolved++;
        }
      }
      for (const item of await items("claim")) {
        counts.claimed++;
        try {
          if (await object(item)) {
            const deleted = await call(
              "/storage/v1/object/task-attachments",
              "DELETE",
              { prefixes: [item.object_name] },
            );
            if (!deleted.ok) throw Error("delete");
            await read(deleted.body, 16384, signal);
            if (await object(item)) throw Error("still present");
          }
          const result = await rpc("confirm", {
            operation_id: item.operation_id,
            object_name: item.object_name,
            token: item.token,
          });
          exact(result, ["protocol", "purged"]);
          if (result.protocol !== 1 || result.purged !== true) {
            throw Error("unconfirmed");
          }
          counts.purged++;
        } catch {
          counts.unresolved++;
        }
      }
      signal.throwIfAborted();
      return json(counts);
    } catch {
      return json({ code: "retry" }, 503);
    } finally {
      clearTimeout(timer);
    }
  };
}

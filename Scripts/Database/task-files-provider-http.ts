// Synthetic Auth/RPC adapter; all Storage requests reach the pinned real API.
import { createTaskFilesHandler } from "../../supabase/functions/task-files/handler.ts";
import { createTaskFileMaintenanceHandler } from "../../supabase/functions/task-file-maintenance/handler.ts";
const input = JSON.parse(await new Response(Deno.stdin.readable).text());
if (
  !Number.isInteger(input.port) || input.port < 1 || input.port > 65535 ||
  typeof input.service !== "string"
) throw Error("Owned fixture configuration required");
const send = (request: Request) => {
  const u = new URL(request.url);
  if (
    u.origin !== "https://taskfold-provider-fixture.invalid" ||
    ![
        "/auth/v1/user",
        "/rest/v1/rpc/taskfold_task_file_command",
        "/rest/v1/rpc/taskfold_task_file_maintenance",
      ].includes(u.pathname) && !u.pathname.startsWith("/storage/v1/object/")
  ) throw Error("Unknown owned route");
  return fetch(
    new Request("http://127.0.0.1:" + input.port + u.pathname + u.search, {
      method: request.method,
      headers: request.headers,
      body: request.body,
      signal: request.signal,
      redirect: "error",
    }),
  );
};
const handler = createTaskFilesHandler({
  url: "https://taskfold-provider-fixture.invalid",
  serviceKey: input.service,
  enabled: true,
}, { send });
const maintenance = createTaskFileMaintenanceHandler({
  url: "https://taskfold-provider-fixture.invalid",
  serviceKey: input.service,
  maintenanceKey: "synthetic-maintenance-".repeat(3),
  enabled: true,
}, { send });
Deno.serve(
  {
    hostname: "127.0.0.1",
    port: 0,
    onListen: ({ port }) => console.log(JSON.stringify({ ready: port })),
  },
  (request) => {
    const path = new URL(request.url).pathname;
    if (
      input.workspace === true &&
      (path.startsWith("/rest/v1/") || path === "/auth/v1/user")
    ) {
      return fetch(
        new Request(
          "http://127.0.0.1:" + input.port + "/native" + path +
            new URL(request.url).search,
          {
            method: request.method,
            headers: request.headers,
            body: request.body,
            signal: request.signal,
            redirect: "error",
          },
        ),
      );
    }
    return path === "/maintenance" ? maintenance(request) : handler(request);
  },
);

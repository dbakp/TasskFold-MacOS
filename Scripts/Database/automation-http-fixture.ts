// Local-only acceptance adapter. The production handler retains its fixed HTTPS
// RPC construction; this injected transport maps only those paths to an owned
// loopback PostgreSQL fixture. No hosted URL/config/credential is read.
import { createHandler } from "../../supabase/functions/automation-tasks/handler.ts";
const port = Number(Deno.args[0]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error("Use the owned RPC fixture port");
}
const handler = createHandler({
  url: "https://automation-http-fixture.invalid",
  serviceKey: "synthetic-loopback-service",
  forwardedForMode: "supabase-append-v1",
}, {
  send: async (request) => {
    const path = new URL(request.url).pathname;
    if (
      ![
        "/rest/v1/rpc/taskfold_automation_read",
        "/rest/v1/rpc/taskfold_automation_write",
        "/rest/v1/rpc/taskfold_automation_destinations",
        "/rest/v1/rpc/taskfold_automation_admit",
      ].includes(path)
    ) throw new Error("Unexpected fixture RPC");
    return await fetch(
      new Request("http://127.0.0.1:" + port + path, {
        method: "POST",
        redirect: "error",
        signal: request.signal,
        headers: request.headers,
        body: await request.text(),
      }),
    );
  },
});
Deno.serve({
  hostname: "127.0.0.1",
  port: 0,
  onListen: (address) => console.log(JSON.stringify({ ready: address.port })),
}, handler);

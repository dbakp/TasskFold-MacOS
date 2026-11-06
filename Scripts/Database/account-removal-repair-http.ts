// Reserved loopback bridge. Production handlers run unchanged; no external network permission.
import { createRemovalRepairHandler } from "../../supabase/functions/account-removal-repair/handler.ts";
import { createHandler } from "../../supabase/functions/delete-account/handler.ts";
import { issueProof } from "../../supabase/functions/delete-account/proof.ts";
if (
  Deno.args.length !== 1 || !/^[0-9]{1,5}$/.test(Deno.args[0]) ||
  +Deno.args[0] < 1 || +Deno.args[0] > 65535
) throw Error("loopback port");
const origin = "https://repair.fixture",
  serviceKey = "synthetic-loopback-service",
  maintenanceKey = "synthetic-operator-key-never-in-clients";
const send = async (request: Request) => {
  if (new URL(request.url).origin !== origin) throw Error("fixture origin");
  return await fetch(
    "http://127.0.0.1:" + Deno.args[0] + new URL(request.url).pathname,
    {
      method: request.method,
      headers: request.headers,
      redirect: "error",
      signal: request.signal,
      body: request.method === "GET" ? undefined : await request.arrayBuffer(),
    },
  );
};
const repair = createRemovalRepairHandler({
  url: origin,
  serviceKey,
  maintenanceKey,
  enabled: true,
}, { send });
const status = createHandler({ url: origin, serviceKey }, { send });
Deno.serve({
  hostname: "127.0.0.1",
  port: 0,
  onListen: ({ port }) => console.log(JSON.stringify({ ready: port })),
}, async (request) => {
  const path = new URL(request.url).pathname;
  if (path === "/repair") return await repair(request);
  if (path === "/status") return await status(request);
  if (
    path === "/proof" &&
    request.headers.get("X-Taskfold-Removal-Repair") === maintenanceKey
  ) {
    const { account } = await request.json();
    const proof = await issueProof(account, origin, Date.now(), async (id) => {
      const response = await send(
        new Request(
          origin + "/rest/v1/rpc/taskfold_account_removal_proof_key",
          {
            method: "POST",
            headers: {
              apikey: serviceKey,
              Authorization: "Bearer " + serviceKey,
              "Content-Type": "application/json",
            },
            body: JSON.stringify({ _id: id }),
          },
        ),
      );
      if (!response.ok) throw Error("key");
      return await response.json();
    });
    return Response.json({ proof });
  }
  return new Response(null, { status: 404 });
});

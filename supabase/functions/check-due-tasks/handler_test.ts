import { createHandler, type Config } from "./handler.ts";
const config: Config = { url: "https://backend.test", serviceKey: "service-fixture", cronSecret: "private-cron-fixture", appID: "provider-fixture", providerKey: "private-provider-fixture" };
const request = (secret = config.cronSecret, method = "POST") => new Request("https://worker.test", { method, headers: { "x-cron-secret": secret } });
const assert = (value: boolean, message: string) => { if (!value) throw new Error(message); };
const response = (data: unknown, status = 200) => new Response(JSON.stringify(data), { status });
Deno.test("missing, empty, wrong and oversized secrets reject before transport", async () => {
  let calls = 0;
  const send = async () => { calls++; return response([]); };
  for (const secret of ["", "wrong", "x".repeat(513)]) assert((await createHandler(config, { send })(request(secret))).status === 401, "Unauthorized call accepted");
  assert((await createHandler({ ...config, cronSecret: "" }, { send })(request())).status === 401, "Missing configuration accepted");
  assert(calls === 0, "Unauthorized request accessed data/provider");
});
Deno.test("method and provider configuration failures have no transport", async () => {
  let calls = 0;
  const send = async () => { calls++; return response([]); };
  assert((await createHandler(config, { send })(request(config.cronSecret, "GET"))).status === 405, "GET accepted");
  assert((await createHandler({ ...config, providerKey: "" }, { send })(request())).status === 503, "Missing provider accepted");
  assert(calls === 0, "Invalid request accessed provider");
});
Deno.test("valid no-work cron uses UTC minute and only server credentials", async () => {
  let calls = 0;
  const send = async (req: Request) => {
    calls++; const url = new URL(req.url);
    assert(url.searchParams.get("due_date") === "eq.2026-10-06" && url.searchParams.get("due_time") === "eq.11:45", "Clock model changed");
    assert(req.headers.get("Authorization") === "Bearer service-fixture", "Wrong DB authorization"); return response([]);
  };
  const result = await createHandler(config, { send, now: () => new Date("2026-10-06T11:45:12Z") })(request());
  assert(result.status === 200 && calls === 1, "No-work cron failed");
});
Deno.test("opt-out users never receive a provider request; accepted delivery is marked", async () => {
  let sent = 0, marked = 0;
  const send = async (req: Request) => {
    const url = new URL(req.url);
    if (url.hostname === "onesignal.com") {
      sent++; const payload = await req.json(); assert(payload.include_subscription_ids[0] === "opaque-subscription", "Wrong recipient");
      assert(req.headers.get("Authorization") === "Basic private-provider-fixture", "Wrong provider authorization"); return response({ id: "opaque-provider-result" });
    }
    if (req.method === "PATCH") { marked++; assert(url.searchParams.get("id") === "eq.task-a", "Wrong delivered task marked"); return response(null); }
    if (url.pathname.endsWith("profiles")) return response([{ user_id: "owner-a", onesignal_player_id: "opaque-subscription", preferences: null }, { user_id: "owner-b", onesignal_player_id: "never-contact", preferences: { notifications: { enabled: false } } }]);
    return response([{ id: "task-a", user_id: "owner-a", title: "Private task title" }, { id: "task-b", user_id: "owner-b", title: "Never sent title" }]);
  };
  const result = await createHandler(config, { send })(request()), body = await result.text();
  assert(sent === 1 && marked === 1 && JSON.parse(body).sent === 1, "Recipient filtering failed");
  assert(!body.includes("Private") && !body.includes("opaque") && !body.includes("provider-fixture"), "Response leaked private data");
});
Deno.test("provider rejection stays unmarked and raw errors do not leave the handler", async () => {
  let marked = 0;
  const send = async (req: Request) => {
    if (req.url.includes("onesignal.com")) return response({ error: "PRIVATE TOKEN AND TASK TITLE" }, 500);
    if (req.method === "PATCH") { marked++; return response(null); }
    if (req.url.includes("profiles?")) return response([{ user_id: "owner", onesignal_player_id: "secret-subscription", preferences: null }]);
    return response([{ id: "task", user_id: "owner", title: "Private title" }]);
  };
  const result = await createHandler(config, { send })(request()), body = await result.text();
  assert(marked === 0 && JSON.parse(body).failed === 1 && !body.includes("PRIVATE"), "Rejected provider result mishandled");
  const failure = await createHandler(config, { send: () => { throw new Error("PRIVATE SERVICE CREDENTIAL"); } })(request());
  assert(failure.status === 502 && !(await failure.text()).includes("PRIVATE"), "Exception leaked");
});

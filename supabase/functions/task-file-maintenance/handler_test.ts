import { createTaskFileMaintenanceHandler } from "./handler.ts";
import { taskFileDigest } from "../task-files/handler.ts";
const op = "11111111-1111-4111-8111-111111111111",
  nonce = "22222222-2222-4222-8222-222222222222",
  token = "33333333-3333-4333-8333-333333333333";
const bytes = new TextEncoder().encode("hello"),
  sha = await taskFileDigest(bytes),
  path = `team-task-files/v1/${op}/${nonce}`;
const item = {
  operation_id: op,
  object_name: path,
  sha256: sha,
  byte_count: 5,
};
const key = "test-only-maintenance-key-0123456789";
const response = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), { status });
const assert = (value: unknown, message = "assertion") => {
  if (!value) throw Error(message);
};
function fixture(
  options: {
    probe?: boolean;
    absent?: boolean;
    wrongBytes?: boolean;
    deleteFails?: boolean;
    stillPresent?: boolean;
    confirm?: boolean;
    badPath?: boolean;
    bad404?: boolean;
    hang?: boolean;
  } = {},
) {
  const calls: {
    path: string;
    method: string;
    body: Record<string, unknown> | null;
  }[] = [];
  let deleted = false;
  const handler = createTaskFileMaintenanceHandler({
    url: "https://fixture.invalid",
    serviceKey: "test-only-service",
    maintenanceKey: key,
    enabled: true,
    timeoutMilliseconds: options.hang ? 20 : 1000,
  }, {
    send: async (request) => {
      assert(request.redirect === "error");
      const url = new URL(request.url);
      assert(url.origin === "https://fixture.invalid");
      const body = request.method === "GET" ? null : await request.json();
      calls.push({ path: url.pathname, method: request.method, body });
      if (options.hang) return await new Promise<Response>(() => {});
      if (url.pathname.startsWith("/rest/")) {
        switch (body._action) {
          case "probe":
            return response({
              protocol: 1,
              items: options.probe ? [{ ...item, ticket_id: token }] : [],
            });
          case "claim":
            return response({
              protocol: 1,
              items: options.probe ? [] : [{
                ...item,
                object_name: options.badPath ? "other/" + op : path,
                token,
              }],
            });
          case "reconcile":
            return response({ protocol: 1, settled: true });
          case "confirm":
            return response({ protocol: 1, purged: options.confirm !== false });
        }
      }
      if (request.method === "DELETE") {
        assert(JSON.stringify(body) == JSON.stringify({ prefixes: [path] }));
        deleted = true;
        return response([], options.deleteFails ? 500 : 200);
      }
      assert(
        url.pathname ===
          "/storage/v1/object/authenticated/task-attachments/" + path,
      );
      if (options.absent || deleted && !options.stillPresent) {
        return response(
          { code: options.bad404 ? "NoSuchBucket" : "NoSuchKey" },
          404,
        );
      }
      return new Response(options.wrongBytes ? "wrong" : bytes);
    },
  });
  const run = () =>
    handler(
      new Request("https://worker.invalid", {
        method: "POST",
        headers: { "X-Taskfold-File-Maintenance": key },
        body: "{}",
      }),
    );
  return { run, calls, handler };
}
Deno.test("matching closed object is verified, removed through API, verified absent then confirmed", async () => {
  const f = fixture(), r = await f.run(), body = await r.json();
  assert(r.status === 200 && body.purged === 1);
  assert(
    f.calls.map((x) => x.method).join(",") === "POST,POST,GET,DELETE,GET,POST",
  );
  assert(!JSON.stringify(body).includes(op));
});
Deno.test("absent closed allocation skips deletion but requires SQL confirmation", async () => {
  const f = fixture({ absent: true }), r = await f.run();
  assert((await r.json()).purged === 1);
  assert(!f.calls.some((x) => x.method === "DELETE"));
});
Deno.test("open writer with verified committed bytes reconciles without deleting", async () => {
  const f = fixture({ probe: true }), r = await f.run();
  assert((await r.json()).recovered === 1);
  assert(f.calls.some((x) => x.body?._action === "reconcile"));
  assert(!f.calls.some((x) => x.method === "DELETE"));
});
Deno.test("404 never settles an unresolved writer", async () => {
  const f = fixture({ probe: true, absent: true }), r = await f.run();
  assert((await r.json()).unresolved === 1);
  assert(!f.calls.some((x) => x.body?._action === "reconcile"));
});
for (
  const [name, options] of Object.entries({
    wrongBytes: { wrongBytes: true },
    deleteFailure: { deleteFails: true },
    stillPresent: { stillPresent: true },
    wrong404: { absent: true, bad404: true },
  })
) {
  Deno.test(name + " never confirms cleanup or releases quota", async () => {
    const f = fixture(options), r = await f.run(), body = await r.json();
    assert(body.purged === 0 && body.unresolved === 1);
    assert(!f.calls.some((x) => x.body?._action === "confirm"));
    if (options.wrongBytes) assert(!f.calls.some((x) => x.method === "DELETE"));
  });
}
Deno.test("SQL refusal remains unresolved", async () => {
  const f = fixture({ confirm: false }), r = await f.run(), b = await r.json();
  assert(b.purged === 0 && b.unresolved === 1);
});
Deno.test("foreign path fails whole claim before provider access", async () => {
  const f = fixture({ badPath: true }), r = await f.run();
  assert(r.status === 503);
  assert(f.calls.every((x) => x.path.startsWith("/rest/")));
});
Deno.test("timeout bounds worker without pretending cleanup succeeded", async () => {
  const f = fixture({ hang: true }), r = await f.run();
  assert(r.status === 503);
});
Deno.test("caller cannot choose paths or bypass maintenance secret", async () => {
  const f = fixture();
  for (
    const request of [
      new Request("https://worker.invalid", { method: "POST" }),
      new Request("https://worker.invalid?path=anything", { method: "POST" }),
      new Request("https://worker.invalid", {
        method: "POST",
        headers: { "X-Taskfold-File-Maintenance": key },
        body: '{"object_name":"anything"}',
      }),
    ]
  ) assert((await f.handler(request)).status !== 200);
  assert(f.calls.length === 0);
});
Deno.test("worker disabled by default", async () => {
  const h = createTaskFileMaintenanceHandler({
    url: "https://fixture.invalid",
    serviceKey: "test",
    maintenanceKey: key,
  });
  assert(
    (await h(new Request("https://worker.invalid", { method: "POST" })))
      .status === 503,
  );
});

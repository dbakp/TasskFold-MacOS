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
    absenceStatus?: number;
    absenceBody?: Record<string, unknown>;
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
          options.absenceBody ??
            { code: options.bad404 ? "NoSuchBucket" : "NoSuchKey" },
          options.absenceStatus ?? 404,
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

const wrappedAbsence = {
  statusCode: "404",
  error: "not_found",
  message: "Object not found",
  code: "NoSuchKey",
};
for (const absent of [false, true]) {
  Deno.test(
    "real Storage wrapped NoSuchKey confirms only a closed claim: " + absent,
    async () => {
      const f = fixture({
        absent,
        absenceStatus: 400,
        absenceBody: wrappedAbsence,
      });
      const r = await f.run(), b = await r.json();
      assert(b.purged === 1);
      assert(f.calls.some((x) => x.body?._action === "confirm"));
      assert(f.calls.some((x) => x.method === "DELETE") === !absent);
    },
  );
}
for (
  const [name, status, body] of [
    ["missing underlying status", 400, { code: "NoSuchKey" }],
    ["wrong underlying status", 400, { code: "NoSuchKey", statusCode: "400" }],
    ["missing bucket", 400, { code: "NoSuchBucket", statusCode: "404" }],
    ["forbidden", 403, wrappedAbsence],
    ["provider failure", 500, wrappedAbsence],
  ] as const
) {
  Deno.test(name + " is never object absence", async () => {
    const f = fixture({
      absent: true,
      absenceStatus: status,
      absenceBody: body,
    });
    const b = await (await f.run()).json();
    assert(b.purged === 0 && b.unresolved === 1);
    assert(!f.calls.some((x) => x.body?._action === "confirm"));
  });
}
Deno.test("wrapped provider absence never settles an open writer", async () => {
  const f = fixture({
    probe: true,
    absent: true,
    absenceStatus: 400,
    absenceBody: wrappedAbsence,
  });
  const b = await (await f.run()).json();
  assert(b.recovered === 0 && b.unresolved === 1);
  assert(!f.calls.some((x) => x.body?._action === "reconcile"));
});
Deno.test("wrapped provider absence cannot override SQL refusal", async () => {
  const f = fixture({
    absent: true,
    absenceStatus: 400,
    absenceBody: wrappedAbsence,
    confirm: false,
  });
  const b = await (await f.run()).json();
  assert(b.purged === 0 && b.unresolved === 1);
});

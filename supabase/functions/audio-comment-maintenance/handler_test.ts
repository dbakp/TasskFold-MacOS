import { createAudioMaintenanceHandler } from "./handler.ts";
const equal = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
};
function fixture() {
  const item = {
    operation_id: crypto.randomUUID(),
    asset_id: crypto.randomUUID(),
    bucket: "taskfold-audio-v1",
    object_name: "",
    token: crypto.randomUUID(),
  };
  item.object_name =
    `audio-comments/v1/${crypto.randomUUID()}/${crypto.randomUUID()}/${item.asset_id}.m4a`;
  const state = {
    items: [item],
    deleteOK: true,
    missing: true,
    confirm: true,
    deletes: 0,
    confirms: 0,
    claimed: 0,
  };
  const config = {
    url: "https://maintenance.example.invalid",
    serviceKey: "synthetic-service",
    maintenanceKey: "a".repeat(40),
    enabled: true,
  };
  const send = async (r: Request) => {
    equal(new URL(r.url).origin, config.url);
    equal(r.redirect, "error");
    equal(r.headers.get("Authorization"), "Bearer " + config.serviceKey);
    equal(r.headers.get("apikey"), config.serviceKey);
    if (r.method === "DELETE") {
      state.deletes++;
      equal(await r.json(), { prefixes: [item.object_name] });
      return new Response(null, { status: state.deleteOK ? 200 : 500 });
    }
    if (r.method === "GET") {
      return new Response(null, { status: state.missing ? 404 : 200 });
    }
    const b = await r.json();
    if (b._action === "claim") {
      state.claimed++;
      return Response.json({
        protocol: 1,
        items: state.items,
        blocked_uploads: 0,
      });
    }
    equal(b._action, "confirm");
    state.confirms++;
    equal(b._body, {
      operation_id: item.operation_id,
      asset_id: item.asset_id,
      object_name: item.object_name,
      token: item.token,
    });
    return Response.json({ protocol: 1, purged: state.confirm });
  };
  const request = (key = config.maintenanceKey) =>
    new Request("https://worker.example.invalid/", {
      method: "POST",
      headers: { "X-Taskfold-Audio-Maintenance": key },
    });
  return {
    config,
    state,
    item,
    request,
    handler: createAudioMaintenanceHandler(config, { send }),
  };
}
Deno.test("worker removes only claimed exact path, checks absence, then confirms", async () => {
  const f = fixture();
  equal(await (await f.handler(f.request())).json(), {
    protocol: 1,
    claimed: 1,
    blocked_uploads: 0,
    purged: 1,
    unresolved: 0,
  });
  equal(f.state.deletes, 1);
  equal(f.state.confirms, 1);
});
Deno.test("failed delete cannot confirm even with missing read", async () => {
  const f = fixture();
  f.state.deleteOK = false;
  equal((await (await f.handler(f.request())).json()).unresolved, 1);
  equal(f.state.confirms, 0);
});
Deno.test("successful delete with bytes still readable cannot confirm", async () => {
  const f = fixture();
  f.state.missing = false;
  equal((await (await f.handler(f.request())).json()).purged, 0);
  equal(f.state.confirms, 0);
});
Deno.test("SQL refusal remains unresolved", async () => {
  const f = fixture();
  f.state.confirm = false;
  equal((await (await f.handler(f.request())).json()).unresolved, 1);
});
Deno.test("entire destructive manifest validated before first delete", async () => {
  const f = fixture();
  f.state.items.push({
    ...f.item,
    operation_id: crypto.randomUUID(),
    object_name: "../other-bucket/secret",
  });
  equal((await f.handler(f.request())).status, 503);
  equal(f.state.deletes, 0);
});
Deno.test("dedicated scheduler secret is required before network", async () => {
  const f = fixture();
  equal((await f.handler(f.request("wrong"))).status, 401);
  equal(f.state.claimed, 0);
  f.config.enabled = false;
  equal((await f.handler(f.request())).status, 503);
  equal(f.state.claimed, 0);
});
Deno.test("worker rejects query parameters", async () => {
  const f = fixture();
  equal(
    (await f.handler(
      new Request("https://worker.example.invalid/?bucket=other", {
        method: "POST",
      }),
    )).status,
    400,
  );
  equal(f.state.claimed, 0);
});
Deno.test("worker deadline bounds ignored cancellation and cancels late body", async () => {
  let cancelled = false;
  const f = fixture();
  const h = createAudioMaintenanceHandler({
    ...f.config,
    timeoutMilliseconds: 50,
  }, {
    send: async () => {
      await new Promise((r) => setTimeout(r, 100));
      return new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
      );
    },
  });
  equal((await h(f.request())).status, 503);
  await new Promise((r) => setTimeout(r, 70));
  equal(cancelled, true);
});

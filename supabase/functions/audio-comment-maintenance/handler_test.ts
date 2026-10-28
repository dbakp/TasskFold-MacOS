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
    if (b._action === "probe") return Response.json({ protocol: 1, items: [] });
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
    recovered: 0,
    probe_unresolved: 0,
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

const syntheticAudio = await Deno.readFile(
  new URL(
    "../../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
    import.meta.url,
  ),
);
const sha = async (bytes: Uint8Array) =>
  Array.from(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", bytes as BufferSource),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
async function recoveryFixture() {
  const asset = crypto.randomUUID(),
    probe = {
      operation_id: crypto.randomUUID(),
      asset_id: asset,
      bucket: "taskfold-audio-v1",
      object_name:
        `audio-comments/v1/${crypto.randomUUID()}/${crypto.randomUUID()}/${asset}.m4a`,
      ticket_id: crypto.randomUUID(),
      sha256: await sha(syntheticAudio),
      byte_count: syntheticAudio.length,
    };
  const state = {
    bytes: syntheticAudio as Uint8Array | null,
    reconciles: 0,
    reads: 0,
  };
  const config = {
    url: "https://recovery.example.invalid",
    serviceKey: "key",
    maintenanceKey: "a".repeat(40),
    enabled: true,
  };
  const h = createAudioMaintenanceHandler(config, {
    send: async (r) => {
      if (r.method === "GET") {
        state.reads++;
        return state.bytes
          ? new Response(state.bytes.slice(), {
            headers: { "Content-Type": "audio/mp4" },
          })
          : new Response(null, { status: 404 });
      }
      const b = await r.json();
      if (b._action === "probe") {
        return Response.json({ protocol: 1, items: [probe] });
      }
      if (b._action === "reconcile") {
        state.reconciles++;
        equal(b._body.stored_sha256, probe.sha256);
        equal(b._body.stored_bytes, syntheticAudio.length);
        return Response.json({ protocol: 1, settled: true });
      }
      equal(b._action, "claim");
      return Response.json({
        protocol: 1,
        items: [],
        blocked_uploads: state.reconciles ? 0 : 1,
      });
    },
  });
  return {
    state,
    probe,
    run: () =>
      h(
        new Request("https://worker.example.invalid/", {
          method: "POST",
          headers: { "X-Taskfold-Audio-Maintenance": config.maintenanceKey },
        }),
      ),
  };
}
Deno.test("complete stored-byte readback reconciles retired upload", async () => {
  const f = await recoveryFixture();
  const r = await (await f.run()).json();
  equal(r.recovered, 1);
  equal(f.state.reconciles, 1);
});
Deno.test("missing bytes never reconcile unknown upload", async () => {
  const f = await recoveryFixture();
  f.state.bytes = null;
  const r = await (await f.run()).json();
  equal(r.recovered, 0);
  equal(r.probe_unresolved, 1);
  equal(r.blocked_uploads, 1);
  equal(f.state.reconciles, 0);
});
Deno.test("wrong stored hash never reconciles unknown upload", async () => {
  const f = await recoveryFixture();
  f.state.bytes = new Uint8Array(syntheticAudio.length);
  equal((await (await f.run()).json()).recovered, 0);
  equal(f.state.reconciles, 0);
});
Deno.test("malformed recovery path rejected before reading", async () => {
  const f = await recoveryFixture();
  f.probe.object_name = "other/path.m4a";
  equal((await f.run()).status, 503);
  equal(f.state.reads, 0);
});
async function scheduledFixture() {
  const ref = "a".repeat(20),
    secret = "b".repeat(64),
    nonce = crypto.randomUUID(),
    issued = Math.floor(Date.now() / 1000);
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = Array.from(
    new Uint8Array(
      await crypto.subtle.sign(
        "HMAC",
        key,
        new TextEncoder().encode(
          `taskfold.audio.maintenance.v1.${issued}.${nonce}.${ref}`,
        ),
      ),
    ),
    (b) => b.toString(16).padStart(2, "0"),
  ).join("");
  const state = { admitted: false, calls: 0 };
  const handler = createAudioMaintenanceHandler({
    url: `https://${ref}.supabase.co`,
    serviceKey: "key",
    maintenanceKey: secret,
    enabled: true,
  }, {
    send: async (r) => {
      state.calls++;
      const b = await r.json();
      if (b._action === "admit_schedule") {
        equal(b._body, { nonce, issued });
        const admitted = !state.admitted;
        state.admitted = true;
        return Response.json({ protocol: 1, admitted });
      }
      if (b._action === "probe") {
        return Response.json({ protocol: 1, items: [] });
      }
      equal(b._action, "claim");
      return Response.json({ protocol: 1, items: [], blocked_uploads: 0 });
    },
  });
  const proof = `${issued}.${nonce}.${mac}`;
  return {
    state,
    proof,
    run: (value = proof) =>
      handler(
        new Request("https://worker.example.invalid/", {
          method: "POST",
          headers: { "X-Taskfold-Audio-Schedule": value },
        }),
      ),
  };
}
Deno.test("signed scheduled invocation requires one-use SQL admission", async () => {
  const f = await scheduledFixture();
  equal((await f.run()).status, 200);
  equal((await f.run()).status, 401);
  equal(f.state.calls, 4);
});
Deno.test("tampered signature is rejected before SQL admission", async () => {
  const f = await scheduledFixture();
  equal(
    (await f.run(f.proof.slice(0, -1) + (f.proof.endsWith("0") ? "1" : "0")))
      .status,
    401,
  );
  equal(f.state.calls, 0);
});
Deno.test("expired scheduled proof is rejected before SQL admission", async () => {
  const f = await scheduledFixture();
  equal((await f.run(f.proof.replace(/^[0-9]+/, "1"))).status, 401);
  equal(f.state.calls, 0);
});

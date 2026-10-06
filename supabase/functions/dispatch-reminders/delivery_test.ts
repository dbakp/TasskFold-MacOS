// deno-lint-ignore-file require-await
// Immediate async fake transports preserve the provider contract; race fixtures await gates.
import {
  type Claim,
  createAPNsProvider,
  type KeyConfig,
  parseKeys,
  type Prepared,
  type Provider,
  type Transport,
  validPrepared,
} from "./apns.ts";
import { type Config, createHandler } from "./handler.ts";
function assert(value: unknown, message = "Assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(JSON.stringify(actual) === JSON.stringify(expected));
}
async function rejects(body: () => unknown | Promise<unknown>) {
  let failed = false;
  try {
    await body();
  } catch {
    failed = true;
  }
  assert(failed);
}
const clone = <T>(v: T): T => structuredClone(v);
const device = "00000000-0000-4000-8000-000000000021",
  lease = "00000000-0000-4000-8000-000000000031";
const account = "00000000-0000-4000-8000-000000000011",
  task = "00000000-0000-4000-8000-000000000041",
  spec = "00000000-0000-4000-8000-000000000051";
const instant = Date.parse("2026-10-06T13:00:00.123Z"), id = "a".repeat(64);
const job: Claim = {
  id,
  device,
  lease,
  account,
  task,
  spec,
  signature: "r4:" + "b".repeat(64),
  fire_at: new Date(instant).toISOString(),
  attempt: 1,
};
const prepared: Prepared = {
  id,
  collapse_id: id,
  provider_id: "aaaaaaaa-aaaa-5aaa-aaaa-aaaaaaaaaaaa",
  binding: {
    platform: "ios",
    bundle: "com.dbakp.taskfold",
    environment: "development",
    token: "aa11",
    enabled: true,
    permission: "authorized",
  },
  content: {
    title: "Fixture task 🔥",
    info: {
      eventKind: "task",
      eventID: `${task}.${spec}`,
      accountID: account,
      taskID: task,
      specID: spec,
      signature: job.signature,
      originalAt: instant / 1000,
      fireAt: instant / 1000,
      snoozed: false,
    },
  },
};
// Ephemeral P-256 key solely for signature verification; no configured/private deployment key.
const pair = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"],
);
const pem = "-----BEGIN PRIVATE KEY-----\n" +
  btoa(
    String.fromCharCode(
      ...new Uint8Array(
        await crypto.subtle.exportKey("pkcs8", pair.privateKey),
      ),
    ),
  ) + "\n-----END PRIVATE KEY-----";
const key: KeyConfig = {
  platform: "ios",
  bundle: "com.dbakp.taskfold",
  environment: "development",
  teamID: "ABCDEFGHIJ",
  keyID: "1234567890",
  privateKey: pem,
};
const config: Config = {
  url: "https://fixture.supabase.co",
  serviceKey: "fixture-service-secret",
  cronSecret: "c".repeat(64),
  enabled: true,
};
const request = (suffix = "", method = "POST", secret = config.cronSecret) =>
  new Request(
    "https://fixture.supabase.co/functions/v1/dispatch-reminders" + suffix,
    { method, headers: { "x-cron-secret": secret } },
  );
const result = {
  outcome: "accepted" as const,
  retryAfter: null,
  halt: false,
  code: "accepted" as const,
};
const provider: Provider = {
  ready: () => Promise.resolve(),
  send: () => Promise.resolve(result),
};
function fixtureDB(
  options: {
    prepare?: unknown;
    finish?: boolean;
    devices?: string[];
    failFinish?: boolean;
    after?: string | null;
    sweep?: unknown;
    finishSweep?: boolean;
    failSweepFinish?: boolean;
  } = {},
) {
  const calls: { name: string; body: Record<string, unknown> }[] = [];
  let claimed = false;
  const send: Transport = async (req) => {
    assert(
      req.headers.get("apikey") === config.serviceKey &&
        req.headers.get("authorization") === "Bearer " + config.serviceKey,
    );
    const name = new URL(req.url).pathname.split("/").at(-1)!,
      body = await req.json();
    calls.push({ name, body });
    switch (name) {
      case "taskfold_claim_reminder_sweep":
        return Response.json(
          "sweep" in options ? options.sweep : {
            version: 1,
            lease,
            after: options.after ?? null,
          },
        );
      case "taskfold_finish_reminder_sweep":
        if (options.failSweepFinish) throw new Error("PRIVATE SWEEP ERROR");
        return Response.json(options.finishSweep ?? true);
      case "taskfold_maintain_reminder_queue":
        return Response.json({ retired: 0, removed: 0 });
      case "taskfold_reminder_device_page":
        return Response.json(options.devices ?? [device]);
      case "taskfold_reconcile_reminder_jobs":
        return Response.json({ queued: 1 });
      case "taskfold_claim_reminder_jobs":
        assert(body._limit === 1);
        if (claimed) return Response.json([]);
        claimed = true;
        return Response.json([{ ...job, device: body._device }]);
      case "taskfold_prepare_sweep_reminder_job":
        equal(body, { _sweep: lease, _id: id, _lease: lease });
        return Response.json("prepare" in options ? options.prepare : prepared);
      case "taskfold_finish_reminder_delivery":
        if (options.failFinish) throw new Error("PRIVATE DATABASE EXCEPTION");
        return Response.json(options.finish ?? true);
      default:
        throw new Error("Unexpected RPC");
    }
  };
  return { calls, send };
}
Deno.test("authorization, method, cursor and rollout fail closed without queue/provider calls", async () => {
  let calls = 0;
  const blocked = createHandler(config, {
    ready: async () => {
      calls++;
    },
    send: async () => {
      calls++;
      return result;
    },
  }, {
    send: async () => {
      calls++;
      throw new Error();
    },
  });
  equal((await blocked(request("", "POST", ""))).status, 401);
  equal((await blocked(request("", "GET"))).status, 405);
  for (
    const query of [
      "?after=invalid",
      "?after=" + device,
      "?device=" + device,
      "?after=" + device + "&after=" + device,
    ]
  ) equal((await blocked(request(query))).status, 400);
  const disabled = createHandler({ ...config, enabled: false }, provider, {
    send: async () => {
      calls++;
      throw new Error();
    },
  });
  equal(await (await disabled(request())).json(), { status: "disabled" });
  equal(calls, 0);
});
Deno.test("missing/invalid signing configuration does not reserve any leases", async () => {
  const db = fixtureDB();
  const badProvider = createAPNsProvider([{
    ...key,
    privateKey: "-----BEGIN PRIVATE KEY-----invalid-----END PRIVATE KEY-----",
  }], { send: db.send });
  equal(
    (await createHandler(config, badProvider, { send: db.send })(request()))
      .status,
    503,
  );
  equal(db.calls, []);
  equal(
    (await createHandler({ ...config, serviceKey: "" }, provider, {
      send: db.send,
    })(request())).status,
    503,
  );
  for (
    const invalid of [
      "",
      "[]",
      JSON.stringify([key, key]),
      JSON.stringify([{ ...key, bundle: "evil.bundle" }]),
      JSON.stringify([{ ...key, keyID: "invalid" }]),
    ]
  ) await rejects(() => parseKeys(invalid));
});
Deno.test("worker revalidates, dispatches once and records exact lease; output excludes private data", async () => {
  const db = fixtureDB();
  let sends = 0;
  const response = await createHandler(config, {
    ...provider,
    send: async (p) => {
      equal(p, prepared);
      sends++;
      return result;
    },
  }, { send: db.send })(request());
  equal(response.status, 200);
  const text = await response.text();
  assert(
    !text.includes(prepared.content.title) && !text.includes("aa11") &&
      !text.includes(config.serviceKey),
  );
  equal(JSON.parse(text), {
    status: "processed",
    devices: 1,
    accepted: 1,
    retry: 0,
    failed: 0,
    obsolete: 0,
    receiptRejected: 0,
    diagnostics: { accepted: 1 },
    nextCursor: null,
  });
  equal(sends, 1);
  equal(
    db.calls.find((c) => c.name === "taskfold_finish_reminder_delivery")?.body,
    {
      _id: id,
      _lease: lease,
      _outcome: "accepted",
      _retry_after_seconds: null,
    },
  );
});
Deno.test("cancelled/completed/reassigned lease prepares null and never dispatches", async () => {
  const db = fixtureDB({ prepare: null });
  let sends = 0;
  const response = await createHandler(config, {
    ...provider,
    send: async () => {
      sends++;
      return result;
    },
  }, { send: db.send })(request());
  equal((await response.json()).obsolete, 1);
  equal(sends, 0);
  assert(!db.calls.some((c) => c.name === "taskfold_finish_reminder_delivery"));
});
Deno.test("wrong account/signature/address/occurrence payload leaves lease for recovery without dispatch", async () => {
  const values = [
    clone(prepared),
    clone(prepared),
    clone(prepared),
    clone(prepared),
  ];
  values[0].content.info.accountID = device;
  values[1].content.info.signature = "r4:" + "c".repeat(64);
  values[2].binding.token = "../private";
  values[3].content.info.fireAt = instant / 1000 + 1;
  for (const value of values) {
    assert(!validPrepared(value, job));
    let sends = 0;
    const db = fixtureDB({ prepare: value });
    equal(
      (await createHandler(config, {
        ...provider,
        send: async () => {
          sends++;
          return result;
        },
      }, { send: db.send })(request())).status,
      502,
    );
    equal(sends, 0);
    assert(
      !db.calls.some((c) => c.name === "taskfold_finish_reminder_delivery"),
    );
  }
});
Deno.test("provider accepted + lost DB acknowledgement never resends within invocation", async () => {
  const db = fixtureDB({ failFinish: true });
  let sends = 0;
  const response = await createHandler(config, {
    ...provider,
    send: async () => {
      sends++;
      return result;
    },
  }, { send: db.send })(request());
  equal(response.status, 502);
  equal(sends, 1);
  assert(!(await response.text()).includes("PRIVATE"));
});
Deno.test("mutation/token rotation during provider response rejects receipt rather than counting sent", async () => {
  const db = fixtureDB({ finish: false });
  let resolve!: () => void;
  const held = new Promise<void>((r) => resolve = r);
  let sending!: () => void;
  const started = new Promise<void>((r) => sending = r);
  const response = createHandler(config, {
    ...provider,
    send: async () => {
      sending();
      await held;
      return result;
    },
  }, { send: db.send })(request());
  await started;
  assert(!db.calls.some((c) => c.name === "taskfold_finish_reminder_delivery"));
  resolve();
  const data = await (await response).json();
  equal(data.accepted, 0);
  equal(data.receiptRejected, 1);
});
Deno.test("provider outage pauses batch with retry delay and does not claim remaining devices", async () => {
  const db = fixtureDB({
    devices: [device, "00000000-0000-4000-8000-000000000022"],
  });
  const response = await createHandler(config, {
    ...provider,
    send: async () => ({
      outcome: "transient",
      retryAfter: 900,
      halt: true,
      code: "transport",
    }),
  }, { send: db.send })(request());
  const data = await response.json();
  equal(data.status, "paused");
  equal(data.nextCursor, null);
  equal(data.retry, 1);
  equal(
    db.calls.filter((c) => c.name === "taskfold_claim_reminder_jobs").length,
    1,
  );
  equal(
    db.calls.find((c) => c.name === "taskfold_finish_reminder_delivery")?.body
      ._retry_after_seconds,
    900,
  );
});
Deno.test("ordered keyset page returns cursor after last fully processed device", async () => {
  const devices = Array.from(
      { length: 20 },
      (_, i) => `00000000-0000-4000-8000-${String(i + 21).padStart(12, "0")}`,
    ),
    db = fixtureDB({ devices });
  const response = await createHandler(config, provider, { send: db.send })(
    request(),
  );
  equal((await response.json()).nextCursor, devices.at(-1));
  const invalid = fixtureDB({ devices: [device, device] });
  equal(
    (await createHandler(config, provider, { send: invalid.send })(request()))
      .status,
    502,
  );
});
Deno.test("time budget stops before claiming and retains previous cursor", async () => {
  const db = fixtureDB({ after: "00000000-0000-4000-8000-000000000001" });
  let tick = 0;
  const response = await createHandler(config, provider, {
    send: db.send,
    now: () => tick++ === 0 ? instant : instant + 31_000,
  })(request());
  const data = await response.json();
  equal(data.status, "paused");
  equal(data.nextCursor, "00000000-0000-4000-8000-000000000001");
  assert(!db.calls.some((c) => c.name === "taskfold_claim_reminder_jobs"));
});
Deno.test("busy/backoff sweep never touches device jobs or provider", async () => {
  const db = fixtureDB({ sweep: null });
  let sends = 0;
  const response = await createHandler(config, {
    ...provider,
    send: async () => {
      sends++;
      return result;
    },
  }, { send: db.send })(request());
  equal(await response.json(), { status: "busy" });
  equal(sends, 0);
  equal(db.calls.map((c) => c.name), ["taskfold_claim_reminder_sweep"]);
});
Deno.test("malformed sweep leases fail closed before touching private delivery", async () => {
  for (
    const sweep of [
      [],
      {},
      { version: 2, lease, after: null },
      { version: 1, lease: "not-a-nonce", after: null },
      { version: 1, lease, after: "not-a-cursor" },
      { version: 1, lease, after: null, extra: "PRIVATE" },
    ]
  ) {
    const db = fixtureDB({ sweep });
    equal(
      (await createHandler(config, provider, { send: db.send })(request()))
        .status,
      502,
    );
    equal(db.calls.map((c) => c.name), ["taskfold_claim_reminder_sweep"]);
  }
});
Deno.test("durable cursor resumes after twenty devices and wraps at exhaustion", async () => {
  const devices = Array.from(
    { length: 45 },
    (_, i) => `00000000-0000-4000-8000-${String(i + 21).padStart(12, "0")}`,
  );
  let cursor: string | null = null;
  const visited: string[] = [], committed: (string | null)[] = [];
  for (let run = 0; run < 4; run++) {
    const next = devices.filter((d) => cursor === null || d > cursor).slice(
      0,
      20,
    );
    const db = fixtureDB({ devices: next, after: cursor, prepare: null });
    const response = await createHandler(config, provider, {
      send: async (req) => {
        const name = new URL(req.url).pathname.split("/").at(-1);
        if (name === "taskfold_finish_reminder_sweep") {
          const body = await req.clone().json();
          equal(body._after, cursor);
          equal(body._lease, lease);
          cursor = body._next;
          committed.push(cursor);
        }
        return db.send(req);
      },
    })(request());
    equal(response.status, 200);
    equal((await response.json()).nextCursor, cursor);
    visited.push(
      ...db.calls.filter((c) => c.name === "taskfold_reconcile_reminder_jobs")
        .map((c) => c.body._device as string),
    );
  }
  equal(committed, [devices[19], devices[39], null, devices[19]]);
  equal(visited, [...devices, ...devices.slice(0, 20)]);
});
Deno.test("lost delivery acknowledgement records error without advancing saved cursor", async () => {
  const after = "00000000-0000-4000-8000-000000000001";
  const db = fixtureDB({ after, failFinish: true });
  equal(
    (await createHandler(config, provider, { send: db.send })(request()))
      .status,
    502,
  );
  const finish = db.calls.find((c) =>
    c.name === "taskfold_finish_reminder_sweep"
  )!;
  equal([
    finish.body._after,
    finish.body._next,
    finish.body._lease,
    finish.body._status,
    finish.body._retry_after_seconds,
  ], [after, after, lease, "error", 30]);
});
Deno.test("lost or expired sweep receipt never reports committed progress", async () => {
  for (const options of [{ finishSweep: false }, { failSweepFinish: true }]) {
    const db = fixtureDB(options);
    let sends = 0;
    const response = await createHandler(config, {
      ...provider,
      send: async () => {
        sends++;
        return result;
      },
    }, { send: db.send })(request());
    equal(response.status, 502);
    equal(sends, 1);
    const receipts = db.calls.filter((c) =>
      c.name === "taskfold_finish_reminder_sweep"
    );
    equal(receipts.map((c) => c.body._status), ["processed", "error"]);
    equal(receipts[1].body._next, receipts[1].body._after);
    assert(!(await response.text()).includes("PRIVATE"));
  }
});
Deno.test("provider pause persists preceding cursor and bounded global retry floor", async () => {
  const after = "00000000-0000-4000-8000-000000000001";
  for (const delay of [null, 1, 900, 3601]) {
    const db = fixtureDB({ after });
    const response = await createHandler(config, {
      ...provider,
      send: async () => ({
        outcome: "transient",
        retryAfter: delay,
        halt: true,
        code: "transport",
      }),
    }, { send: db.send })(request());
    equal(response.status, 200);
    const receipt = db.calls.find((c) =>
      c.name === "taskfold_finish_reminder_sweep"
    )!;
    equal([
      receipt.body._after,
      receipt.body._next,
      receipt.body._status,
      receipt.body._retry_after_seconds,
    ], [after, after, "paused", Math.min(3600, Math.max(30, delay ?? 900))]);
  }
});
Deno.test("lost response after cursor commit cannot rewind the replacement sweep", async () => {
  const devices = Array.from(
    { length: 20 },
    (_, i) => `00000000-0000-4000-8000-${String(i + 21).padStart(12, "0")}`,
  );
  let saved: string | null = null, active: string | null = lease;
  let receipts = 0;
  const db = fixtureDB({ devices });
  const response = await createHandler(config, provider, {
    send: async (req) => {
      if (
        new URL(req.url).pathname.endsWith("taskfold_finish_reminder_sweep")
      ) {
        const body = await req.json();
        receipts++;
        if (active !== body._lease) return Response.json(false);
        saved = body._next;
        active = null;
        throw new Error("PRIVATE LOST RESPONSE");
      }
      return db.send(req);
    },
  })(request());
  equal(response.status, 502);
  equal(saved, devices[19]);
  equal(receipts, 2);
});
Deno.test("request abort does not send a second provider call or advance cursor", async () => {
  const controller = new AbortController(), db = fixtureDB();
  let sends = 0;
  const response = await createHandler(config, {
    ...provider,
    send: async () => {
      sends++;
      controller.abort();
      throw new Error("PRIVATE ABORT");
    },
  }, { send: db.send })(new Request(request(), { signal: controller.signal }));
  equal(response.status, 502);
  equal(sends, 1);
  assert(!db.calls.some((c) => c.name === "taskfold_finish_reminder_sweep"));
});
Deno.test("late preparation response cannot dispatch after invocation budget", async () => {
  let tick = 0, sends = 0;
  const db = fixtureDB();
  const response = await createHandler(config, {
    ...provider,
    send: async () => {
      sends++;
      return result;
    },
  }, {
    send: db.send,
    now: () => tick++ < 3 ? instant : instant + 121_000,
  })(request());
  equal(response.status, 200);
  equal((await response.json()).status, "paused");
  equal(sends, 0);
  assert(
    db.calls.some((c) => c.name === "taskfold_prepare_sweep_reminder_job"),
  );
  assert(!db.calls.some((c) => c.name === "taskfold_finish_reminder_delivery"));
});
Deno.test("APNs sends signed ES256 request, exact topic/environment and bounded private route", async () => {
  let sent!: Request;
  let payload: Record<string, unknown> = {};
  const p = clone(prepared);
  p.content.info.extraPrivateNotes = "NEVER IN PUSH";
  const apns = createAPNsProvider(parseKeys(JSON.stringify([key])), {
    now: () => instant,
    send: async (req) => {
      sent = req;
      payload = await req.json();
      return new Response(null, { status: 200 });
    },
  });
  await apns.ready();
  equal((await apns.send(p, new AbortController().signal)).outcome, "accepted");
  equal(sent.url, "https://api.sandbox.push.apple.com/3/device/aa11");
  equal(sent.headers.get("apns-topic"), key.bundle);
  equal(sent.headers.get("apns-collapse-id"), id);
  equal(sent.headers.get("apns-id"), prepared.provider_id);
  equal(sent.headers.get("apns-expiration"), "0");
  equal(sent.headers.get("apns-push-type"), "alert");
  equal(sent.headers.get("apns-priority"), "10");
  assert(!JSON.stringify(payload).includes("NEVER IN PUSH"));
  const parts = sent.headers.get("authorization")!.replace("bearer ", "").split(
    ".",
  );
  const decode = (v: string) =>
    Uint8Array.from(
      atob(v.replaceAll("-", "+").replaceAll("_", "/")),
      (c) => c.charCodeAt(0),
    );
  equal(JSON.parse(new TextDecoder().decode(decode(parts[0]))), {
    alg: "ES256",
    kid: key.keyID,
  });
  equal(JSON.parse(new TextDecoder().decode(decode(parts[1]))), {
    iss: key.teamID,
    iat: Math.floor(instant / 1000),
  });
  assert(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      pair.publicKey,
      decode(parts[2]),
      new TextEncoder().encode(parts[0] + "." + parts[1]),
    ),
  );
});
Deno.test("APNs production Mac uses its separately scoped signing identity", async () => {
  const mac: KeyConfig = {
    ...key,
    platform: "macos",
    bundle: "com.dbakp.taskfold.mac",
    environment: "production",
    keyID: "MAC1234567",
  };
  let sent!: Request;
  const apns = createAPNsProvider([key, mac], {
    now: () => instant,
    send: async (r) => {
      sent = r;
      return new Response(null, { status: 200 });
    },
  });
  await apns.ready();
  const p = clone(prepared);
  p.binding = {
    ...p.binding,
    platform: "macos",
    bundle: mac.bundle,
    environment: "production",
  };
  equal((await apns.send(p, new AbortController().signal)).outcome, "accepted");
  equal(new URL(sent.url).hostname, "api.push.apple.com");
  equal(sent.headers.get("apns-topic"), mac.bundle);
  const token = sent.headers.get("authorization")!.split(" ")[1];
  assert(
    atob(token.split(".")[0].replaceAll("-", "+").replaceAll("_", "/"))
      .includes(mac.keyID),
  );
});
Deno.test("JWT reused across concurrent sends and refreshed only after 45 minutes", async () => {
  let clock = instant;
  const tokens: string[] = [];
  const apns = createAPNsProvider([key], {
    now: () => clock,
    send: async (r) => {
      tokens.push(r.headers.get("authorization")!);
      return new Response(null, { status: 200 });
    },
  });
  await apns.ready();
  await Promise.all(
    Array.from(
      { length: 4 },
      () => apns.send(prepared, new AbortController().signal),
    ),
  );
  assert(tokens.every((t) => t === tokens[0]));
  clock += 44 * 60_000;
  await apns.send(prepared, new AbortController().signal);
  equal(tokens.at(-1), tokens[0]);
  clock += 60_000;
  await apns.send(prepared, new AbortController().signal);
  assert(tokens.at(-1) !== tokens[0]);
});
Deno.test("known device rejection retires binding; unknown 410 does not", async () => {
  for (
    const [status, reason, expected] of [
      [410, "Unregistered", "invalid_token"],
      [410, "ExpiredToken", "invalid_token"],
      [400, "BadDeviceToken", "invalid_token"],
      [400, "DeviceTokenNotForTopic", "invalid_token"],
      [410, "Unknown", "transient"],
      [413, "PayloadTooLarge", "permanent"],
    ] as const
  ) {
    const apns = createAPNsProvider([key], {
      send: async () => Response.json({ reason }, { status }),
    });
    await apns.ready();
    equal(
      (await apns.send(prepared, new AbortController().signal)).outcome,
      expected,
    );
  }
});
Deno.test("provider signing/topic errors halt without retiring user's address", async () => {
  for (
    const [status, reason] of [
      [403, "ExpiredProviderToken"],
      [403, "InvalidProviderToken"],
      [400, "TopicDisallowed"],
      [429, "TooManyProviderTokenUpdates"],
    ] as const
  ) {
    const apns = createAPNsProvider([key], {
      send: async () => Response.json({ reason }, { status }),
    });
    await apns.ready();
    equal(await apns.send(prepared, new AbortController().signal), {
      outcome: "transient",
      retryAfter: 900,
      halt: true,
      code: "provider_configuration",
    });
  }
});
Deno.test("server error waits at least 15 minutes; throttle honors bounded Retry-After", async () => {
  for (
    const [status, delay, expected] of [
      [503, "1", 900],
      [500, "1200", 1200],
      [429, "60", 60],
      [429, "9999999999", 3600],
      [429, "bad", 30],
      [429, new Date(instant + 90_000).toUTCString(), 90],
    ] as const
  ) {
    const apns = createAPNsProvider([key], {
      now: () => instant,
      send: async () =>
        Response.json({ reason: "Fixture" }, {
          status,
          headers: { "retry-after": delay },
        }),
    });
    await apns.ready();
    const result = await apns.send(prepared, new AbortController().signal);
    equal(result.outcome, "transient");
    equal(result.retryAfter, expected);
  }
});
Deno.test("missing scope and aborted transport halt safely; private errors not returned", async () => {
  let sent = 0;
  const apns = createAPNsProvider([key], {
    send: async () => {
      sent++;
      throw new Error("PRIVATE PROVIDER BODY");
    },
  });
  await apns.ready();
  const p = clone(prepared);
  p.binding.environment = "production";
  equal(
    (await apns.send(p, new AbortController().signal)).code,
    "provider_configuration",
  );
  equal(sent, 0);
  const controller = new AbortController();
  controller.abort();
  const result = await apns.send(prepared, controller.signal);
  equal(result.code, "transport");
  assert(!JSON.stringify(result).includes("PRIVATE"));
});
Deno.test("oversized provider reason is cancelled and supplementary Unicode title stays under 4KiB", async () => {
  let cancelled = false;
  const stream = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode("x".repeat(4097)));
    },
    cancel() {
      cancelled = true;
    },
  });
  const apns = createAPNsProvider([key], {
    send: async (r) => {
      assert((await r.arrayBuffer()).byteLength < 4096);
      return new Response(stream, { status: 400 });
    },
  });
  await apns.ready();
  const p = clone(prepared);
  p.content.title = "🧠".repeat(100_000);
  equal(
    (await apns.send(p, new AbortController().signal)).outcome,
    "transient",
  );
  assert(cancelled);
});

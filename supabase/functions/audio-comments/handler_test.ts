import { createAudioCommentsHandler } from "./handler.ts";
import {
  audio64,
  digest,
  encodedMilliseconds,
  maximumAudioBytes,
  path,
  type Row,
  verifyAudio,
} from "./wire.ts";
const equal = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
};
const id = () => crypto.randomUUID();
const audio = await Deno.readFile(
  new URL(
    "../../../TaskfoldTests/Fixtures/audio-comment-synthetic-tone.m4a",
    import.meta.url,
  ),
);
const descriptor = {
  version: 1,
  mime_type: "audio/mp4",
  byte_count: audio.length,
  duration_ms: 1000,
  sha256: await digest(audio),
};
const base64 = (bytes: Uint8Array) => {
  let s = "";
  for (let i = 0; i < bytes.length; i += 32000) {
    s += String.fromCharCode(...bytes.subarray(i, i + 32000));
  }
  return btoa(s);
};
function fixture(options: { enabled?: boolean; timeout?: number } = {}) {
  const account = id(),
    session = id(),
    intent: Row = {
      version: 1,
      account,
      operation_id: id(),
      comment_id: id(),
      asset_id: id(),
      target: { task_id: id(), task_generation: id(), project_id: null },
      caption: "  café\nمراجعة 🪴  ",
      audio: descriptor,
    };
  const token = "test." +
    btoa(JSON.stringify({ sub: account, session_id: session })) + ".synthetic";
  const row: Row = {
    protocol: 1,
    account,
    operation_id: intent.operation_id,
    comment_id: intent.comment_id,
    asset_id: intent.asset_id,
    author_id: account,
    target: intent.target,
    caption: intent.caption,
    audio: descriptor,
    state: "pending",
    reserved_at: "2026-10-28T12:00:00Z",
    expires_at: "2026-10-28T12:15:00Z",
    published_at: null,
    bucket: "taskfold-audio-v1",
    object_name: path(intent),
  };
  const state = {
    stored: null as Uint8Array | null,
    uploads: 0,
    finalizes: 0,
    reads: 0,
    calls: [] as string[],
    lostAck: false,
    noWrite: false,
    admission: true,
    revoked: false,
    corrupt: false,
    wrongReceipt: false,
    authID: account,
  };
  const response = (x: unknown) =>
    new Response(JSON.stringify(x), {
      headers: { "Content-Type": "application/json" },
    });
  const send = async (request: Request): Promise<Response> => {
    const u = new URL(request.url);
    equal(u.origin, "https://gateway.example.invalid");
    equal(request.redirect, "error");
    state.calls.push(request.method + " " + u.pathname);
    equal(request.headers.get("apikey"), "synthetic-service-key");
    if (u.pathname === "/auth/v1/user") {
      equal(request.headers.get("Authorization"), "Bearer " + token);
      return response({ id: state.authID });
    }
    equal(request.headers.get("Authorization"), "Bearer synthetic-service-key");
    if (u.pathname.endsWith("/taskfold_audio_comment_admit")) {
      return response(
        state.admission
          ? { protocol: 1, account, allowed: true, retry_after: 0 }
          : { allowed: false, status: "rate_limited", retry_after: 37 },
      );
    }
    if (u.pathname.endsWith("/taskfold_audio_comment_command")) {
      const body = await request.json();
      equal(body._actor, account);
      equal(body._session, session);
      switch (body._action) {
        case "reserve":
          return response({
            ...row,
            ...state.wrongReceipt ? { comment_id: id() } : {},
          });
        case "finalize":
          state.finalizes++;
          equal(body._body.stored_sha256, descriptor.sha256);
          equal(body._body.stored_bytes, audio.length);
          row.state = "published";
          row.published_at = "2026-10-28T12:00:01Z";
          return response(row);
        case "read":
          state.reads++;
          return response(
            state.revoked && state.reads > 1 ? { status: "unavailable" } : row,
          );
        case "list":
          return response({
            protocol: 1,
            account,
            items: row.state === "published" ? [row] : [],
          });
        case "remove":
          return response({
            protocol: 1,
            account,
            operation_id: row.operation_id,
            comment_id: row.comment_id,
            state: "retired",
          });
        default:
          throw Error("Unexpected command");
      }
    }
    equal(u.pathname, "/storage/v1/object/taskfold-audio-v1/" + path(intent));
    if (request.method === "POST") {
      equal(request.headers.get("x-upsert"), "false");
      state.uploads++;
      if (state.stored) return new Response(null, { status: 409 });
      const input = new Uint8Array(await request.arrayBuffer());
      equal(await digest(input), descriptor.sha256);
      if (!state.noWrite) {
        state.stored = state.corrupt ? new Uint8Array([1, 2, 3]) : input;
      }
      if (state.lostAck) throw Error("secret lost acknowledgement");
      return new Response("{}", { status: 201 });
    }
    return state.stored
      ? new Response(state.stored.slice(), {
        headers: { "Content-Type": "audio/mp4" },
      })
      : new Response(null, { status: 404 });
  };
  const handler = createAudioCommentsHandler({
    url: "https://gateway.example.invalid",
    serviceKey: "synthetic-service-key",
    enabled: options.enabled ?? true,
    timeoutMilliseconds: options.timeout,
  }, { send });
  const request = (action: string, body: unknown) =>
    new Request(
      "https://edge.example.invalid/audio-comments?action=" + action,
      {
        method: "POST",
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      },
    );
  const publish = () =>
    handler(request("publish", { intent, audio_base64: base64(audio) }));
  return { handler, request, publish, intent, row, state, token, account };
}
Deno.test("publication reads stored bytes, then finalizes; retry preserves IDs and never overwrites", async () => {
  const f = fixture();
  const r = await f.publish();
  equal(r.status, 200);
  const output = await r.json();
  equal(output.receipt.comment_id, f.intent.comment_id);
  equal(output.receipt.object_name, undefined);
  equal(output.receipt.bucket, undefined);
  equal(f.state.uploads, 1);
  equal(f.state.finalizes, 1);
  equal((await f.publish()).status, 200);
  equal(f.state.uploads, 1);
  const download = await f.handler(
    f.request("download", { comment_id: f.intent.comment_id }),
  );
  equal(download.status, 200);
  equal(download.headers.get("Cache-Control"), "private, no-store");
  equal(
    await digest(new Uint8Array(await download.arrayBuffer())),
    descriptor.sha256,
  );
  equal(f.state.reads, 2);
  const list = await (await f.handler(f.request("list", f.intent.target)))
    .json();
  equal(list.items.length, 1);
  equal(list.items[0].object_name, undefined);
});
Deno.test("lost acknowledgement reconciles fixed stored object", async () => {
  const f = fixture();
  f.state.lostAck = true;
  equal((await f.publish()).status, 200);
  equal(f.state.uploads, 1);
  equal(f.state.finalizes, 1);
});
Deno.test("successful upload response without bytes is never publication proof", async () => {
  const f = fixture();
  f.state.noWrite = true;
  equal((await f.publish()).status, 503);
  equal(f.state.finalizes, 0);
});
Deno.test("corrupt stored bytes cannot finalize or leak details", async () => {
  const f = fixture();
  f.state.corrupt = true;
  const r = await f.publish();
  equal(r.status, 503);
  equal(f.state.finalizes, 0);
  equal((await r.text()).includes("secret"), false);
});
Deno.test("published missing object is never resurrected", async () => {
  const f = fixture();
  await f.publish();
  f.state.stored = null;
  equal((await f.publish()).status, 503);
  equal(f.state.uploads, 1);
});
Deno.test("changed authority during download prevents delivery", async () => {
  const f = fixture();
  await f.publish();
  f.state.revoked = true;
  equal(
    (await f.handler(
      f.request("download", { comment_id: f.intent.comment_id }),
    )).status,
    404,
  );
  equal(f.state.reads, 2);
});
Deno.test("mismatched receipt prevents Storage access", async () => {
  const f = fixture();
  f.state.wrongReceipt = true;
  equal((await f.publish()).status, 503);
  equal(f.state.uploads, 0);
  equal(f.state.calls.some((x) => x.includes("/storage/")), false);
});
Deno.test("feature gate rejects work without network, removal stays available", async () => {
  const f = fixture({ enabled: false });
  equal((await f.publish()).status, 503);
  equal(f.state.calls.length, 0);
  equal(
    (await f.handler(f.request("remove", { comment_id: f.intent.comment_id })))
      .status,
    200,
  );
});
Deno.test("actor mismatch rejected before commands", async () => {
  const f = fixture();
  f.state.authID = id();
  equal((await f.publish()).status, 401);
  equal(f.state.calls.length, 1);
});
Deno.test("machine actions and unknown parameters never reach backend", async () => {
  const f = fixture();
  for (
    const action of [
      "cleanup",
      "purged",
      "publish&extra=yes",
      "publish&action=list",
    ]
  ) equal((await f.handler(f.request(action, {}))).status, 400);
  equal(f.state.calls.length, 0);
});
Deno.test("budget rejection precedes request body consumption", async () => {
  const f = fixture();
  f.state.admission = false;
  let pulls = 0, cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull() {
      pulls++;
    },
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const r = await f.handler(
    new Request("https://edge.example.invalid/?action=publish", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + f.token,
        "Content-Type": "application/json",
      },
      body,
    }),
  );
  equal(r.status, 429);
  equal(r.headers.get("Retry-After"), "37");
  equal(pulls, 0);
  equal(cancelled, true);
});
Deno.test("malformed and forged audio envelopes never reserve", async () => {
  for (
    const change of [{ audio_base64: "AA==" }, { intent: {} }, {
      intent: { caption: "\ud800" },
    }, { unexpected: true }]
  ) {
    const f = fixture();
    const body = { intent: f.intent, audio_base64: base64(audio), ...change };
    if ("intent" in change && "caption" in change.intent!) {
      body.intent = { ...f.intent, ...change.intent };
    }
    equal((await f.handler(f.request("publish", body))).status, 400);
    equal(f.state.calls.some((x) => x.includes("comment_command")), false);
  }
});
Deno.test("upstream deadline works even when injected transport ignores abort", async () => {
  let cancelled = false;
  const handler = createAudioCommentsHandler({
    url: "https://gateway.example.invalid",
    serviceKey: "key",
    enabled: true,
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
  const f = fixture();
  const r = await handler(f.request("list", f.intent.target));
  equal(r.status, 503);
  await new Promise((r) => setTimeout(r, 80));
  equal(cancelled, true);
});
Deno.test("actual AAC fixture and maximum-size padded M4A pass bounded byte checks", async () => {
  equal(Math.abs(encodedMilliseconds(audio) - 1000) < 1000, true);
  await verifyAudio(audio, descriptor);
  const padded = new Uint8Array(maximumAudioBytes);
  padded.set(audio);
  const size = padded.length - audio.length;
  new DataView(padded.buffer).setUint32(audio.length, size);
  padded.set(new TextEncoder().encode("free"), audio.length + 4);
  const decoded = audio64(base64(padded));
  equal(decoded.length, maximumAudioBytes);
  await verifyAudio(decoded, {
    ...descriptor,
    byte_count: padded.length,
    sha256: await digest(padded),
  });
});

Deno.test("stored corruption also blocks authenticated download", async () => {
  const f = fixture();
  await f.publish();
  f.state.stored = new Uint8Array([1, 2, 3]);
  equal(
    (await f.handler(
      f.request("download", { comment_id: f.intent.comment_id }),
    )).status,
    503,
  );
  equal(f.state.reads, 1);
});
Deno.test("declared oversized input is rejected before Auth or body reads", async () => {
  const f = fixture();
  const r = f.request("publish", {});
  r.headers.set("Content-Length", "99999999");
  equal((await f.handler(r)).status, 413);
  equal(f.state.calls.length, 0);
});
Deno.test("stalled caller body is cancelled at deadline without publication", async () => {
  const f = fixture({ timeout: 50 });
  let cancelled = false;
  const stream = new ReadableStream<Uint8Array>({
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const r = await f.handler(
    new Request("https://edge.example.invalid/?action=publish", {
      method: "POST",
      headers: {
        Authorization: "Bearer " + f.token,
        "Content-Type": "application/json",
      },
      body: stream,
    }),
  );
  equal(r.status, 503);
  equal(cancelled, true);
  equal(f.state.uploads, 0);
  equal(f.state.finalizes, 0);
});
Deno.test("stored M4A truncation and duration/hash changes are rejected", async () => {
  for (
    const [bytes, metadata] of [
      [audio.subarray(0, audio.length - 1), descriptor],
      [audio, { ...descriptor, duration_ms: 120000 }],
      [audio, { ...descriptor, sha256: "f".repeat(64) }],
    ] as [Uint8Array, Row][]
  ) {
    let rejected = false;
    try {
      await verifyAudio(bytes, metadata);
    } catch {
      rejected = true;
    }
    equal(rejected, true);
  }
});

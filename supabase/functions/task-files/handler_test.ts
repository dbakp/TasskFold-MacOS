import { createTaskFilesHandler } from "./handler.ts";
type Row = Record<string, unknown>;
const equal = (a: unknown, b: unknown) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw new Error(`Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
  }
};
const bytes = new TextEncoder().encode("hello");
const digest = [...new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))]
  .map((v) => v.toString(16).padStart(2, "0")).join("");
const response = (r: unknown, status = 200) =>
  new Response(JSON.stringify(r), {
    status,
    headers: { "content-type": "application/json" },
  });
function fixture(options: { enabled?: boolean; timeout?: number } = {}) {
  const account = crypto.randomUUID(),
    session = crypto.randomUUID(),
    operation = crypto.randomUUID(),
    objectID = crypto.randomUUID();
  const target = {
    team_id: crypto.randomUUID(),
    project_id: crypto.randomUUID(),
    task_id: crypto.randomUUID(),
    task_generation: crypto.randomUUID(),
  };
  const intent = {
    operation_id: operation,
    target,
    name: "Workshop notes.txt",
    type: "text/plain",
    byte_count: 5,
    sha256: digest,
  };
  const attachment = {
    id: operation,
    storage_object_id: objectID,
    name: intent.name,
    size: 5,
    type: intent.type,
    sha256: digest,
    uploadedAt: "2026-11-01T22:00:00Z",
  };
  const receipt = (state = "published") => ({
    protocol: 1,
    account,
    operation_id: operation,
    target,
    state,
    attachment: state === "published" ? attachment : null,
  });
  const token = "e30." +
    btoa(JSON.stringify({ sub: account, session_id: session })).replaceAll(
      "=",
      "",
    ) + ".signature";
  const path = "team-task-files/v1/" + operation,
    calls: { path: string; method: string; body: unknown; headers: Headers }[] =
      [];
  let published = false;
  const state: {
    auth?: () => Response;
    rpc?: (action: string, body: Row) => Response | Promise<Response>;
    upload?: () => Response;
    stored?: () => Response;
  } = {};
  const send = async (request: Request) => {
    const url = new URL(request.url);
    equal(url.origin, "https://taskfold.invalid");
    equal(request.redirect, "error");
    const body = request.method === "POST"
      ? (url.pathname.startsWith("/rest/")
        ? await request.json()
        : new Uint8Array(await request.arrayBuffer()))
      : null;
    calls.push({
      path: url.pathname,
      method: request.method,
      body,
      headers: request.headers,
    });
    if (url.pathname === "/auth/v1/user") {
      equal(request.headers.get("authorization"), "Bearer " + token);
      return state.auth?.() ?? response({ id: account });
    }
    equal(request.headers.get("authorization"), "Bearer service-test-key");
    if (url.pathname === "/rest/v1/rpc/taskfold_task_file_command") {
      const b = body as Row;
      equal(b._actor, account);
      equal(b._session, session);
      if (state.rpc) return await state.rpc(String(b._action), b._body as Row);
      if (b._action === "reserve") {
        return response(
          published ? { status: "published", receipt: receipt() } : {
            status: "reserved",
            object_name: path,
            receipt: receipt("reserved"),
          },
        );
      }
      if (b._action === "finalize") {
        published = true;
        equal((b._body as Row).stored_sha256, digest);
        equal((b._body as Row).stored_bytes, 5);
        return response({ status: "published", receipt: receipt() });
      }
      if (b._action === "download") {
        return response({
          status: "download",
          object_name: path,
          sha256: digest,
          byte_count: 5,
          mime: "text/plain",
        });
      }
      if (b._action === "resolve") {
        return response({ status: "published", receipt: receipt() });
      }
      if (b._action === "cancel") {
        return response({ status: "cancelled", receipt: receipt("cancelled") });
      }
    }
    if (url.pathname === "/storage/v1/object/task-attachments/" + path) {
      equal(request.method, "POST");
      equal(request.headers.get("x-upsert"), "false");
      equal([...body as Uint8Array], [...bytes]);
      return state.upload?.() ?? response({ Key: "task-attachments/" + path });
    }
    if (
      url.pathname ===
        "/storage/v1/object/authenticated/task-attachments/" + path
    ) return state.stored?.() ?? new Response(bytes);
    throw new Error("Unexpected route");
  };
  const handler = createTaskFilesHandler({
    url: "https://taskfold.invalid",
    serviceKey: "service-test-key",
    enabled: options.enabled ?? true,
    timeoutMilliseconds: options.timeout,
  }, { send });
  const request = (
    action = "publish",
    body: unknown = { intent, bytes_base64: btoa("hello") },
    extra: RequestInit = {},
  ) =>
    new Request("https://edge.invalid/task-files?action=" + action, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer " + token,
      },
      body: JSON.stringify(body),
      ...extra,
    });
  return {
    account,
    session,
    operation,
    target,
    intent,
    objectID,
    path,
    calls,
    state,
    handler,
    request,
    receipt,
  };
}
Deno.test("publish verifies stored bytes and returns only the metadata receipt", async () => {
  const f = fixture(), r = await f.handler(f.request());
  equal(r.status, 200);
  equal(await r.json(), { receipt: f.receipt() });
  equal(f.calls.map((c) => c.method), ["GET", "POST", "POST", "GET", "POST"]);
  equal(r.headers.get("cache-control"), "private, no-store");
});
Deno.test("lost publication reply resolves without uploading or appending again", async () => {
  const f = fixture();
  equal((await f.handler(f.request())).status, 200);
  const count = f.calls.length;
  equal((await f.handler(f.request())).status, 200);
  equal(f.calls.slice(count).map((c) => c.path), [
    "/auth/v1/user",
    "/rest/v1/rpc/taskfold_task_file_command",
  ]);
});
Deno.test("normal no-overwrite provider collision is verified by reading the bytes", async () => {
  const f = fixture();
  f.state.upload = () => response({ message: "Asset exists" }, 400);
  equal((await f.handler(f.request())).status, 200);
});
for (const data of ["wrong", "hello!"]) {
  Deno.test("provider corruption cannot publish " + data, async () => {
    const f = fixture();
    f.state.stored = () => new Response(data);
    const r = await f.handler(f.request());
    equal(r.status, 409);
    equal(await r.json(), { error: "review" });
    equal(
      f.calls.filter((c) => (c.body as Row)?._action === "finalize").length,
      0,
    );
  });
}
Deno.test("verified download checks current access again after fetching bytes", async () => {
  const f = fixture();
  const r = await f.handler(
    f.request("download", {
      object_id: f.objectID,
      task_id: f.target.task_id,
      task_generation: f.target.task_generation,
    }),
  );
  equal(r.status, 200);
  equal(await r.text(), "hello");
  equal(r.headers.get("content-disposition"), "attachment");
  equal(r.headers.get("x-file-sha256"), digest);
  equal(
    f.calls.filter((c) => (c.body as Row)?._action === "download").length,
    2,
  );
});
Deno.test("access lost during provider download returns no content", async () => {
  const f = fixture();
  let n = 0;
  f.state.rpc = () =>
    response(
      ++n === 1
        ? {
          status: "download",
          object_name: f.path,
          sha256: digest,
          byte_count: 5,
          mime: "text/plain",
        }
        : { status: "unavailable" },
    );
  const r = await f.handler(
    f.request("download", {
      object_id: f.objectID,
      task_id: f.target.task_id,
      task_generation: f.target.task_generation,
    }),
  );
  equal(r.status, 404);
  equal(await r.json(), { error: "unavailable" });
});
Deno.test("cancelled operation never uploads", async () => {
  const f = fixture();
  f.state.rpc = () =>
    response({ status: "cancelled", receipt: f.receipt("cancelled") });
  equal((await f.handler(f.request())).status, 200);
  equal(f.calls.length, 2);
});
Deno.test("reserve response cannot redirect the service credential to another path", async () => {
  const f = fixture();
  f.state.rpc = () =>
    response({
      status: "reserved",
      object_name: "https://outside.invalid",
      receipt: f.receipt("reserved"),
    });
  equal((await f.handler(f.request())).status, 503);
  equal(f.calls.length, 2);
});
for (
  const status of [
    "unavailable",
    "quota",
    "disabled",
    "conflict",
    "verification_failed",
  ]
) {
  Deno.test("database refusal stays private: " + status, async () => {
    const f = fixture();
    f.state.rpc = () => response({ status });
    const r = await f.handler(f.request());
    equal(
      r.status,
      status === "unavailable" ? 404 : status === "disabled" ? 503 : 409,
    );
    equal(f.calls.length, 2);
  });
}
Deno.test("disabled entry point makes no network request", async () => {
  const f = fixture({ enabled: false });
  equal((await f.handler(f.request())).status, 503);
  equal(f.calls.length, 0);
});
Deno.test("resolve and cancellation remain available while publishing is disabled", async () => {
  const f = fixture({ enabled: false });
  for (const action of ["resolve", "cancel"]) {
    equal(
      (await f.handler(f.request(action, { operation_id: f.operation })))
        .status,
      200,
    );
  }
});
Deno.test("live Auth identity must agree with JWT subject", async () => {
  const f = fixture();
  f.state.auth = () => response({ id: crypto.randomUUID() });
  equal((await f.handler(f.request())).status, 401);
  equal(f.calls.length, 1);
});
Deno.test("a rejected live session never reaches service SQL", async () => {
  const f = fixture();
  f.state.auth = () => response({ error: "expired" }, 401);
  equal((await f.handler(f.request())).status, 401);
  equal(f.calls.length, 1);
});
for (
  const replacement of [
    { name: "../secret" },
    { type: "text/html" },
    { byte_count: 0 },
    { sha256: "f".repeat(64) },
    { operation_id: "not-an-id" },
  ]
) {
  Deno.test(
    "invalid intent never reaches SQL " + Object.keys(replacement)[0] +
      JSON.stringify(replacement),
    async () => {
      const f = fixture();
      equal(
        (await f.handler(
          f.request("publish", {
            intent: { ...f.intent, ...replacement },
            bytes_base64: btoa("hello"),
          }),
        )).status,
        400,
      );
      equal(f.calls.length, 1);
    },
  );
}
Deno.test("client cannot supply a stored-byte proof", async () => {
  const f = fixture();
  equal(
    (await f.handler(
      f.request("publish", {
        intent: f.intent,
        bytes_base64: btoa("hello"),
        stored_sha256: digest,
      }),
    )).status,
    400,
  );
  equal(f.calls.length, 1);
});
Deno.test("oversized request is stopped before SQL or Storage", async () => {
  const f = fixture();
  const r = await f.handler(
    f.request("publish", { bytes_base64: "A".repeat(7100001) }),
  );
  equal(r.status, 413);
  equal(f.calls.length, 1);
});
Deno.test("unresponsive upstream is bounded even if it ignores abort", async () => {
  const handler = createTaskFilesHandler({
    url: "https://taskfold.invalid",
    serviceKey: "test-key",
    enabled: true,
    timeoutMilliseconds: 50,
  }, { send: () => new Promise<Response>(() => {}) });
  const r = await handler(
    new Request("https://edge.invalid/task-files?action=publish", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        authorization: "Bearer token",
      },
      body: "{}",
    }),
  );
  equal(r.status, 503);
  equal(await r.json(), { error: "retry" });
});

Deno.test("live request budget returns a bounded retry delay", async () => {
  const f = fixture();
  f.state.rpc = () => response({ status: "rate_limited", retry_after: 10 });
  const r = await f.handler(f.request());
  equal(r.status, 429);
  equal(r.headers.get("retry-after"), "10");
  equal(f.calls.length, 2);
});

const senderStop = (f: ReturnType<typeof fixture>) => ({
  protocol: 1,
  sender_stop_protocol: 1,
  account: f.account,
  operation_id: f.operation,
  state: "cancelled",
});
Deno.test("unknown sender cancellation returns only a durable operation stop", async () => {
  const f = fixture({ enabled: false });
  f.state.rpc = () => response({ status: "cancelled", receipt: senderStop(f) });
  const result = await f.handler(
    f.request("cancel", { operation_id: f.operation }),
  );
  equal(result.status, 200);
  equal(await result.json(), { receipt: senderStop(f) });
  equal(f.calls.length, 2);
});
Deno.test("a stopped operation never starts provider work on publish retry", async () => {
  const f = fixture();
  f.state.rpc = () => response({ status: "cancelled", receipt: senderStop(f) });
  const result = await f.handler(f.request());
  equal(result.status, 200);
  equal(await result.json(), { receipt: senderStop(f) });
  equal(f.calls.length, 2);
});
for (
  const changed of [
    { sender_stop_protocol: 2 },
    { account: crypto.randomUUID() },
    { operation_id: crypto.randomUUID() },
    { state: "published" },
  ]
) {
  Deno.test(
    "sender stop must bind version actor operation and terminal state " +
      Object.keys(changed)[0],
    async () => {
      const f = fixture();
      f.state.rpc = () =>
        response({
          status: "cancelled",
          receipt: { ...senderStop(f), ...changed },
        });
      equal(
        (await f.handler(f.request("cancel", { operation_id: f.operation })))
          .status,
        503,
      );
    },
  );
}

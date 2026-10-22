import { createHandler } from "./handler.ts";
const owner = "f084cafe-0000-4000-8000-000000000001",
  other = "f084cafe-0000-4000-8000-000000000002",
  session = "f084cafe-0000-4000-8000-000000000010";
const config = {
  url: "https://removal.test",
  serviceKey: "private-service-fixture",
};
const token = (subject = owner) =>
  "header." + btoa(JSON.stringify({ sub: subject, session_id: session })) +
  ".signature";
const request = (body: unknown = {}, secret = token(), method = "POST") =>
  new Request("https://edge.test", {
    method,
    headers: { Authorization: "Bearer " + secret },
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
const assert = (value: unknown, message: string) => {
  if (!value) throw new Error(message);
};
const response = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
function fixture(
  options: {
    auth?: number;
    complete?: boolean;
    storageFailure?: boolean;
    prepareOther?: boolean;
    beginDenied?: boolean;
    repeatFiles?: boolean;
    corruptGrant?: boolean;
    loseDeleteReply?: boolean;
    pending?: boolean;
    malformedBucket?: boolean;
  } = {},
) {
  const calls: string[] = [];
  let authorized = options.pending ?? options.complete ?? false,
    complete = options.complete ?? false,
    removed = false,
    batches = 0;
  const send = async (req: Request) => {
    calls.push(req.method + " " + new URL(req.url).pathname);
    assert(
      req.headers.get("apikey") === config.serviceKey,
      "Missing server API key",
    );
    const path = new URL(req.url).pathname;
    if (path === "/auth/v1/user") {
      assert(
        req.headers.get("Authorization") === "Bearer " + token(),
        "Auth did not receive the actual caller token",
      );
      return response({
        id: owner,
        user_metadata: { account: other, admin: true },
      }, options.auth ?? 200);
    }
    assert(
      req.headers.get("Authorization") === "Bearer " + config.serviceKey,
      "Server credentials not confined to server calls",
    );
    if (path.endsWith("_status")) {
      return response(
        options.corruptGrant
          ? { account: owner, complete: "true" }
          : authorized
          ? { account: owner, complete }
          : null,
      );
    }
    if (path.endsWith("_begin")) {
      const input = await req.json();
      assert(
        input._account === owner && input._session === session &&
          /^[0-9a-f]{64}$/.test(input._token_hash),
        "Unverified account/session/raw token reached RPC",
      );
      if (options.beginDenied) {
        return response({ code: "28000", message: "PRIVATE AUTH DETAIL" }, 400);
      }
      authorized = true;
      return response({ account: owner, complete: false });
    }
    if (path.endsWith("_files")) {
      batches++;
      return response(
        options.repeatFiles || batches === 1
          ? [{
            bucket: options.malformedBucket ? ".." : "avatars",
            name: owner + "/avatar.jpg",
          }]
          : [],
      );
    }
    if (path === "/storage/v1/object/avatars") {
      assert(
        req.method === "DELETE" &&
          (await req.json()).prefixes[0] === owner + "/avatar.jpg",
        "Wrong object removed",
      );
      return response(
        { message: "PRIVATE STORAGE ERROR" },
        options.storageFailure ? 500 : 200,
      );
    }
    if (path.endsWith("_prepare")) {
      return response(options.prepareOther ? other : owner);
    }
    if (path === "/auth/v1/admin/users/" + owner && req.method === "DELETE") {
      assert(
        (await req.json()).should_soft_delete === false,
        "Soft deletion enabled",
      );
      if (removed) return response({ message: "No user" }, 404);
      removed = true;
      if (options.loseDeleteReply) throw new Error("PRIVATE LOST ACK");
      return response({ user: { id: owner } });
    }
    if (path === "/auth/v1/admin/users/" + owner && req.method === "GET") {
      return response({ message: "No user" }, removed ? 404 : 200);
    }
    if (path.endsWith("_complete")) {
      assert(removed, "Receipt confirmed before Auth deletion");
      complete = true;
      return response(true);
    }
    throw new Error("Unexpected endpoint " + path);
  };
  return { handler: createHandler(config, { send }), calls };
}
Deno.test("missing token, method and target-bearing/malformed requests make no service call", async () => {
  const f = fixture();
  assert(
    (await f.handler(new Request("https://edge.test", { method: "POST" })))
      .status === 401,
    "Anonymous removal accepted",
  );
  assert(
    (await f.handler(request({}, token(), "GET"))).status === 405,
    "GET mutated data",
  );
  for (const body of [{ account: other }, [], null]) {
    assert(
      (await f.handler(request(body))).status === 400,
      "Caller nominated a target",
    );
  }
  assert(
    (await f.handler(request({ data: "x".repeat(2100) }))).status === 413,
    "Oversized input accepted",
  );
  assert(f.calls.length === 0, "Rejected request accessed service");
});
Deno.test("real caller identity and active-session RPC authorize storage before hard Auth deletion", async () => {
  const f = fixture(), result = await f.handler(request());
  assert(
    result.status === 200 && (await result.json()).deleted === true,
    "Removal failed",
  );
  assert(
    f.calls.indexOf("DELETE /storage/v1/object/avatars") <
      f.calls.indexOf("DELETE /auth/v1/admin/users/" + owner),
    "Auth deleted before storage",
  );
});
Deno.test("invalid authentication and revoked sessions cannot start a deletion", async () => {
  for (const options of [{ auth: 401 }, { beginDenied: true }]) {
    const f = fixture(options), result = await f.handler(request());
    assert(result.status === 401, "Unauthorized operation accepted");
    assert(
      !f.calls.some((x) => x.startsWith("DELETE")),
      "Unauthorized deletion performed",
    );
    assert(!(await result.text()).includes("PRIVATE"), "Private error exposed");
  }
});
Deno.test("completed receipt confirms a lost reply without reauthenticating or deleting again", async () => {
  const f = fixture({ complete: true }), result = await f.handler(request());
  assert(result.status === 200, "Receipt unavailable");
  assert(
    f.calls.length === 1 && f.calls[0].endsWith("_status"),
    "Replay changed data",
  );
});
Deno.test("storage failure leaves Auth intact and returns bounded private-safe recovery", async () => {
  const f = fixture({ storageFailure: true }), r = await f.handler(request());
  assert(r.status === 503, "Storage failure reported success");
  assert(
    !f.calls.some((x) => x.includes("/admin/users/")),
    "Auth removed after failed object cleanup",
  );
  assert(!(await r.text()).includes("PRIVATE"), "Service details leaked");
});
Deno.test("changed owner or corrupt authorization refuses before Auth deletion", async () => {
  for (const options of [{ prepareOther: true }, { corruptGrant: true }]) {
    const f = fixture(options), r = await f.handler(request());
    assert(r.status === 503, "Invalid authority accepted");
    assert(
      !f.calls.some((x) => x.includes("/admin/users/")),
      "Foreign Auth deletion attempted",
    );
  }
});
Deno.test("file batches are bounded and unfinished cleanup cannot report success", async () => {
  const f = fixture({ repeatFiles: true }), r = await f.handler(request());
  assert(r.status === 503, "Unfinished cleanup accepted");
  assert(
    f.calls.filter((x) => x.startsWith("DELETE /storage")).length === 8,
    "Unbounded file cleanup",
  );
  assert(
    !f.calls.some((x) => x.includes("/admin/users/")),
    "Account removed before files finished",
  );
});
Deno.test("transport exceptions and missing configuration never expose secrets", async () => {
  const broken = createHandler(config, {
      send: () => {
        throw new Error("PRIVATE SERVICE CREDENTIAL");
      },
    }),
    r = await broken(request());
  assert(
    r.status === 503 && !(await r.text()).includes("PRIVATE"),
    "Transport detail leaked",
  );
  assert(
    (await createHandler({ ...config, serviceKey: "" })(request())).status ===
      503,
    "Missing secret accepted",
  );
});

Deno.test("lost Auth deletion reply resumes the existing command and confirms absence", async () => {
  const f = fixture({ loseDeleteReply: true });
  assert(
    (await f.handler(request())).status === 503,
    "A lost reply pretended success",
  );
  assert(
    (await f.handler(request())).status === 200,
    "Authorized retry did not finish",
  );
  assert(
    f.calls.filter((x) => x === "GET /auth/v1/user").length === 1,
    "Retry required deleted credentials",
  );
  assert(
    f.calls.includes("GET /auth/v1/admin/users/" + owner),
    "Retry did not confirm absent user",
  );
});
Deno.test("pending receipt resumes without treating revoked credentials as a new authorization", async () => {
  const f = fixture({ pending: true, auth: 401 });
  assert(
    (await f.handler(request())).status === 200,
    "Authorized pending command could not finish",
  );
  assert(
    !f.calls.some((x) => x === "GET /auth/v1/user" || x.endsWith("_begin")),
    "Pending command reauthorized revoked session",
  );
});
Deno.test("service authentication outages remain retryable and invalid bucket paths never reach Storage", async () => {
  const outage = fixture({ auth: 503 }),
    bad = fixture({ malformedBucket: true });
  assert(
    (await outage.handler(request())).status === 503,
    "Auth outage requested a new login",
  );
  assert(
    (await bad.handler(request())).status === 503,
    "Invalid bucket was accepted",
  );
  assert(
    !bad.calls.some((x) => x.startsWith("DELETE")),
    "Untrusted path reached deletion",
  );
});
Deno.test("malformed JSON and a stalled caller body are refused without credentials reaching any service", async () => {
  const f = fixture(), headers = { Authorization: "Bearer " + token() };
  assert(
    (await f.handler(
      new Request("https://edge.test", { method: "POST", headers, body: "{" }),
    )).status === 400,
    "Malformed JSON accepted",
  );
  const stalled = new ReadableStream<Uint8Array>({ start() {}, cancel() {} });
  const req = new Request(
    "https://edge.test",
    { method: "POST", headers, body: stalled, duplex: "half" } as RequestInit,
  );
  assert((await f.handler(req)).status === 408, "Stalled body not bounded");
  assert(f.calls.length === 0, "Rejected bodies touched service");
});

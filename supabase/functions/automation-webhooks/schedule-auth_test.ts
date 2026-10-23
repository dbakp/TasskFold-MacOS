import { admitScheduledWebhook } from "./schedule-auth.ts";
const token = "a".repeat(64),
  project = "abcdefghijklmnopqrst",
  nonce = "12345678-1234-4234-8234-123456789abc";
const config = {
  url: `https://${project}.supabase.co`,
  serviceKey: "fixture-service-only",
  workerToken: token,
};
const assert = (ok: unknown) => {
  if (!ok) throw Error("Scheduled admission assertion failed");
};
async function proof(
  issued = Math.floor(Date.now() / 1000),
  ref = project,
  key = token,
) {
  const secret = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      "HMAC",
      secret,
      new TextEncoder().encode(
        `taskfold.webhook.schedule.v1.${issued}.${nonce}.${ref}`,
      ),
    ),
  );
  return `Taskfold-Schedule ${issued}.${nonce}.${
    Array.from(signature, (b) => b.toString(16).padStart(2, "0")).join("")
  }`;
}
Deno.test("signed schedule uses fixed service-only one-use admission", async () => {
  let calls = 0;
  const send = async (request: Request) => {
    calls++;
    assert(
      request.url ===
        config.url + "/rest/v1/rpc/taskfold_webhook_schedule_admit",
    );
    assert(request.redirect === "error");
    assert(request.credentials === "omit");
    assert(
      request.headers.get("Authorization") === "Bearer fixture-service-only",
    );
    const body = await request.json();
    assert(body._nonce === nonce);
    return new Response("true");
  };
  assert(await admitScheduledWebhook(await proof(), config, send));
  assert(calls === 1);
});
Deno.test("bad signature and wrong project never reach admission", async () => {
  const send: typeof fetch = () => {
    throw Error("Must not send");
  };
  assert(
    !await admitScheduledWebhook(
      await proof(undefined, project, "b".repeat(64)),
      config,
      send,
    ),
  );
  assert(
    !await admitScheduledWebhook(
      await proof(undefined, "bbbbbbbbbbbbbbbbbbbb"),
      config,
      send,
    ),
  );
});
Deno.test("expired future and malformed schedule never reach admission", async () => {
  let calls = 0;
  const send: typeof fetch = () => {
    calls++;
    return Promise.resolve(new Response("true"));
  };
  for (
    const header of [
      await proof(Math.floor(Date.now() / 1000) - 100),
      await proof(Math.floor(Date.now() / 1000) + 30),
      "Taskfold-Schedule nope",
      null,
    ]
  ) assert(!await admitScheduledWebhook(header, config, send));
  assert(calls === 0);
});
Deno.test("replayed admission and server errors fail closed", async () => {
  const header = await proof();
  for (
    const response of [
      new Response("false"),
      new Response("true", { status: 500 }),
      new Response("true ".repeat(20)),
    ]
  ) {
    assert(
      !await admitScheduledWebhook(
        header,
        config,
        () => Promise.resolve(response),
      ),
    );
  }
});
Deno.test("untrusted origin or invalid worker credential cannot authorize", async () => {
  const header = await proof();
  const send: typeof fetch = () => Promise.resolve(new Response("true"));
  assert(
    !await admitScheduledWebhook(header, {
      ...config,
      url: "https://evil.example",
    }, send),
  );
  assert(
    !await admitScheduledWebhook(header, { ...config, workerToken: "" }, send),
  );
});

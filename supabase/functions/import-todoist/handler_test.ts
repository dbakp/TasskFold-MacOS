import {
  ADMISSION_MAX_REQUESTS,
  ADMISSION_WINDOW_MS,
  createHandler,
  MAX_BODY_BYTES,
} from "./handler.ts";
const reply = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });
const eq = (a: unknown, b: unknown) => {
  if (a !== b) throw new Error(`${a} !== ${b}`);
};
function setup(gate?: Promise<void>) {
  let todoist = 0;
  const fetcher = (async (input) => {
    const path = new URL(String(input)).pathname;
    if (path === "/auth/v1/user") return reply({ id: "u" });
    todoist++;
    if (gate) await gate;
    if (path.endsWith("/user")) return reply({ id: "a" });
    return reply({ results: [], next_cursor: null });
  }) as typeof fetch;
  let now = 1_000_000;
  const handler = createHandler(
    { url: "https://fixture.invalid", key: "public" },
    fetcher,
    () => now,
  );
  return {
    handler,
    todoist: () => todoist,
    advance: (ms: number) => now += ms,
  };
}
const post = (body: BodyInit, headers: Record<string, string> = {}) =>
  new Request("https://fixture.invalid", {
    method: "POST",
    headers: { Authorization: "Bearer fixture", ...headers },
    body,
  });
const preview = () =>
  post(JSON.stringify({ userToken: "fixture-token-123456", preview: true }));
Deno.test("declared oversized body is refused before any service call", async () => {
  const s = setup();
  const big = "x".repeat(MAX_BODY_BYTES + 1);
  const r = await s.handler(
    post(big, { "Content-Length": String(big.length) }),
  );
  eq(r.status, 413);
  eq(s.todoist(), 0);
});
Deno.test("undeclared (streamed) oversized body is cut off and never reaches Todoist", async () => {
  const s = setup();
  const chunk = new Uint8Array(256 * 1024);
  let sent = 0;
  const stream = new ReadableStream({
    pull(c) {
      if (sent++ < 8) c.enqueue(chunk);
      else c.close();
    },
  });
  const r = await s.handler(post(stream));
  eq(r.status, 413);
  eq(s.todoist(), 0);
});
Deno.test("per-user budget returns 429 with Retry-After and recovers after the window", async () => {
  const s = setup();
  for (let i = 0; i < ADMISSION_MAX_REQUESTS; i++) {
    eq((await s.handler(preview())).status, 200);
  }
  const r = await s.handler(preview());
  eq(r.status, 429);
  eq(Number(r.headers.get("Retry-After")) > 0, true);
  const used = s.todoist();
  s.advance(ADMISSION_WINDOW_MS + 1);
  eq((await s.handler(preview())).status, 200);
  eq(s.todoist() > used, true);
});
Deno.test("a second import for the same user is refused while one is running", async () => {
  let open!: () => void;
  const s = setup(new Promise<void>((r) => open = r));
  const first = s.handler(preview());
  await new Promise((r) => setTimeout(r, 20));
  const second = await s.handler(preview());
  eq(second.status, 429);
  open();
  eq((await first).status, 200);
  eq((await s.handler(preview())).status, 200);
});
Deno.test("malformed JSON is a 400 that never reaches Todoist", async () => {
  const s = setup();
  eq((await s.handler(post("{", {}))).status, 400);
  eq(s.todoist(), 0);
});

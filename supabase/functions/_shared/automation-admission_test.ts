import { createAdmission, forwardedIP } from "./automation-admission.ts";
import { createHandler as tasks } from "../automation-tasks/handler.ts";
import { createHandler as keys } from "../automation-keys/handler.ts";
const config = {
  url: "https://admission.test",
  serviceKey: "synthetic-private-service",
  forwardedForMode: "supabase-append-v1",
};
const assert = (condition: unknown, message = "Assertion failed") => {
  if (!condition) throw new Error(message);
};
const request = (
  authorization = "Bearer synthetic-credential",
  ip = "192.0.2.10",
) =>
  new Request("https://edge.test", {
    method: "POST",
    headers: { Authorization: authorization, "X-Forwarded-For": ip },
    body: '{"action":"list","body":{}}',
  });
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status });
const allow = { allowed: true, retry_after: 0, limited_by: null };
Deno.test("forwarded identity requires the explicit trusted append contract and canonicalizes only its last hop", () => {
  assert(forwardedIP(request(), undefined) === null);
  assert(forwardedIP(request(), "other") === null);
  assert(
    forwardedIP(
      request("Bearer x", "spoofed, 192.0.2.10"),
      config.forwardedForMode,
    ) === "192.0.2.10",
  );
  assert(
    forwardedIP(
      request("Bearer x", "2001:0DB8:0000::1"),
      config.forwardedForMode,
    ) === "2001:db8::1",
  );
  for (
    const ip of [
      "192.0.2.999",
      "192.000.2.10",
      "192.0.2.10:80",
      "192.0.2.10,",
      "[2001:db8::1]",
      "fe80::1%en0",
      "garbage",
    ]
  ) {
    assert(
      forwardedIP(request("Bearer x", ip), config.forwardedForMode) === null,
      "Accepted invalid IP: " + ip,
    );
  }
});
Deno.test("unset proxy contract or invalid origin fails closed without reading input or contacting service", async () => {
  let calls = 0;
  for (
    const settings of [
      { ...config, forwardedForMode: undefined },
      { ...config, url: "http://admission.test" },
      { ...config, url: "https://admission.test/other" },
      { ...config, serviceKey: "" },
    ]
  ) {
    const gate = createAdmission(settings, "tasks", () => {
      calls++;
      throw new Error();
    });
    assert((await gate(request()))?.status === 503);
  }
  assert(calls === 0);
});
Deno.test("admission forwards only domain-separated HMACs to fixed no-redirect RPC and never caches a positive grant", async () => {
  const calls: Request[] = [];
  const gate = createAdmission(config, "tasks", (req) => {
    calls.push(req.clone());
    return Promise.resolve(reply({ ...allow, private: "NEVER EXPOSE" }));
  });
  assert(await gate(request()) === null);
  assert(
    await gate(
      request("bEaReR synthetic-credential", "pretend, 192.0.2.10"),
    ) === null,
  );
  assert(calls.length === 2, "Positive grant cached");
  const first = await calls[0].json(), second = await calls[1].json();
  assert(
    calls[0].url ===
      "https://admission.test/rest/v1/rpc/taskfold_automation_admit",
  );
  assert(calls[0].redirect === "error");
  assert(
    JSON.stringify(first) === JSON.stringify(second),
    "Bearer casing/forged prefix changed identity",
  );
  assert(
    Object.keys(first).sort().join(",") === "_credential_hash,_ip_hash,_route",
  );
  assert(
    first._route === "tasks" && /^[a-f0-9]{64}$/.test(first._ip_hash) &&
      /^[a-f0-9]{64}$/.test(first._credential_hash),
  );
  assert(first._ip_hash !== first._credential_hash);
  assert(
    !JSON.stringify(first).includes("synthetic-credential") &&
      !JSON.stringify(first).includes("192.0.2.10"),
  );
});
Deno.test("IP/global/credential negative decisions reduce repeat service work but isolate dimensions and routes", async () => {
  for (const dimension of ["ip", "global", "credential"]) {
    let calls = 0;
    const gate = createAdmission(config, "tasks", () => {
      calls++;
      return Promise.resolve(
        reply({ allowed: false, retry_after: 60, limited_by: dimension }),
      );
    });
    const first = await gate(request());
    assert(first?.status === 429);
    assert(first!.headers.get("Retry-After") === "60");
    assert(first!.headers.get("Cache-Control") === "no-store");
    assert(
      !await first!.text().then((t) => t.includes(dimension)),
      "Internal dimension exposed",
    );
    assert((await gate(request()))?.status === 429);
    assert(calls === 1);
    await gate(request("Bearer another", "192.0.2.11"));
    assert(calls === (dimension === "global" ? 1 : 2));
  }
});
Deno.test("expired negative cache must reconsult durable admission", async () => {
  let calls = 0;
  const gate = createAdmission(config, "tasks", () => {
    calls++;
    return Promise.resolve(
      reply(
        calls === 1
          ? { allowed: false, retry_after: 1, limited_by: "ip" }
          : allow,
      ),
    );
  });
  assert((await gate(request()))?.status === 429);
  await new Promise((resolve) => setTimeout(resolve, 1050));
  assert(await gate(request()) === null);
  assert(calls === 2);
});
Deno.test("malformed, inconsistent, oversized and service-error receipts cannot authorize resource access", async () => {
  for (
    const body of [
      null,
      [],
      {},
      { ...allow, retry_after: 1 },
      { ...allow, limited_by: "ip" },
      { allowed: false, retry_after: 0, limited_by: "ip" },
      { allowed: false, retry_after: 61, limited_by: "ip" },
      { allowed: false, retry_after: 1, limited_by: "unknown" },
    ]
  ) {
    assert(
      (await createAdmission(
        config,
        "tasks",
        () => Promise.resolve(reply(body)),
      )(request()))?.status === 503,
    );
  }
  assert(
    (await createAdmission(
      config,
      "tasks",
      () => Promise.resolve(reply({ private: "x".repeat(3000) })),
    )(request()))
      ?.status === 503,
  );
  assert(
    (await createAdmission(
      config,
      "tasks",
      () => Promise.resolve(reply({ private: "SQL secret" }, 400)),
    )(request()))
      ?.status === 503,
  );
  assert(
    (await createAdmission(
      config,
      "tasks",
      () => Promise.reject(new Error("PRIVATE")),
    )(request()))?.status === 503,
  );
});
Deno.test("stalled response is cancelled at admission deadline", async () => {
  let cancelled = false;
  const gate = createAdmission(
    config,
    "tasks",
    () =>
      Promise.resolve(
        new Response(
          new ReadableStream({
            cancel() {
              cancelled = true;
            },
          }),
        ),
      ),
  );
  const started = performance.now();
  assert((await gate(request()))?.status === 503);
  assert(cancelled);
  assert(performance.now() - started < 3500);
});
Deno.test("both production handler factories admit before task validation, live Auth, body consumption or task effects", async () => {
  for (const factory of [tasks, keys]) {
    let calls = 0, cancelled = false;
    const handler = factory(config, {
      send: (req) => {
        calls++;
        assert(
          req.url.endsWith("/taskfold_automation_admit"),
          "Resource/Auth reached before gate",
        );
        return Promise.resolve(
          reply({ allowed: false, retry_after: 5, limited_by: "ip" }),
        );
      },
    });
    const req = new Request("https://edge.test", {
      method: "POST",
      headers: { "X-Forwarded-For": "192.0.2.10" },
      body: new ReadableStream({
        cancel() {
          cancelled = true;
        },
      }),
    });
    assert((await handler(req)).status === 429);
    assert(cancelled);
    assert(calls === 1);
  }
});
Deno.test("task preflight remains available without admission while normal invalid requests consume a grant", async () => {
  let calls = 0;
  const handler = tasks(config, {
    send: () => {
      calls++;
      return Promise.resolve(reply(allow));
    },
  });
  assert(
    (await handler(new Request("https://edge.test", { method: "OPTIONS" })))
      .status === 204,
  );
  assert(calls === 0);
  assert((await handler(request("Bearer invalid"))).status === 401);
  assert(calls === 1);
});

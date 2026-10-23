import { createIngressProbe } from "./automation-ingress-probe.ts";
const assert = (condition: unknown, message = "Assertion failed") => {
  if (!condition) throw new Error(message);
};
async function fixture() {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const config = {
    publicKey: await crypto.subtle.exportKey("jwk", pair.publicKey),
    expires: Date.now() + 60000,
    selfURL: "https://probe.test/functions/v1/owned-probe",
    fingerprintKey: "synthetic-private-fingerprint-key",
  };
  const value = (mode = "direct") => ({
    mode,
    at: Date.now(),
    nonce: crypto.randomUUID(),
  });
  const signed = async (body: unknown) => {
    const raw = JSON.stringify(body);
    const data = await crypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      pair.privateKey,
      new TextEncoder().encode(raw),
    );
    return {
      body: raw,
      signature: btoa(String.fromCharCode(...new Uint8Array(data))).replaceAll(
        "+",
        "-",
      ).replaceAll("/", "_").replaceAll("=", ""),
    };
  };
  const request = async (
    body: unknown = value(),
    headers: Record<string, string> = {},
  ) => {
    const message = await signed(body);
    return new Request(config.selfURL, {
      method: "POST",
      headers: {
        "X-Taskfold-Probe-Signature": message.signature,
        "X-Forwarded-For": "192.0.2.222, 8.8.8.8",
        ...headers,
      },
      body: message.body,
    });
  };
  return { config, value, signed, request };
}
Deno.test("probe verifies a signed fresh body and projects no raw addresses or service credential", async () => {
  const f = await fixture(),
    probe = createIngressProbe(f.config),
    body = f.value();
  const response = await probe(await f.request(body));
  assert(response.status === 200);
  assert(response.headers.get("Cache-Control") === "no-store");
  const text = await response.text();
  assert(!text.includes("8.8.8.8") && !text.includes(f.config.fingerprintKey));
  const result = JSON.parse(text);
  assert(
    result.nonce === body.nonce && result.hopCount === 2 &&
      result.injectedInPrefix && result.lastPublic,
  );
  assert(/^[a-f0-9]{64}$/.test(result.lastFingerprint));
});
Deno.test("probe rejects absent, altered and stale signatures before inspecting headers", async () => {
  const f = await fixture(), probe = createIngressProbe(f.config);
  const absent = await f.request();
  absent.headers.delete("X-Taskfold-Probe-Signature");
  assert((await probe(absent)).status === 401);
  const changed = await f.request();
  changed.headers.set("X-Taskfold-Probe-Signature", "A".repeat(86));
  assert((await probe(changed)).status === 401);
  assert(
    (await probe(await f.request({ ...f.value(), at: Date.now() - 120000 })))
      .status === 401,
  );
});
Deno.test("expired/misconfigured probe and unsupported method fail safely", async () => {
  const f = await fixture();
  assert(
    (await createIngressProbe({ ...f.config, expires: 0 })(await f.request()))
      .status === 410,
  );
  assert(
    (await createIngressProbe({ ...f.config, fingerprintKey: "" })(
      await f.request(),
    )).status === 503,
  );
  assert(
    (await createIngressProbe(f.config)(new Request(f.config.selfURL)))
      .status === 405,
  );
});
Deno.test("probe bounds and cancels a stalled body before any network relay", async () => {
  const f = await fixture();
  let cancelled = false, calls = 0;
  const controller = new AbortController();
  const req = new Request(f.config.selfURL, {
    method: "POST",
    signal: controller.signal,
    body: new ReadableStream({
      cancel() {
        cancelled = true;
      },
    }),
  });
  const result = createIngressProbe(f.config, () => {
    calls++;
    throw new Error();
  })(req);
  controller.abort();
  assert((await result).status === 400);
  assert(cancelled && calls === 0);
});
Deno.test("authenticated relay can only make one same-configured-endpoint request for a direct child", async () => {
  const f = await fixture(), child = await f.signed(f.value());
  let calls = 0;
  const probe = createIngressProbe(f.config, async (req) => {
    calls++;
    assert(req.url === f.config.selfURL && req.redirect === "error");
    assert(JSON.parse(await req.text()).mode === "direct");
    return new Response(
      JSON.stringify({
        nonce: JSON.parse(child.body).nonce,
        lastFingerprint: "a".repeat(64),
        canonicalLastHop: true,
      }),
    );
  });
  const result = await probe(
    await f.request({ ...f.value("relay"), child, spoof: true }),
  );
  assert(result.status === 200 && calls === 1);
  const nested = await f.signed(f.value("relay"));
  assert(
    (await probe(await f.request({ ...f.value("relay"), child: nested })))
      .status === 400,
  );
  assert(calls === 1);
});
Deno.test("relay error or wrong child receipt cannot masquerade as source proof", async () => {
  const f = await fixture(), child = await f.signed(f.value());
  const probe = createIngressProbe(
    f.config,
    () =>
      Promise.resolve(
        new Response(
          JSON.stringify({ nonce: "wrong", lastFingerprint: "PRIVATE" }),
        ),
      ),
  );
  const result = await probe(await f.request({ ...f.value("relay"), child }));
  assert(
    result.status === 503 &&
      !await result.text().then((t) => t.includes("PRIVATE")),
  );
});

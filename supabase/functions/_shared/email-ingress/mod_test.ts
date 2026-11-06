import {
  EmailIngressError,
  emailIngressLimits,
  prepareVerifiedEmailDelivery,
  verifyEmailEnvelope,
} from "./mod.ts";
import {
  createEmailIngressHandler,
  type EmailIngressDependencies,
  EmailJournalRefusal,
} from "./handler.ts";
import {
  fixtureConfig,
  fixtureEnvelope,
  fixtureNow,
  signedFixture,
} from "./fixtures.ts";
function equal(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw Error("Synthetic ingress assertion failed");
  }
}
async function fails(work: () => Promise<unknown>, reason: string) {
  try {
    await work();
  } catch (error) {
    if (error instanceof EmailIngressError && error.reason === reason) return;
    throw error;
  }
  throw Error("Expected refusal: " + reason);
}
function deps(events: string[] = []): EmailIngressDependencies {
  return {
    now: () => fixtureNow,
    admit: (phase) => {
      events.push(phase);
      return Promise.resolve({ allowed: true });
    },
    deliver: (args) => {
      events.push("deliver");
      equal(args._provider, "synthetic-adapter");
      return Promise.resolve({ accepted: true, replayed: false });
    },
  };
}
async function request(envelope: unknown = fixtureEnvelope()) {
  const { body, headers } = await signedFixture(envelope);
  return new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers,
    body,
  });
}
Deno.test("signed handoff uses attested envelope, never forged MIME authority headers", async () => {
  const { body, headers } = await signedFixture();
  const sealed = await verifyEmailEnvelope(
    body,
    headers,
    fixtureConfig,
    fixtureNow,
  );
  equal(Object.keys(sealed), ["provider", "deliveryID"]);
  const args = await prepareVerifiedEmailDelivery(sealed);
  equal(args._verified_sender, "intake-a@example.invalid");
  equal(args._received_at, fixtureEnvelope().receivedAt);
  equal(args._delivery_id, "original-receipt-1");
  equal(args._recipient_domain, "mail.example.invalid");
  equal(args._content.title, "Review the launch");
  equal(args._content.description, "Keep the original words.\n");
  equal(args._alias_hash.length, 64);
});
Deno.test("copied or fabricated envelopes cannot enter MIME preparation", async () => {
  const { body, headers } = await signedFixture();
  const sealed = await verifyEmailEnvelope(
    body,
    headers,
    fixtureConfig,
    fixtureNow,
  );
  await fails(
    () => prepareVerifiedEmailDelivery({ ...sealed }),
    "unverified_envelope",
  );
});
Deno.test("signature binds the exact body", async () => {
  const { body, headers } = await signedFixture();
  body[body.length - 2] ^= 1;
  await fails(
    () => verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow),
    "signature",
  );
});
for (
  const field of [
    "X-Taskfold-Mail-Key",
    "X-Taskfold-Mail-Time",
    "X-Taskfold-Mail-Signature",
  ]
) {
  Deno.test("missing signature component: " + field, async () => {
    const { body, headers } = await signedFixture();
    headers.delete(field);
    await fails(
      () => verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow),
      "signature",
    );
  });
}
for (const offset of [-301000, 301000]) {
  Deno.test("expired or future signature refused: " + offset, async () => {
    const { body, headers } = await signedFixture();
    await fails(
      () =>
        verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow + offset),
      "signature",
    );
  });
}
Deno.test("key rotation accepts configured previous key and refuses removed key", async () => {
  const { body, headers } = await signedFixture(
    undefined,
    fixtureNow,
    "previous",
  );
  await verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow);
  await fails(
    () =>
      verifyEmailEnvelope(body, headers, {
        ...fixtureConfig,
        keys: { current: fixtureConfig.keys.current },
      }, fixtureNow),
    "signature",
  );
});
Deno.test("new retry signature retains original receipt time and journal arguments", async () => {
  const envelope = fixtureEnvelope(fixtureNow - 3600000);
  const first = await signedFixture(envelope);
  const next = await signedFixture(envelope, fixtureNow + 120000);
  const a = await prepareVerifiedEmailDelivery(
    await verifyEmailEnvelope(
      first.body,
      first.headers,
      fixtureConfig,
      fixtureNow,
    ),
  );
  const b = await prepareVerifiedEmailDelivery(
    await verifyEmailEnvelope(
      next.body,
      next.headers,
      fixtureConfig,
      fixtureNow + 120000,
    ),
  );
  equal(a, b);
});
for (
  const patch of [
    { version: 2 },
    { provider: "attacker" },
    { senderVerified: false },
    { senderVerified: "true" },
    { recipient: "a".repeat(64) + "@other.invalid" },
    { recipient: "A".repeat(64) + "@mail.example.invalid" },
    { sender: "intake-a@example.invalid\n" },
    { sender: "name <intake-a@example.invalid>" },
    { deliveryID: "bad receipt" },
    { receivedAt: "2026-02-31T12:00:00.000Z" },
    { receivedAt: new Date(fixtureNow - 8 * 86400000).toISOString() },
    { receivedAt: new Date(fixtureNow + 301000).toISOString() },
    { raw: "YR==" },
    { raw: "" },
    { raw: "not base64" },
  ]
) {
  Deno.test(
    "signed invalid envelope is refused: " + Object.keys(patch)[0] +
      JSON.stringify(patch).slice(0, 40),
    async () => {
      const { body, headers } = await signedFixture({
        ...fixtureEnvelope(),
        ...patch,
      });
      await fails(
        () => verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow),
        "envelope",
      );
    },
  );
}
Deno.test("duplicate JSON fields and noncanonical encoding are refused", async () => {
  for (
    const text of [
      JSON.stringify(fixtureEnvelope(), null, 2),
      JSON.stringify(fixtureEnvelope()).replace(
        '"version":1',
        '"version":1,"version":1',
      ),
    ]
  ) {
    const { body, headers } = await signedFixture(
      undefined,
      fixtureNow,
      "current",
      fixtureConfig,
      text,
    );
    await fails(
      () => verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow),
      "envelope",
    );
  }
});
Deno.test("oversized bytes refused before signature or decoding", async () => {
  await fails(
    () =>
      verifyEmailEnvelope(
        new Uint8Array(emailIngressLimits.bodyBytes + 1),
        new Headers(),
        fixtureConfig,
        fixtureNow,
      ),
    "body_size",
  );
});
Deno.test("configuration changes during verification cannot retarget provider or domain", async () => {
  const config = { ...fixtureConfig, keys: { ...fixtureConfig.keys } };
  const { body, headers } = await signedFixture();
  const pending = verifyEmailEnvelope(body, headers, config, fixtureNow);
  config.provider = "changed";
  config.inboundDomain = "other.invalid";
  config.keys.current = "ff".repeat(32);
  equal(
    (await prepareVerifiedEmailDelivery(await pending))._provider,
    "synthetic-adapter",
  );
});
Deno.test("disabled or invalid configuration refuses without body/admission access", async () => {
  const events: string[] = [];
  const handler = createEmailIngressHandler({
    ...fixtureConfig,
    enabled: false,
  }, deps(events));
  equal((await handler(await request())).status, 503);
  equal(events, []);
});
Deno.test("handler requires explicit admission and journal wiring", async () => {
  const handler = createEmailIngressHandler(
    fixtureConfig,
    {} as EmailIngressDependencies,
  );
  equal((await handler(await request())).status, 503);
});
Deno.test("handler orders two admissions before one journal call", async () => {
  const events: string[] = [];
  const result = await createEmailIngressHandler(fixtureConfig, deps(events))(
    await request(),
  );
  equal(result.status, 200);
  equal(await result.json(), { accepted: true, replayed: false });
  equal(events, ["before_read", "verified", "deliver"]);
  equal(result.headers.get("Cache-Control"), "no-store");
});
Deno.test("bad signatures never receive verified admission or journal access", async () => {
  const events: string[] = [];
  const r = await request();
  r.headers.set("X-Taskfold-Mail-Signature", "00".repeat(32));
  equal(
    (await createEmailIngressHandler(fixtureConfig, deps(events))(r)).status,
    401,
  );
  equal(events, ["before_read"]);
});
for (const phase of ["before_read", "verified"]) {
  Deno.test("admission denial prevents later work: " + phase, async () => {
    const events: string[] = [];
    const dependencies = deps(events);
    dependencies.admit = (p) => {
      events.push(p);
      return Promise.resolve(
        p === phase ? { allowed: false, retryAfter: 5 } : { allowed: true },
      );
    };
    const result = await createEmailIngressHandler(fixtureConfig, dependencies)(
      await request(),
    );
    equal(result.status, 429);
    equal(
      events,
      phase === "before_read" ? ["before_read"] : ["before_read", "verified"],
    );
  });
}
Deno.test("verified admission precedes actual MIME decoding", async () => {
  const dependencies = deps();
  dependencies.admit = (phase) =>
    Promise.resolve(
      phase === "verified"
        ? { allowed: false, retryAfter: 1 }
        : { allowed: true },
    );
  const envelope = {
    ...fixtureEnvelope(),
    raw: btoa("Content-Type: application/pkcs7-mime\r\n\r\nencrypted"),
  };
  equal(
    (await createEmailIngressHandler(fixtureConfig, dependencies)(
      await request(envelope),
    )).status,
    429,
  );
});
Deno.test("unsupported MIME never reaches journal", async () => {
  const events: string[] = [];
  const envelope = {
    ...fixtureEnvelope(),
    raw: btoa("Content-Type: application/pkcs7-mime\r\n\r\nencrypted"),
  };
  equal(
    (await createEmailIngressHandler(fixtureConfig, deps(events))(
      await request(envelope),
    )).status,
    422,
  );
  equal(events, ["before_read", "verified"]);
});
Deno.test("malformed and lost journal replies never claim success or expose messages", async () => {
  for (
    const reply of [{ accepted: false }, { accepted: true, replayed: "yes" }]
  ) {
    const dependencies = deps();
    dependencies.deliver = () => Promise.resolve(reply as never);
    const r = await createEmailIngressHandler(fixtureConfig, dependencies)(
      await request(),
    );
    equal(r.status, 503);
  }
  const dependencies = deps();
  dependencies.deliver = () =>
    Promise.reject(Error("private alias and raw mail"));
  const r = await createEmailIngressHandler(fixtureConfig, dependencies)(
    await request(),
  );
  equal(await r.json(), { error: "uncertain" });
});
for (
  const [code, status] of [["PT409", 409], ["PT429", 429], ["PT404", 422], [
    "42501",
    422,
  ], ["PT503", 503]]
) {
  Deno.test("safe journal refusal projection: " + code, async () => {
    const dependencies = deps();
    dependencies.deliver = () =>
      Promise.reject(new EmailJournalRefusal(code as string));
    equal(
      (await createEmailIngressHandler(fixtureConfig, dependencies)(
        await request(),
      )).status,
      status,
    );
  });
}
Deno.test("request cancellation terminates an admission dependency ignoring its signal", async () => {
  const controller = new AbortController();
  const dependencies = deps();
  dependencies.admit = () => new Promise(() => {});
  const original = await request();
  const r = new Request(original, { signal: controller.signal });
  const pending = createEmailIngressHandler(fixtureConfig, dependencies)(r);
  controller.abort();
  equal((await pending).status, 503);
});
Deno.test("request cancellation terminates an actual pending stream read", async () => {
  const controller = new AbortController();
  let cancelled = false;
  let entered!: () => void;
  const reading = new Promise<void>((resolve) => entered = resolve);
  const body = new ReadableStream<Uint8Array>({
    pull() {
      entered();
    },
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const r = new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
    signal: controller.signal,
  });
  const pending = createEmailIngressHandler(fixtureConfig, deps())(r);
  await reading;
  controller.abort();
  equal((await pending).status, 503);
  equal(cancelled, true);
});

Deno.test("aborted uncertain commit can retry with exact original arguments", async () => {
  const controller = new AbortController();
  let entered!: () => void;
  const reached = new Promise<void>((resolve) => entered = resolve);
  const dependencies = deps();
  dependencies.deliver = () => {
    entered();
    return new Promise(() => {});
  };
  const pending = createEmailIngressHandler(fixtureConfig, dependencies)(
    new Request(await request(), { signal: controller.signal }),
  );
  await reached;
  controller.abort();
  equal((await pending).status, 503);
  const replay = deps();
  replay.deliver = () => Promise.resolve({ accepted: true, replayed: true });
  equal(
    await (await createEmailIngressHandler(fixtureConfig, replay)(
      await request(),
    )).json(),
    { accepted: true, replayed: true },
  );
});
Deno.test("maximum raw-message boundary verifies without recursive regex growth", async () => {
  const envelope = { ...fixtureEnvelope(), raw: btoa("x".repeat(1048576)) };
  const { body, headers } = await signedFixture(envelope);
  await verifyEmailEnvelope(body, headers, fixtureConfig, fixtureNow);
  const tooBig = await signedFixture({
    ...envelope,
    raw: btoa("x".repeat(1048577)),
  });
  await fails(
    () =>
      verifyEmailEnvelope(
        tooBig.body,
        tooBig.headers,
        fixtureConfig,
        fixtureNow,
      ),
    "envelope",
  );
});
Deno.test("microchunk amplification is bounded independently of byte count", async () => {
  let reads = 0, cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    pull(c) {
      reads++;
      c.enqueue(new Uint8Array());
    },
    cancel() {
      cancelled = true;
    },
  });
  const r = new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  equal(
    (await createEmailIngressHandler(fixtureConfig, deps())(r)).status,
    413,
  );
  equal(cancelled, true);
  equal(reads <= emailIngressLimits.streamChunks + 2, true);
});
Deno.test("oversized input chunk is cancelled without journal access", async () => {
  let cancelled = false;
  const events: string[] = [];
  const body = new ReadableStream<Uint8Array>({
    start(c) {
      c.enqueue(new Uint8Array(emailIngressLimits.bodyBytes + 1));
    },
    cancel() {
      cancelled = true;
    },
  });
  const r = new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers: { "Content-Type": "application/json", "Content-Length": "1" },
    body,
  });
  equal(
    (await createEmailIngressHandler(fixtureConfig, deps(events))(r)).status,
    413,
  );
  equal(cancelled, true);
  equal(events, ["before_read"]);
});
Deno.test("method and media-type refusals never start admission or commit", async () => {
  const events: string[] = [];
  const handler = createEmailIngressHandler(fixtureConfig, deps(events));
  equal(
    (await handler(new Request("https://fixture.invalid/mail"))).status,
    405,
  );
  equal(
    (await handler(
      new Request("https://fixture.invalid/mail", {
        method: "POST",
        body: "not mail",
      }),
    )).status,
    415,
  );
  equal(events, []);
});
Deno.test("malformed admission output cannot become permission", async () => {
  for (
    const value of [null, {}, { allowed: false, retryAfter: 0 }, {
      allowed: false,
      retryAfter: 900,
    }]
  ) {
    const dependencies = deps();
    dependencies.admit = () => Promise.resolve(value as never);
    equal(
      (await createEmailIngressHandler(fixtureConfig, dependencies)(
        await request(),
      )).status,
      503,
    );
  }
});
Deno.test("configuration snapshot keeps provider budget consistent during admission", async () => {
  const config = { ...fixtureConfig, keys: { ...fixtureConfig.keys } };
  const events: string[] = [];
  const dependencies = deps(events);
  dependencies.admit = (_phase, _headers, provider) => {
    equal(provider, "synthetic-adapter");
    config.provider = "changed";
    return Promise.resolve({ allowed: true });
  };
  equal(
    (await createEmailIngressHandler(config, dependencies)(await request()))
      .status,
    200,
  );
});
Deno.test("signature cannot cross deployment audiences or provider namespaces", async () => {
  const { body, headers } = await signedFixture();
  await fails(
    () =>
      verifyEmailEnvelope(body, headers, {
        ...fixtureConfig,
        audience: "other-environment",
      }, fixtureNow),
    "signature",
  );
  await fails(
    () =>
      verifyEmailEnvelope(body, headers, {
        ...fixtureConfig,
        provider: "another-adapter",
      }, fixtureNow),
    "signature",
  );
});

Deno.test("input deadline cancels a stalled reader without external intervention", async () => {
  let cancelled = false;
  const body = new ReadableStream<Uint8Array>({
    cancel() {
      cancelled = true;
    },
  }, { highWaterMark: 0 });
  const r = new Request("https://fixture.invalid/mail", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  const result = await createEmailIngressHandler(fixtureConfig, deps())(r);
  equal(result.status, 503);
  equal(await result.json(), { error: "deadline" });
  equal(cancelled, true);
});
Deno.test("compressed or transformed handoffs are refused before admission", async () => {
  const events: string[] = [];
  const r = await request();
  r.headers.set("Content-Encoding", "gzip");
  equal(
    (await createEmailIngressHandler(fixtureConfig, deps(events))(r)).status,
    415,
  );
  equal(events, []);
});

Deno.test("oversized header collections stop before admission", async () => {
  for (const mode of ["bytes", "count", "name"]) {
    const r = await request();
    const events: string[] = [];
    if (mode === "bytes") {
      r.headers.set(
        "X-Padding",
        "x".repeat(emailIngressLimits.headerBytes + 1),
      );
    } else if (mode === "name") {
      r.headers.set("X-" + "a".repeat(emailIngressLimits.headerBytes + 1), "x");
    } else {
      for (let i = 0; i <= emailIngressLimits.headerCount; i++) {
        r.headers.set("X-Padding-" + i, "x");
      }
    }
    equal(
      (await createEmailIngressHandler(fixtureConfig, deps(events))(r)).status,
      431,
    );
    equal(events, []);
  }
});

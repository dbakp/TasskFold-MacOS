import { createRemovalRepairHandler } from "./handler.ts";
const account = "f085cafe-0000-4000-8000-000000000001";
const other = "f085cafe-0000-4000-8000-000000000002";
const config = {
  url: "https://repair.test",
  serviceKey: "synthetic-server-key",
  maintenanceKey: "synthetic-operator-key-never-in-clients",
  enabled: true,
};
const file = (n = 1, bucket = "avatars") => ({
  id: `f085cafe-0000-4000-8000-${String(n).padStart(12, "0")}`,
  bucket,
  name: `${account}/file-${n}.txt`,
  stamp: "a".repeat(64),
});
const assert = (v: unknown, message = "assertion") => {
  if (!v) throw Error(message);
};
function fixture(
  options: {
    existing?: boolean;
    removeFailure?: boolean;
    keepFiles?: boolean;
    more?: boolean;
    changeBeforeDelete?: boolean;
    timeout?: boolean;
    files?: ReturnType<typeof file>[];
  } = {},
) {
  let files = options.files ?? [file()],
    now = 1700000000000,
    existing = options.existing ?? false;
  const calls: string[] = [];
  const send = async (request: Request): Promise<Response> => {
    const path = new URL(request.url).pathname;
    calls.push(request.method + " " + path);
    assert(request.redirect === "error");
    assert(
      request.headers.get("Authorization") === "Bearer " + config.serviceKey,
    );
    assert(request.headers.get("apikey") === config.serviceKey);
    if (options.timeout) return await new Promise(() => {});
    if (path.endsWith("_repair_manifest")) {
      if (
        options.changeBeforeDelete &&
        calls.filter((c) => c.includes("_repair_manifest")).length === 3
      ) files = files.map((f) => ({ ...f, stamp: "b".repeat(64) }));
      return Response.json(
        existing
          ? { code: "28000", message: "PRIVATE INTERNAL" }
          : { account, files, more: options.more ?? false },
        { status: existing ? 400 : 200 },
      );
    }
    if (path.endsWith("_absent")) {
      return Response.json(!existing && files.length === 0 && !options.more);
    }
    if (request.method === "DELETE") {
      if (options.removeFailure) {
        return Response.json({ message: "PRIVATE STORAGE FAILURE" }, {
          status: 503,
        });
      }
      const body = await request.json();
      assert(
        JSON.stringify(body) === JSON.stringify({
          prefixes: files.filter((f) => path.endsWith("/" + f.bucket)).map(
            (f) => f.name,
          ),
        }),
      );
      if (!options.keepFiles) {
        files = files.filter((f) => !path.endsWith("/" + f.bucket));
      }
      return Response.json([]);
    }
    throw Error("unexpected request");
  };
  const handler = createRemovalRepairHandler({
    ...config,
    timeoutMilliseconds: options.timeout ? 20 : undefined,
  }, { send, now: () => now });
  const call = (body: unknown, key = config.maintenanceKey) =>
    handler(
      new Request("https://edge.test", {
        method: "POST",
        headers: { "X-Taskfold-Removal-Repair": key },
        body: JSON.stringify(body),
      }),
    );
  const preview = async () => {
    const r = await call({ action: "preview", account });
    assert(r.status === 200);
    return await r.json();
  };
  return {
    call,
    preview,
    calls,
    files: () => files,
    setFiles: (v: typeof files) => {
      files = v;
    },
    expire: () => {
      now += 900001;
    },
    setExisting: () => {
      existing = true;
    },
    handler,
  };
}
Deno.test("disabled and unauthenticated operators cannot inspect or mutate", async () => {
  const f = fixture();
  assert((await f.call({ action: "preview", account }, "")).status === 401);
  assert(f.calls.length === 0);
  const disabled = createRemovalRepairHandler({ ...config, enabled: false });
  assert(
    (await disabled(new Request("https://edge.test", { method: "POST" })))
      .status === 503,
  );
});
Deno.test("preview is read-only and binds a reviewed complete cleanup", async () => {
  const f = fixture(), p = await f.preview();
  assert(p.files.length === 1 && typeof p.review === "string");
  assert(f.calls.every((c) => c.startsWith("POST ")));
  const r = await f.call({
    action: "repair",
    account,
    review: p.review,
    confirmation: account,
  });
  assert(r.status === 200);
  assert((await r.json()).complete === true);
  assert(f.files().length === 0);
});
Deno.test("existing Auth blocks manifests and new Auth blocks an approved plan", async () => {
  const a = fixture({ existing: true });
  assert((await a.call({ action: "preview", account })).status === 409);
  assert(a.calls.length === 1);
  const f = fixture(), p = await f.preview();
  f.setExisting();
  assert(
    (await f.call({
      action: "repair",
      account,
      review: p.review,
      confirmation: account,
    })).status === 409,
  );
  assert(!f.calls.some((c) => c.startsWith("DELETE")));
});
Deno.test("changed file ownership version identity and new files invalidate review", async () => {
  for (
    const change of [
      (x: ReturnType<typeof file>) => ({ ...x, stamp: "b".repeat(64) }),
      (x: ReturnType<typeof file>) => ({ ...x, id: other }),
      (x: ReturnType<typeof file>) => ({ ...x, name: "replaced" }),
    ]
  ) {
    const f = fixture(), p = await f.preview();
    f.setFiles([change(file())]);
    assert(
      (await f.call({
        action: "repair",
        account,
        review: p.review,
        confirmation: account,
      })).status === 409,
    );
    assert(!f.calls.some((c) => c.startsWith("DELETE")));
  }
  const f = fixture(), p = await f.preview();
  f.setFiles([file(), file(2)]);
  assert(
    (await f.call({
      action: "repair",
      account,
      review: p.review,
      confirmation: account,
    })).status === 409,
  );
});
Deno.test("review signature expiry target and explicit confirmation are mandatory", async () => {
  for (const mode of ["tamper", "expired", "other", "confirmation"]) {
    const f = fixture(), p = await f.preview();
    if (mode === "expired") f.expire();
    const r = await f.call({
      action: "repair",
      account: mode === "other" ? other : account,
      review: mode === "tamper" ? p.review.slice(0, -2) + "aa" : p.review,
      confirmation: mode === "confirmation"
        ? ""
        : mode === "other"
        ? other
        : account,
    });
    assert(r.status === 409);
    assert(!f.calls.some((c) => c.startsWith("DELETE")));
  }
});
Deno.test("private details stay private on partial and unconfirmed Storage results", async () => {
  for (const options of [{ removeFailure: true }, { keepFiles: true }]) {
    const f = fixture(options),
      p = await f.preview(),
      r = await f.call({
        action: "repair",
        account,
        review: p.review,
        confirmation: account,
      });
    assert(r.status === (options.removeFailure ? 503 : 202));
    assert(!(await r.text()).includes("PRIVATE"));
    assert(f.files().length === 1);
  }
});
Deno.test("two buckets require fresh checks and can complete one bounded plan", async () => {
  const f = fixture({ files: [file(), file(2, "task-attachments")] }),
    p = await f.preview();
  assert(
    (await f.call({
      action: "repair",
      account,
      review: p.review,
      confirmation: account,
    })).status === 200,
  );
  assert(f.calls.filter((c) => c.includes("_repair_manifest")).length === 4);
  assert(f.calls.filter((c) => c.startsWith("DELETE")).length === 2);
});
Deno.test("oversized duplicate and malformed manifests never become reviewed deletes", async () => {
  for (
    const files of [
      Array.from({ length: 101 }, (_, n) => file(n)),
      [file(), file()],
      [{ ...file(), bucket: ".." }],
      [{ ...file(), name: "a/../b" }],
      [{ ...file(), stamp: "bad" }],
    ]
  ) {
    const f = fixture({ files });
    assert((await f.call({ action: "preview", account })).status === 503);
    assert(!f.calls.some((c) => c.startsWith("DELETE")));
  }
});
Deno.test("caller paths options malformed input and oversized requests are refused", async () => {
  const f = fixture();
  for (
    const body of [
      { action: "preview", account, paths: ["outside"] },
      { action: "preview", account: "no" },
      { action: "unknown", account },
      { action: "preview", account, review: "x".repeat(5000) },
    ]
  ) assert((await f.call(body)).status >= 400);
  assert(f.calls.length === 0);
});
Deno.test("stalled upstream is bounded and never reports completion", async () => {
  const f = fixture({ timeout: true });
  assert((await f.call({ action: "preview", account })).status === 503);
});
Deno.test("normal client status proofs do not enter administrator repair", async () => {
  const f = fixture();
  const r = await f.handler(
    new Request("https://edge.test", {
      method: "POST",
      headers: {
        Authorization: "Bearer client-token",
        "X-Taskfold-Account-Removal-Proof": "opaque-status-proof",
      },
      body: JSON.stringify({ action: "preview", account }),
    }),
  );
  assert(r.status === 401);
  assert(f.calls.length === 0);
});

Deno.test("unreviewed remainder requires another preview after the100file batch", async () => {
  const f = fixture({
      more: true,
      files: Array.from({ length: 100 }, (_, n) => file(n + 1)),
    }),
    p = await f.preview();
  const r = await f.call({
    action: "repair",
    account,
    review: p.review,
    confirmation: account,
  });
  assert(r.status === 202);
  assert((await r.json()).reviewRequired === true);
});
Deno.test("last moment version change is checked before the Storage request", async () => {
  const f = fixture({ changeBeforeDelete: true }), p = await f.preview();
  assert(
    (await f.call({
      action: "repair",
      account,
      review: p.review,
      confirmation: account,
    })).status === 409,
  );
  assert(!f.calls.some((c) => c.startsWith("DELETE")));
});

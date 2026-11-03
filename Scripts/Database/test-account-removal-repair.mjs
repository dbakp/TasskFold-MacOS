import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createHash, randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";
import { createPostgresFixture, literal as lit } from "./postgres-fixture.mjs";
import { createStorageProvider } from "./storage-provider-fixture.mjs";
const report = {
  checks: {},
  hostedChanges: false,
  providerBytesTested: false,
  realAuthAdminClaimed: false,
  deployed: false,
};
const check = (name, a, b = true) => {
  assert.deepEqual(a, b, name);
  report.checks[name] = true;
  console.log("passed:", name);
};
let pg, storage, server, child;
const failures = [], rpcTrace = [];
let failOnDelete = 0, deleteCalls = 0;
try {
  pg = await createPostgresFixture({ advisors: true });
  const bootstrap = await readFile(
    new URL("./account-removal-bootstrap.sql", import.meta.url),
    "utf8",
  );
  const stub =
    "create table storage.objects(id uuid primary key default gen_random_uuid(),bucket_id text,name text,owner uuid,owner_id text);";
  assert.equal(bootstrap.split(stub).length, 2);
  const [before, after] = bootstrap.split(stub);
  await pg.raw(
    "create schema extensions;create extension pgcrypto with schema extensions;" +
      before,
  );
  storage = await createStorageProvider(pg);
  await pg.raw(after);
  for (
    const file of [
      "20261022193804_account_removal_service.sql",
      "20261022203333_account_removal_status_proofs.sql",
      "20261103105727_account_removal_residual_repair.sql",
    ]
  ) {
    const sql = await readFile(
      new URL("../../supabase/migrations/" + file, import.meta.url),
      "utf8",
    );
    if (file.includes("residual_repair")) {
      report.baselineAdvisors = await pg.advisors();
    }
    await pg.raw(sql);
    report[file] = createHash("sha256").update(sql).digest("hex");
  }
  const current = randomUUID(), outside = randomUUID();
  await pg.raw(
    `insert into auth.users(id,email) values(${
      lit(current)
    },'owner@example.invalid'),(${lit(outside)},'outside@example.invalid')`,
  );
  for (const id of ["avatars", "task-attachments", "shared-exports"]) {
    assert.equal(
      (await storage.request("/bucket", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, name: id, public: false }),
      })).status,
      200,
    );
  }
  const upload = async (bucket, name, owner) => {
    const token = owner
      ? storage.token({ role: "service_role", sub: owner })
      : storage.service;
    const bytes = Buffer.from("Synthetic residual proof " + name);
    const r = await storage.request("/object/" + bucket + "/" + name, {
      method: "POST",
      headers: { "Content-Type": "text/plain" },
      body: bytes,
    }, token);
    assert.equal(r.status, 200, await r.text());
    return bytes;
  };
  const own = current + "/canonical.txt",
    legacy = current + "/legacy.txt",
    foreign = own + ".outside",
    other = "another-prefix/owned.txt",
    unsupported = current + "/unclaimed.txt";
  await upload("avatars", own, current);
  await upload("task-attachments", legacy);
  const outsiderBytes = await upload("avatars", foreign, outside);
  await upload("shared-exports", other, current);
  const unclaimedBytes = await upload("shared-exports", unsupported);
  check(
    "provider metadata identifies actual canonical owner",
    await pg.scalar(
      `select to_jsonb(owner_id) from storage.objects where name=${lit(own)}`,
    ),
    current,
  );
  check(
    "ownerless legacy file is real provider metadata",
    await pg.scalar(
      `select to_jsonb(owner_id is null and owner is null) from storage.objects where name=${
        lit(legacy)
      }`,
    ),
  );
  // Client roles cannot inspect administrator repair manifests through either schema.
  for (const role of ["anon", "authenticated"]) {
    const result = await pg.raw(
      `set role ${role};select has_function_privilege(current_user,'public.taskfold_account_removal_repair_manifest(uuid)','execute')::text`,
    );
    check(role + " has no public repair RPC", result, "false");
    const result2 = await pg.raw(
      `select has_function_privilege(${
        lit(role)
      },'taskfold_private.account_removal_repair_manifest(uuid)','execute')::text`,
    );
    check(role + " has no private repair RPC", result2, "false");
    await assert.rejects(
      pg.raw(
        `set role ${role};select public.taskfold_account_removal_repair_manifest(${
          lit(current)
        })`,
      ),
      { code: "42501" },
    );
    check(role + " actual invocation denied", true);
  }
  const existing = await pg.value(
    `public.taskfold_account_removal_repair_manifest(${lit(current)})`,
  );
  check("existing Auth rejected by actual RPC", existing.code, "28000");
  server = createServer(async (req, res) => {
    try {
      if (req.url === "/auth/v1/user") {
        assert.equal(req.headers.apikey, "synthetic-loopback-service");
        assert.equal(
          req.headers.authorization,
          "Bearer expired-original-token",
        );
        res.writeHead(401);
        res.end("{}");
        return;
      }
      assert.equal(
        req.headers.authorization,
        "Bearer synthetic-loopback-service",
      );
      assert.equal(req.headers.apikey, "synthetic-loopback-service");
      let size = 0;
      const chunks = [];
      for await (const c of req) {
        size += c.length;
        assert(size <= 20000);
        chunks.push(c);
      }
      const bytes = Buffer.concat(chunks);
      const routes = {
        taskfold_account_removal_repair_manifest: ["_account"],
        taskfold_account_removal_absent: ["_account"],
        taskfold_account_removal_status: ["_token_hash"],
        taskfold_account_removal_proof_key: ["_id"],
      };
      if (req.url.startsWith("/rest/v1/rpc/")) {
        const fn = req.url.split("/").at(-1), args = routes[fn];
        assert(args);
        const body = JSON.parse(bytes);
        assert.deepEqual(Object.keys(body).sort(), [...args].sort());
        const values = args.map((k) =>
          body[k] === null ? "null" : lit(body[k])
        );
        const answer = await pg.value(
          `to_jsonb(public.${fn}(${values.join(",")}))`,
        );
        rpcTrace.push({
          rpc: fn,
          code: answer.code,
          valueType: typeof answer.value,
        });
        res.writeHead(answer.code ? 400 : 200, {
          "Content-Type": "application/json",
        });
        res.end(
          JSON.stringify(
            answer.code
              ? { code: answer.code, message: "PRIVATE FIXTURE" }
              : answer.value,
          ),
        );
        return;
      }
      if (
        req.url.startsWith("/storage/v1/object/") && req.method === "DELETE"
      ) {
        deleteCalls++;
        if (deleteCalls === failOnDelete) {
          failOnDelete = 0;
          res.writeHead(503);
          res.end('{"error":"PRIVATE STORAGE"}');
          return;
        }
        const response = await storage.request(
          req.url.slice("/storage/v1".length),
          {
            method: "DELETE",
            headers: { "Content-Type": "application/json" },
            body: bytes,
          },
        );
        res.writeHead(response.status, { "Content-Type": "application/json" });
        res.end(Buffer.from(await response.arrayBuffer()));
        return;
      }
      if (req.url === "/auth/v1/user") {
        res.writeHead(401);
        res.end("{}");
        return;
      }
      throw Error("route");
    } catch (error) {
      failures.push(error.message);
      res.writeHead(503);
      res.end("{}");
    }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  child = spawn("deno", [
    "run",
    "--allow-net=127.0.0.1",
    fileURLToPath(new URL("./account-removal-repair-http.ts", import.meta.url)),
    String(server.address().port),
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (b) => {
    stderr = (stderr + b).slice(-4000);
  });
  const port = await new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(
      () => reject(Error("handler startup " + stderr)),
      10000,
    );
    child.once("error", reject);
    child.once("exit", () => {
      clearTimeout(timer);
      reject(Error("handler exited " + stderr));
    });
    child.stdout.on("data", (b) => {
      buffer += b;
      for (const line of buffer.split("\n")) {
        try {
          const v = JSON.parse(line);
          if (v.ready) {
            clearTimeout(timer);
            resolve(v.ready);
          }
        } catch {}
      }
    });
  });
  const request = async (path, body, headers = {}) => {
    const r = await fetch("http://127.0.0.1:" + port + path, {
      method: "POST",
      headers: {
        "X-Taskfold-Removal-Repair": "synthetic-operator-key-never-in-clients",
        ...headers,
      },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(25000),
    });
    const value = await r.json();
    assert(!JSON.stringify(value).includes("PRIVATE"));
    return { status: r.status, body: value };
  };
  const preview = () =>
    request("/repair", { action: "preview", account: current });
  check(
    "handler refuses still-existing account",
    (await preview()).status,
    409,
  );
  check("no deletion on existing account", deleteCalls, 0);
  const proof = (await request("/proof", { account: current })).body.proof;
  assert.equal(typeof proof, "string");
  // Simulates the already-removed Auth precondition, not an Auth Admin HTTP pass.
  await pg.raw(`delete from auth.users where id=${lit(current)}`);
  const plan = await preview();
  check(
    "review lists exactly canonical and narrow legacy files",
    plan.body.files.map((f) => f.name).sort(),
    [own, legacy, other].sort(),
  );
  check("preview removes nothing", deleteCalls, 0);
  const clientStatus = () =>
    request("/status", {}, {
      Authorization: "Bearer expired-original-token",
      "X-Taskfold-Account-Removal": "2",
      "X-Taskfold-Account-Removal-Proof": proof,
    });
  check(
    "status proof cannot repair residual files",
    (await clientStatus()).status,
    401,
  );
  check("status read made no destructive call", deleteCalls, 0);
  await upload("avatars", current + "/added-after-review.txt", current);
  const apply = (p) =>
    request("/repair", {
      action: "repair",
      account: current,
      review: p.body.review,
      confirmation: current,
    });
  check(
    "real new object invalidates reviewed plan",
    (await apply(plan)).status,
    409,
  );
  check("changed review removed nothing", deleteCalls, 0);
  let next = await preview();
  failOnDelete = deleteCalls + 2;
  check(
    "real handler reports Storage failure honestly",
    (await apply(next)).status,
    503,
  );
  check(
    "first approved bucket bytes gone before partial failure",
    (await storage.request("/object/avatars/" + own)).status !== 200,
  );
  check(
    "later approved bucket remains after partial failure",
    (await storage.request("/object/task-attachments/" + legacy)).status,
    200,
  );
  check("files still block proof", (await clientStatus()).status, 401);
  next = await preview();
  check(
    "reviewed actual Storage cleanup completes",
    (await apply(next)).body.complete,
    true,
  );
  check(
    "old client status proof now confirms absence",
    (await clientStatus()).body,
    { deleted: true },
  );
  check(
    "metadata for deleted account absent",
    await pg.scalar(
      `select to_jsonb(public.taskfold_account_removal_absent(${
        lit(current)
      }))`,
    ),
  );
  for (
    const [bucket, name, bytes] of [["avatars", foreign, outsiderBytes], [
      "shared-exports",
      unsupported,
      unclaimedBytes,
    ]]
  ) {
    const response = await storage.request("/object/" + bucket + "/" + name);
    check(
      "foreign or unsupported file remains readable " + name,
      response.status,
      200,
    );
    check(
      "preserved bytes " + name,
      Buffer.from(await response.arrayBuffer()),
      bytes,
    );
  }
  for (
    const [bucket, name] of [["avatars", own], ["task-attachments", legacy], [
      "shared-exports",
      other,
    ]]
  ) {
    check(
      "removed bytes unavailable " + name,
      (await storage.request("/object/" + bucket + "/" + name)).status !== 200,
    );
  }
  check(
    "outsider Auth remains",
    await pg.scalar(`select count(*) from auth.users where id=${lit(outside)}`),
    1,
  );
  // A second plan cannot silently treat a same-path replacement as the reviewed object.
  const a = await upload("avatars", current + "/replacement.txt", current);
  assert(a.length);
  const replacement = await preview();
  assert.equal(
    (await storage.request("/object/avatars/" + current + "/replacement.txt", {
      method: "PUT",
      headers: { "Content-Type": "text/plain" },
      body: Buffer.from("Changed version"),
    }, storage.token({ role: "service_role", sub: current }))).status,
    200,
  );
  const oldCalls = deleteCalls;
  check(
    "provider version change refuses stale review",
    (await apply(replacement)).status,
    409,
  );
  check("version refusal calls no DELETE", deleteCalls, oldCalls);
  next = await preview();
  check(
    "new review finishes replacement",
    (await apply(next)).body.complete,
    true,
  );
  for (let offset = 0; offset < 101; offset += 4) {
    await Promise.all(
      Array.from({ length: Math.min(4, 101 - offset) }, (_, i) =>
        upload(
          "avatars",
          current + "/batch-" + String(offset + i).padStart(3, "0") + ".txt",
          current,
        )),
    );
  }
  const batch = await preview();
  check("actual provider plan is capped at100", batch.body.files.length, 100);
  check("actual provider reports unreviewed remainder", batch.body.more, true);
  const partial = await apply(batch);
  check(
    "bounded batch returns pending rather than false completion",
    partial.status,
    202,
  );
  check("pending batch requires another review", partial.body, {
    complete: false,
    reviewRequired: true,
  });
  check(
    "unreviewed101st object remains",
    await pg.scalar(
      `select count(*) from storage.objects where owner_id=${lit(current)}`,
    ),
    1,
  );
  check(
    "old review cannot remove the next batch",
    (await apply(batch)).status,
    409,
  );
  next = await preview();
  check(
    "fresh final review completes101objects",
    (await apply(next)).body.complete,
    true,
  );
  report.finalAdvisors = await pg.advisors();
  check("RPC adapter reports no private failures", failures, []);
  report.providerBytesTested = true;
  report.providerImage = storage.image;
  report.postgresVersion = pg.serverVersion;
} catch (error) {
  report.error = error.message;
  throw error;
} finally {
  report.rpcTrace = rpcTrace;
  report.adapterFailures = failures;
  if (child && child.exitCode === null) {
    child.kill("SIGTERM");
    await Promise.race([
      once(child, "exit"),
      new Promise((r) => setTimeout(r, 3000)),
    ]);
    if (child.exitCode === null) child.kill("SIGKILL");
  }
  if (server) {
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
  try {
    if (storage) report.storageRemoved = await storage.close();
  } finally {
    if (pg) report.databaseRemoved = await pg.close();
  }
  const output = process.env.TASKFOLD_REMOVAL_REPAIR_REPORT;
  if (output) {
    assert(/^\/tmp\/taskfold-[a-z0-9-]+\.json$/.test(output));
    await writeFile(output, JSON.stringify(report, null, 2) + "\n");
  }
  console.log(JSON.stringify({
    passed: Object.keys(report.checks).length,
    providerBytesTested: report.providerBytesTested,
    storageRemoved: report.storageRemoved,
    databaseRemoved: report.databaseRemoved,
    error: report.error,
  }));
}

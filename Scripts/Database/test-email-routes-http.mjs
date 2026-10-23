import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createPostgresFixture, literal } from "./postgres-fixture.mjs";
import { loadEmailIntakeSchema } from "./email-intake-schema.mjs";
const summary = {
  date: new Date().toISOString(),
  checks: {},
  hostedAcceptance: false,
  realDataChanged: false,
};
const id = (n) => "f0e1cafe-0000-4000-8000-" + String(n).padStart(12, "0");
const owner = id(1), other = id(2), session = id(11), otherSession = id(12);
const hash = (n) =>
  createHash("sha256").update("synthetic-alias-" + n).digest("hex");
const token = (account = owner, sid = session) =>
  "header." +
  Buffer.from(JSON.stringify({ sub: account, session_id: sid })).toString(
    "base64url",
  ) + ".signature";
const stamp = new Date().toISOString();
const setup = (n) => ({
  id: id(n),
  name: "Workflow inbox",
  project_id: null,
  alias_hash: hash(n),
  requested_at: stamp,
});
let db, bridge, child, gateway;
const same = (label, value, expected = true) => {
  summary.checks[label] = false;
  assert.deepEqual(value, expected, label);
  summary.checks[label] = true;
};
const scalar = (sql) => db.scalar(sql);
async function call(action, body = {}, bearer = token()) {
  const result = await fetch(gateway, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + bearer,
      "X-Taskfold-Email": "1",
      "X-Taskfold-Email-Domain": "mail.example.invalid",
      "X-Forwarded-For": "198.51.100.10",
      "CF-Connecting-IP": "198.51.100.10",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ action, body }),
    signal: AbortSignal.timeout(20000),
  });
  return { status: result.status, value: await result.json() };
}
try {
  db = await createPostgresFixture();
  summary.postgresVersion = db.serverVersion;
  await loadEmailIntakeSchema(db.raw);
  await db.raw(
    `insert into auth.users(id,email,email_confirmed_at) values(${
      literal(owner)
    },'intake-a@example.invalid',now()),(${
      literal(other)
    },'intake-b@example.invalid',now());insert into auth.sessions(id,user_id) values(${
      literal(session)
    },${literal(owner)}),(${literal(otherSession)},${
      literal(other)
    });insert into public.profiles(user_id) values(${literal(owner)}),(${
      literal(other)
    })`,
  );
  bridge = createServer(async (req, res) => {
    const finish = (status, value) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(value));
    };
    try {
      if (req.url === "/auth/v1/user") {
        const bearer = req.headers.authorization;
        if (bearer === "Bearer " + token()) return finish(200, { id: owner });
        if (bearer === "Bearer " + token(other, otherSession)) {
          return finish(200, { id: other });
        }
        return finish(401, { error: "Synthetic Auth refused" });
      }
      assert.equal(req.headers.authorization, "Bearer synthetic-service-only");
      let text = "";
      for await (const chunk of req) text += chunk;
      const body = JSON.parse(text);
      let expression;
      if (req.url === "/rest/v1/rpc/taskfold_automation_admit") {
        expression = `public.taskfold_automation_admit(${
          literal(body._route)
        },${literal(body._ip_hash)},${literal(body._credential_hash)})`;
      } else if (req.url === "/rest/v1/rpc/taskfold_email_routes") {
        expression = `public.taskfold_email_routes(${literal(body._account)},${
          literal(body._session)
        },${literal(body._action)},${
          literal(JSON.stringify(body._body))
        }::jsonb)`;
      } else throw Error("Unexpected bridge path");
      const result = await db.value(expression);
      return result.code
        ? finish(400, { code: result.code, message: "Fixture SQL diagnostic" })
        : finish(200, result.value);
    } catch {
      finish(500, { error: "Synthetic bridge failure" });
    }
  });
  bridge.listen(0, "127.0.0.1");
  await once(bridge, "listening");
  child = spawn("deno", [
    "run",
    "--allow-net=127.0.0.1",
    fileURLToPath(new URL("./email-routes-http-host.ts", import.meta.url)),
    "http://127.0.0.1:" + bridge.address().port,
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  child.stderr.on("data", (chunk) => stderr += chunk);
  gateway = await new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(
      () => reject(Error("Gateway startup deadline")),
      10000,
    );
    child.once("exit", () => {
      clearTimeout(timeout);
      reject(Error("Gateway exited: " + stderr.slice(0, 300)));
    });
    child.stdout.on("data", (chunk) => {
      output += chunk;
      const line = output.split("\n")[0];
      try {
        const value = JSON.parse(line);
        if (!Number.isInteger(value.port)) throw Error();
        clearTimeout(timeout);
        resolve("http://127.0.0.1:" + value.port);
      } catch {}
    });
  });
  let result = await call("list");
  same("HTTP list reports database disabled", [
    result.status,
    result.value.available,
    result.value.domain,
  ], [200, false, null]);
  result = await call("create", setup(21));
  same("HTTP disabled create refused", result.status, 503);
  await db.raw(
    "update taskfold_private.email_intake_config set enabled=true,provider='synthetic-adapter'",
  );
  result = await call("create", setup(21));
  same("HTTP create reaches actual service-role SQL", [
    result.status,
    result.value.route?.id,
  ], [200, id(21)]);
  same(
    "HTTP create does not reveal alias hash",
    JSON.stringify(result.value).includes(hash(21)),
    false,
  );
  same(
    "HTTP exact create retry",
    (await call("create", setup(21))).value,
    result.value,
  );
  const content = {
    title: "Email gateway proof",
    description: "Entire note\nsecond line",
    attachmentCount: 0,
  };
  const receivedAt = new Date().toISOString();
  const deliver = () =>
    db.value(
      `public.taskfold_email_deliver(${
        literal(hash(21))
      },'synthetic-adapter','receipt_1',${
        literal(receivedAt)
      },'intake-a@example.invalid',${literal(JSON.stringify(content))}::jsonb)`,
    );
  same(
    "gateway-created route captures one actual task",
    (await deliver()).value,
    { accepted: true, replayed: false },
  );
  result = await call("pause", { id: id(21), revision: 1 });
  same("HTTP pause persists", [
    result.status,
    result.value.route?.state,
    result.value.route?.revision,
  ], [200, "paused", 2]);
  same("HTTP paused route refuses capture", (await deliver()).code, "PT404");
  result = await call("resume", { id: id(21), revision: 2 });
  same("HTTP resume persists", [
    result.status,
    result.value.route?.state,
    result.value.route?.revision,
  ], [200, "active", 3]);
  same(
    "HTTP stale pause conflicts",
    (await call("pause", { id: id(21), revision: 1 })).status,
    409,
  );
  same(
    "HTTP cannot list another account routes",
    (await call("list", {}, token(other, otherSession))).value.routes,
    [],
  );
  same(
    "HTTP foreign route cannot be revoked",
    (await call(
      "revoke",
      { id: id(21), revision: 3 },
      token(other, otherSession),
    )).status,
    404,
  );
  result = await call("rotate", {
    id: id(21),
    revision: 3,
    replacement: setup(22),
  });
  same("HTTP atomic rotation returns both route identities", [
    result.status,
    result.value.route?.id,
    result.value.replaced?.id,
    result.value.replaced?.state,
  ], [200, id(22), id(21), "revoked"]);
  same(
    "HTTP exact rotation retry",
    (await call("rotate", { id: id(21), revision: 3, replacement: setup(22) }))
      .value,
    result.value,
  );
  same(
    "rotation prevents old address delivery",
    (await deliver()).code,
    "PT404",
  );
  same(
    "HTTP cancellation before setup",
    (await call("revoke", { id: id(23), revision: 0 })).value,
    { account: owner, id: id(23), cancelled: true },
  );
  same(
    "HTTP late cancelled create conflicts",
    (await call("create", setup(23))).status,
    409,
  );
  await db.raw(
    `update auth.sessions set not_after=clock_timestamp()-interval '1 second' where id=${
      literal(session)
    }`,
  );
  same(
    "HTTP SQL fences expired native session despite successful Auth",
    (await call("list")).status,
    401,
  );
  same(
    "gateway actions never duplicate captured task",
    await scalar("select to_jsonb(count(*)::int) from public.tasks"),
    1,
  );
  same(
    "gateway actions preserve task note",
    await scalar("select to_jsonb(description) from public.tasks"),
    content.description,
  );
  summary.passed = true;
} catch (error) {
  summary.passed = false;
  summary.failure = error.message;
  process.exitCode = 1;
} finally {
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill("SIGTERM");
    await once(child, "exit");
  }
  summary.gatewayStopped = !child || child.exitCode !== null ||
    child.signalCode !== null;
  if (bridge) {
    bridge.closeAllConnections();
    await new Promise((resolve) => bridge.close(resolve));
  }
  summary.bridgeStopped = !bridge || !bridge.listening;
  if (db) summary.containerRemoved = await db.close();
  if (process.argv[2]) {
    await writeFile(process.argv[2], JSON.stringify(summary, null, 2) + "\n");
  }
  console.log(JSON.stringify(summary));
}

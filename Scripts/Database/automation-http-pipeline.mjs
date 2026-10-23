import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
// Invoked only by the owned local mutation runner before fixture cleanup.
export async function checkHttpPipeline(db, account, uuid) {
  let checks = 0, server, child;
  const same = (a, b, label) => {
    assert.deepEqual(a, b, label);
    checks++;
  };
  const key = uuid(27),
    target = uuid(301),
    generation = uuid(10301),
    request = uuid(10302);
  const secret = "tfk_v1_" + key.replaceAll("-", "") +
    "_AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
  const hash = createHash("sha256").update(secret).digest("hex");
  let rpcCalls = 0;
  try {
    await db.query(
      "insert into taskfold_private.automation_keys(id,user_id,name,token_hash,scopes,ttl_days,expires_at) values($1,$2,'Local HTTP fixture',$3,array['tasks:read','tasks:create','tasks:update','tasks:complete','tasks:delete'],30,clock_timestamp()+interval '1 day')",
      [key, account, hash],
    );
    await db.exec("set role service_role");
    server = createServer(async (req, res) => {
      try {
        assert.equal(req.method, "POST");
        assert.equal(
          req.headers.authorization,
          "Bearer synthetic-loopback-service",
        );
        assert.equal(req.headers.apikey, "synthetic-loopback-service");
        const chunks = [];
        let size = 0;
        for await (const chunk of req) {
          size += chunk.length;
          if (size > 1049000) throw new Error("Fixture RPC body too large");
          chunks.push(chunk);
        }
        const text = Buffer.concat(chunks).toString("utf8");
        assert(!text.includes(secret), "Raw authorization secret reached RPC");
        const body = JSON.parse(text);
        assert.equal(body._key, key);
        assert.equal(body._hash, hash);
        rpcCalls++;
        let query;
        if (req.url === "/rest/v1/rpc/taskfold_automation_read") {
          query =
            "select public.taskfold_automation_read($1,$2,$3,$4::jsonb) value";
        } else if (req.url === "/rest/v1/rpc/taskfold_automation_write") {
          query =
            "select public.taskfold_automation_write($1,$2,$3,$4::jsonb) value";
        } else if (
          req.url === "/rest/v1/rpc/taskfold_automation_destinations"
        ) {
          query =
            "select public.taskfold_automation_destinations($1,$2,$3,$4::jsonb) value";
        } else throw new Error("Unexpected service route");
        const result = (await db.query(query, [
          body._key,
          body._hash,
          body._action,
          JSON.stringify(body._body),
        ])).rows[0].value;
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(result));
      } catch (error) {
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            code: error.code ?? "XX000",
            message: "PRIVATE FIXTURE RPC ERROR",
          }),
        );
      }
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const rpcPort = server.address().port;
    child = spawn("deno", [
      "run",
      "--allow-net=127.0.0.1",
      fileURLToPath(new URL("./automation-http-fixture.ts", import.meta.url)),
      String(rpcPort),
    ], { stdio: ["ignore", "pipe", "pipe"] });
    const port = await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error("Local handler did not start")),
        10000,
      );
      let buffer = "";
      child.once("error", (error) => {
        clearTimeout(timer);
        reject(error);
      });
      child.once("exit", () => {
        clearTimeout(timer);
        reject(new Error("Local handler exited before ready"));
      });
      child.stdout.on("data", (chunk) => {
        buffer += String(chunk);
        for (const line of buffer.split("\n")) {
          try {
            const row = JSON.parse(line);
            if (Number.isInteger(row.ready)) {
              clearTimeout(timer);
              resolve(row.ready);
            }
          } catch {
            // Partial stdout lines are retried when the next chunk arrives.
          }
        }
      });
    });
    const call = async (action, body, write = false) => {
      const reply = await fetch(
        "http://127.0.0.1:" + port + (write ? "/write" : "/"),
        {
          method: "POST",
          headers: {
            Authorization: "Bearer " + secret,
            "X-Taskfold-Automation": "1",
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ action, body }),
          signal: AbortSignal.timeout(15000),
        },
      );
      const text = await reply.text();
      assert(
        !text.includes("PRIVATE FIXTURE"),
        "Private service failure escaped",
      );
      return {
        status: reply.status,
        value: JSON.parse(text),
        cache: reply.headers.get("Cache-Control"),
      };
    };
    const destinations = await call("projects", {});
    same(destinations.status, 200);
    same(destinations.value.inbox, {
      name: "Inbox",
      project_id: null,
      section_id: null,
    });
    same(
      destinations.value.projects.every((p) =>
        typeof p.name === "string" && typeof p.accepts_tasks === "boolean"
      ),
      true,
    );
    const destination = destinations.value.projects[0].id;
    const sections = await call("sections", { project_id: destination });
    same(sections.status, 200);
    same(sections.value.project_id, destination);
    same(Array.isArray(sections.value.sections), true);
    same((await call("sections", { project_id: uuid(99999) })).status, 404);
    const reminderFixture = JSON.parse(
      await readFile(
        new URL(
          "../../TaskfoldTests/Fixtures/automation-reminder-validation.json",
          import.meta.url,
        ),
        "utf8",
      ),
    );
    const schedules = ["calendar-sensitive", "interval-normal", "holiday-move"]
      .map((name, i) => ({
        ...reminderFixture.cases.find((r) => r.name === name).spec,
        id: uuid(21000 + i),
      }));
    const portable = await call("create", {
      id: uuid(451),
      task_generation: uuid(20451),
      request_id: uuid(20452),
      time_zone: "UTC",
      fields: {
        title: "HTTP portable reminder proof",
        reminder_specs: schedules,
      },
    }, true);
    same(portable.status, 200);
    const portableRead = await call("get", { id: uuid(451) });
    same(portableRead.status, 200);
    same(portableRead.value.task.reminder_specs, schedules);
    const edited = structuredClone(schedules);
    edited[1].interval_schedule.every_minutes = 30;
    const portableEdit = await call("update", {
      id: uuid(451),
      task_generation: uuid(20451),
      request_id: uuid(20453),
      time_zone: "UTC",
      base: portableRead.value.task,
      fields: { reminder_specs: edited },
    }, true);
    same(portableEdit.status, 200);
    same(
      (await call("get", { id: uuid(451) })).value.task.reminder_specs,
      edited,
    );
    const invalid = structuredClone(edited);
    invalid[1].interval_schedule.every_minutes = 4;
    same(
      (await call("create", {
        id: uuid(452),
        task_generation: uuid(20452),
        request_id: uuid(20454),
        time_zone: "UTC",
        fields: { title: "Invalid HTTP reminder", reminder_specs: invalid },
      }, true)).status,
      400,
    );
    const create = {
      id: target,
      request_id: request,
      task_generation: generation,
      time_zone: "UTC",
      fields: { title: "Local HTTP pipeline proof" },
    };
    const made = await call("create", create, true);
    same(made.status, 200);
    same(made.value.receipt.task_id, target);
    same(made.cache, "no-store");
    const replay = await call("create", create, true);
    same(replay.value.replayed, true);
    same(replay.value.receipt, made.value.receipt);
    let read = await call("get", { id: target });
    same(read.status, 200);
    same(read.value.task.user_id, account);
    same(read.value.task.revision.length, 64);
    const update = await call("update", {
      id: target,
      request_id: uuid(10303),
      task_generation: generation,
      time_zone: "UTC",
      base: read.value.task,
      fields: { title: "Edited over real loopback HTTP" },
    }, true);
    same(update.status, 200);
    read = await call("get", { id: target });
    same(read.value.task.title, "Edited over real loopback HTTP");
    const completed = await call("complete", {
      id: target,
      request_id: uuid(10304),
      task_generation: generation,
      time_zone: "UTC",
      base: read.value.task,
    }, true);
    same(completed.status, 200);
    read = await call("get", { id: target });
    same(read.value.task.completed, true);
    same(
      (await call("reopen", {
        id: target,
        request_id: uuid(10305),
        task_generation: generation,
        time_zone: "UTC",
        base: read.value.task,
      }, true)).status,
      200,
    );
    read = await call("get", { id: target });
    same(read.value.task.completed, false);
    const removed = await call("delete", {
      id: target,
      request_id: uuid(10306),
      task_generation: generation,
      time_zone: "UTC",
      revision: read.value.task.revision,
      descendants: [],
    }, true);
    same(removed.status, 200);
    same(removed.value.receipt.deleted, true);
    same((await call("get", { id: target })).status, 404);
    same(rpcCalls, 19);
    return checks;
  } finally {
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      let timer;
      await Promise.race([
        once(child, "exit"),
        new Promise((resolve) => {
          timer = setTimeout(resolve, 3000);
        }),
      ]);
      clearTimeout(timer);
      if (child.exitCode === null) child.kill("SIGKILL");
    }
    if (server) {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
    }
    await db.exec("reset role");
  }
}

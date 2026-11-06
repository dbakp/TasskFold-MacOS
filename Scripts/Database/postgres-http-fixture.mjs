// Actual production handler -> owned loopback RPC adapter -> real PostgreSQL.
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { literal as lit } from "./postgres-fixture.mjs";
export async function createPostgresHttpFixture(pg, key, app) {
  let child;
  const calls = { admission: 0, resource: 0, errors: [] };
  const routes = {
    "/rest/v1/rpc/taskfold_automation_admit": ["taskfold_automation_admit", [
      "_route",
      "_ip_hash",
      "_credential_hash",
    ]],
    "/rest/v1/rpc/taskfold_automation_read": ["taskfold_automation_read", [
      "_key",
      "_hash",
      "_action",
      "_body",
    ]],
    "/rest/v1/rpc/taskfold_automation_write": ["taskfold_automation_write", [
      "_key",
      "_hash",
      "_action",
      "_body",
    ]],
    "/rest/v1/rpc/taskfold_automation_destinations": [
      "taskfold_automation_destinations",
      ["_key", "_hash", "_action", "_body"],
    ],
  };
  const server = createServer(async (req, res) => {
    try {
      if (
        req.method !== "POST" ||
        req.headers.authorization !== "Bearer synthetic-loopback-service" ||
        req.headers.apikey !== "synthetic-loopback-service"
      ) throw new Error();
      const route = routes[req.url];
      if (!route) throw new Error();
      let bytes = 0;
      const chunks = [];
      for await (const chunk of req) {
        bytes += chunk.length;
        if (bytes > 1049000) throw new Error();
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      if (
        Object.keys(input).sort().join(",") !== [...route[1]].sort().join(",")
      ) throw new Error();
      const args = route[1].map((name) =>
        name === "_body"
          ? lit(JSON.stringify(input[name])) + "::jsonb"
          : lit(input[name])
      );
      if (route[0] === "taskfold_automation_admit") calls.admission++;
      else calls.resource++;
      const answer = await pg.value(`public.${route[0]}(${args.join(",")})`, {
        app,
      });
      if (answer.code) calls.errors.push(answer.code);
      res.writeHead(answer.code ? 400 : 200, {
        "Content-Type": "application/json",
      });
      res.end(
        JSON.stringify(
          answer.code
            ? { code: answer.code, message: "PRIVATE FIXTURE FAILURE" }
            : answer.value,
        ),
      );
    } catch {
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end('{"code":"XX000","message":"PRIVATE FIXTURE ADAPTER"}');
    }
  });
  async function close() {
    if (child && child.exitCode === null) {
      child.kill("SIGTERM");
      let timer;
      await Promise.race([
        once(child, "exit"),
        new Promise((r) => {
          timer = setTimeout(r, 3000);
        }),
      ]);
      clearTimeout(timer);
      if (child.exitCode === null) child.kill("SIGKILL");
    }
    server.closeAllConnections();
    await new Promise((r) => server.close(r));
  }
  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    child = spawn("deno", [
      "run",
      "--allow-net=127.0.0.1",
      fileURLToPath(new URL("./automation-http-fixture.ts", import.meta.url)),
      String(server.address().port),
    ], { stdio: ["ignore", "pipe", "pipe"] });
    const port = await new Promise((resolve, reject) => {
      let buffer = "";
      const timer = setTimeout(
        () => reject(new Error("Owned HTTP handler did not start")),
        10000,
      );
      child.once("error", reject);
      child.once("exit", () => {
        clearTimeout(timer);
        reject(new Error("Owned handler exited"));
      });
      child.stdout.on("data", (part) => {
        buffer += part;
        for (const line of buffer.split("\n")) {
          try {
            const row = JSON.parse(line);
            if (Number.isInteger(row.ready)) {
              clearTimeout(timer);
              resolve(row.ready);
            }
          } catch { /* Wait for a complete ready message. */ }
        }
      });
    });
    const call = async (action, body, write = true) => {
      const response = await fetch(
        "http://127.0.0.1:" + port + (write ? "/write" : "/"),
        {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(15000),
          headers: {
            Authorization: "Bearer " + key.secret,
            "X-Taskfold-Automation": "1",
            "Content-Type": "application/json",
            "X-Forwarded-For": "192.0.2.10",
            "CF-Connecting-IP": "192.0.2.10",
          },
          body: JSON.stringify({ action, body }),
        },
      );
      const text = await response.text();
      if (text.includes("PRIVATE FIXTURE")) {
        throw new Error("Private RPC error escaped");
      }
      return {
        status: response.status,
        body: JSON.parse(text),
        retryAfter: response.headers.get("Retry-After"),
        expose: response.headers.get("Access-Control-Expose-Headers"),
        cache: response.headers.get("Cache-Control"),
      };
    };
    return { call, close, calls };
  } catch (error) {
    await close();
    throw error;
  }
}

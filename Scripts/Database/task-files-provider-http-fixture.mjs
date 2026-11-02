import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { literal as lit } from "./postgres-fixture.mjs";
export async function createTaskFileProviderHttp(pg, storage, users) {
  const faults = {
    loseUpload: false,
    failFinalize: false,
    loseFinalize: false,
    loseDelete: false,
  };
  const counts = {
    uploads: 0,
    downloads: 0,
    deletes: 0,
    rpc: 0,
    auth: 0,
    providerErrors: [],
  };
  let child;
  const tokens = Object.fromEntries(
    Object.entries(users).map((
      [name, u],
    ) => [
      name,
      storage.token({
        role: "authenticated",
        sub: u.id,
        session_id: u.session,
      }),
    ]),
  );
  const server = createServer(async (req, res) => {
    try {
      if (req.headers.apikey !== storage.service) throw Error("service key");
      if (req.url === "/auth/v1/user") {
        counts.auth++;
        const entry = Object.entries(tokens).find(([, token]) =>
          req.headers.authorization === "Bearer " + token
        );
        res.writeHead(entry ? 200 : 401, {
          "Content-Type": "application/json",
        });
        res.end(
          JSON.stringify(
            entry ? { id: users[entry[0]].id } : { error: "invalid" },
          ),
        );
        return;
      }
      if (req.headers.authorization !== "Bearer " + storage.service) {
        throw Error("service authorization");
      }
      const chunks = [];
      let length = 0;
      for await (const c of req) {
        length += c.length;
        if (length > 5242880 + 1000) throw Error("bounded body");
        chunks.push(c);
      }
      const bytes = Buffer.concat(chunks);
      if (req.url.startsWith("/storage/v1/object/")) {
        if (req.method === "POST") counts.uploads++;
        else if (req.method === "GET") counts.downloads++;
        else if (req.method === "DELETE") counts.deletes++;
        else throw Error("storage method");
        const response = await storage.request(
          req.url.slice("/storage/v1".length),
          {
            method: req.method,
            headers: {
              "Content-Type": req.headers["content-type"] ??
                "application/octet-stream",
              "x-upsert": req.headers["x-upsert"] ?? "false",
            },
            ...(bytes.length ? { body: bytes } : {}),
          },
        );
        const result = Buffer.from(await response.arrayBuffer());
        if (!response.ok) {
          counts.providerErrors.push({
            method: req.method,
            status: response.status,
            body: result.toString("utf8").slice(0, 500),
          });
        }
        const lose = req.method === "POST" && faults.loseUpload ||
          req.method === "DELETE" && faults.loseDelete;
        if (lose && response.ok) {
          if (req.method === "POST") faults.loseUpload = false;
          else faults.loseDelete = false;
          res.writeHead(503, { "Content-Type": "application/json" });
          res.end('{"error":"synthetic lost acknowledgement"}');
          return;
        }
        res.writeHead(response.status, {
          "Content-Type": response.headers.get("content-type") ??
            "application/octet-stream",
        });
        res.end(result);
        return;
      }
      const body = JSON.parse(bytes.toString("utf8"));
      let expression;
      if (req.url === "/rest/v1/rpc/taskfold_task_file_command") {
        assertKeys(body, ["_action", "_actor", "_session", "_body"]);
        if (body._action === "finalize" && faults.failFinalize) {
          faults.failFinalize = false;
          res.writeHead(503);
          res.end("{}");
          return;
        }
        expression = `public.taskfold_task_file_command(${lit(body._action)},${
          lit(body._actor)
        },${lit(body._session)},${lit(JSON.stringify(body._body))}::jsonb)`;
      } else if (req.url === "/rest/v1/rpc/taskfold_task_file_maintenance") {
        assertKeys(body, ["_action", "_body"]);
        expression = `public.taskfold_task_file_maintenance(${
          lit(body._action)
        },${lit(JSON.stringify(body._body))}::jsonb)`;
      } else throw Error("unknown adapter path");
      counts.rpc++;
      const answer = await pg.value(expression);
      if (body._action === "finalize" && faults.loseFinalize && !answer.code) {
        faults.loseFinalize = false;
        res.writeHead(503);
        res.end("{}");
        return;
      }
      res.writeHead(answer.code ? 400 : 200, {
        "Content-Type": "application/json",
      });
      res.end(
        JSON.stringify(answer.code ? { code: answer.code } : answer.value),
      );
    } catch {
      res.writeHead(503, { "Content-Type": "application/json" });
      res.end('{"error":"owned fixture failure"}');
    }
  });
  function assertKeys(value, keys) {
    if (Object.keys(value).sort().join(",") !== keys.sort().join(",")) {
      throw Error("adapter contract");
    }
  }
  async function close() {
    if (child && child.exitCode === null && child.signalCode === null) {
      child.kill("SIGTERM");
      let timer;
      await Promise.race([
        once(child, "exit"),
        new Promise((r) => {
          timer = setTimeout(r, 3000);
        }),
      ]);
      clearTimeout(timer);
      if (child.exitCode === null && child.signalCode === null) {
        child.kill("SIGKILL");
      }
    }
    server.closeAllConnections();
    if (server.listening) await new Promise((r) => server.close(r));
    return true;
  }
  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    child = spawn("deno", [
      "run",
      "--allow-net=127.0.0.1",
      fileURLToPath(new URL("./task-files-provider-http.ts", import.meta.url)),
    ], { stdio: ["pipe", "pipe", "pipe"] });
    let diagnostics = "";
    child.stderr.on("data", (c) => {
      diagnostics = (diagnostics + c).slice(-3000);
    });
    child.stdin.end(
      JSON.stringify({ port: server.address().port, service: storage.service }),
    );
    const port = await new Promise((resolve, reject) => {
      let data = "";
      const timer = setTimeout(
        () => reject(Error("Owned file handler did not start")),
        10000,
      );
      child.once("error", reject);
      child.once("exit", () => {
        clearTimeout(timer);
        reject(Error("Owned file handler exited: " + diagnostics));
      });
      child.stdout.on("data", (c) => {
        data += c;
        for (const line of data.split("\n")) {
          try {
            const v = JSON.parse(line);
            if (Number.isInteger(v.ready)) {
              clearTimeout(timer);
              resolve(v.ready);
            }
          } catch { /* Wait for a complete ready message. */ }
        }
      });
    });
    const call = async (action, body, who = "owner") => {
      const maintenance = action === "maintenance";
      const response = await fetch(
        "http://127.0.0.1:" + port +
          (maintenance ? "/maintenance" : "/?action=" + action),
        {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.timeout(60000),
          headers: {
            "Content-Type": "application/json",
            Authorization: "Bearer " + tokens[who],
            ...(maintenance
              ? {
                "X-Taskfold-File-Maintenance": "synthetic-maintenance-".repeat(
                  3,
                ),
              }
              : {}),
          },
          body: JSON.stringify(body),
        },
      );
      const bytes = Buffer.from(await response.arrayBuffer());
      return {
        status: response.status,
        headers: response.headers,
        bytes,
        json: () => JSON.parse(bytes.toString("utf8")),
      };
    };
    return { call, faults, counts, tokens, close };
  } catch (error) {
    await close();
    throw error;
  }
}

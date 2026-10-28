// Production HTTP handler + real PostgreSQL; controlled synthetic Auth and byte Storage adapter.
// This does not claim acceptance by a real Supabase Auth/Storage deployment.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { literal as lit } from "./postgres-fixture.mjs";
export async function createAudioHttpFixture(pg, actor, session) {
  let child;
  const token = "test." +
    Buffer.from(JSON.stringify({ sub: actor, session_id: session })).toString(
      "base64url",
    ) + ".synthetic";
  const state = {
    objects: new Map(),
    uploads: 0,
    authReads: 0,
    lostAck: false,
    noWrite: false,
    corrupt: false,
    afterGet: null,
    errors: [],
  };
  const server = createServer(async (req, res) => {
    const json = (x, status = 200) => {
      res.writeHead(status, { "Content-Type": "application/json" });
      res.end(JSON.stringify(x));
    };
    try {
      assert.equal(req.headers.apikey, "synthetic-loopback-service");
      if (req.url === "/auth/v1/user") {
        state.authReads++;
        assert.equal(req.headers.authorization, "Bearer " + token);
        return json({ id: actor });
      }
      assert.equal(
        req.headers.authorization,
        "Bearer synthetic-loopback-service",
      );
      const chunks = [];
      let length = 0;
      for await (const c of req) {
        length += c.length;
        if (length > 8000000) throw Error("Oversized fixture request");
        chunks.push(c);
      }
      const bytes = Buffer.concat(chunks);
      if (req.url.startsWith("/rest/v1/rpc/")) {
        assert.equal(req.method, "POST");
        const b = JSON.parse(bytes.toString());
        if (!req.url.endsWith("/taskfold_audio_comment_maintenance")) {
          assert.equal(b._actor, actor);
          assert.equal(b._session, session);
        }
        let expression;
        if (req.url.endsWith("/taskfold_audio_comment_maintenance")) {
          expression = `public.taskfold_audio_comment_maintenance(${
            lit(b._action)
          },${lit(JSON.stringify(b._body))}::jsonb)`;
        } else if (req.url.endsWith("/taskfold_audio_comment_admit")) {
          expression = `public.taskfold_audio_comment_admit(${lit(b._actor)},${
            lit(b._session)
          },${lit(b._action)})`;
        } else if (req.url.endsWith("/taskfold_audio_comment_command")) {
          expression = `public.taskfold_audio_comment_command(${
            lit(b._action)
          },${lit(b._actor)},${lit(b._session)},${
            lit(JSON.stringify(b._body))
          }::jsonb)`;
        } else throw Error("Unknown RPC");
        const r = await pg.value(expression);
        if (r.code) {
          state.errors.push(r.code);
          return json({ private: "fixture SQL" }, 400);
        }
        return json(r.value);
      }
      if (
        req.method === "DELETE" &&
        req.url === "/storage/v1/object/taskfold-audio-v1"
      ) {
        const { prefixes } = JSON.parse(bytes.toString());
        assert.equal(prefixes.length, 1);
        const name = prefixes[0];
        if (state.deleteFails) return json({ code: "storage_failed" }, 500);
        if (!state.deleteNoEffect) {
          state.objects.delete(name);
          await pg.raw(
            `delete from storage.objects where bucket_id='taskfold-audio-v1' and name=${
              lit(name)
            }`,
          );
        }
        return json([]);
      }
      const prefix = "/storage/v1/object/taskfold-audio-v1/";
      assert(req.url.startsWith(prefix));
      const name = req.url.slice(prefix.length);
      if (req.method === "POST") {
        assert.equal(req.headers["x-upsert"], "false");
        assert.equal(req.headers["content-type"], "audio/mp4");
        state.uploads++;
        if (state.objects.has(name)) {
          return json({ code: "ResourceAlreadyExists" }, 409);
        }
        if (!state.noWrite) {
          const stored = state.corrupt ? Buffer.from([1, 2, 3]) : bytes;
          state.objects.set(name, stored);
          await pg.raw(
            `insert into storage.objects(id,bucket_id,name,metadata) values(${
              lit(randomUUID())
            },'taskfold-audio-v1',${lit(name)},${
              lit(
                JSON.stringify({ size: stored.length, mimetype: "audio/mp4" }),
              )
            }::jsonb)`,
          );
        }
        if (state.lostAck) {
          req.socket.destroy();
          return;
        }
        return json({ Key: name }, 201);
      }
      assert.equal(req.method, "GET");
      const stored = state.objects.get(name);
      if (!stored) return json({ code: "NoSuchKey" }, 404);
      if (state.afterGet) await state.afterGet();
      res.writeHead(200, { "Content-Type": "audio/mp4" });
      res.end(stored);
    } catch (error) {
      state.errors.push(String(error));
      if (!res.headersSent) json({ private: "fixture adapter" }, 503);
      else res.destroy();
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
      fileURLToPath(
        new URL("./audio-comments-http-fixture.ts", import.meta.url),
      ),
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
    const call = async (action, body) =>
      fetch("http://127.0.0.1:" + port + "/?action=" + action, {
        method: "POST",
        headers: {
          Authorization: "Bearer " + token,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(15000),
      });
    const maintain = (proof = null) =>
      fetch("http://127.0.0.1:" + port + "/maintenance", {
        method: "POST",
        headers: proof ? { "X-Taskfold-Audio-Schedule": proof } : {
          "X-Taskfold-Audio-Maintenance": "b".repeat(64),
        },
        signal: AbortSignal.timeout(25000),
      });
    return {
      call,
      close,
      state,
      maintain,
      nativeEndpoint: "http://127.0.0.1:" + port,
      nativeToken: token,
    };
  } catch (error) {
    await close();
    throw error;
  }
}

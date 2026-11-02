// Actual local production audio handler, PostgreSQL/RLS and pinned Storage API.
// Native HTTPS/Auth/PostgREST routing is synthetic and limited to owned fixtures.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { createHash } from "node:crypto";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import { taskFileWorkspaceAdapter } from "./task-file-workspace-fixture.mjs";
export async function createAudioTeamNativeHttp(pg, storage, user) {
  const audio = await createAudioHttpFixture(pg, user.id, user.session, {
    storage,
  });
  const workspace = taskFileWorkspaceAdapter(pg, { actor: user }, {
    actor: audio.nativeToken,
  });
  const faults = { losePublicationReply: true };
  const requests = [];
  const server = createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, "Bearer " + audio.nativeToken);
      assert.equal(req.headers.apikey, "synthetic-public");
      const url = new URL(req.url, "http://127.0.0.1");
      if (url.pathname !== "/functions/v1/audio-comments") {
        assert(
          url.pathname.startsWith("/rest/v1/") ||
            url.pathname === "/auth/v1/user",
        );
        req.url = "/native" + req.url;
        return await workspace.reply(req, res);
      }
      assert.equal(req.method, "POST");
      assert.equal([...url.searchParams].length, 1);
      const action = url.searchParams.get("action");
      assert(
        ["publish", "resolve", "list", "page", "download", "remove"].includes(
          action,
        ),
      );
      const chunks = [];
      let count = 0;
      for await (const part of req) {
        count += part.length;
        assert(count <= 12000000);
        chunks.push(part);
      }
      const body = Buffer.concat(chunks);
      const response = await fetch(
        audio.nativeEndpoint + "/?action=" + action,
        {
          method: "POST",
          headers: {
            Authorization: "Bearer " + audio.nativeToken,
            "Content-Type": "application/json",
          },
          body,
          signal: AbortSignal.timeout(25000),
          redirect: "error",
        },
      );
      const bytes = Buffer.from(await response.arrayBuffer());
      const lost = action === "publish" && response.ok &&
        faults.losePublicationReply;
      if (lost) faults.losePublicationReply = false;
      requests.push({
        action,
        bodySHA256: createHash("sha256").update(body).digest("hex"),
        responseStatus: response.status,
        deliveredStatus: lost ? 503 : response.status,
        responseBytes: bytes.length,
      });
      const headers = {
        "Content-Type": response.headers.get("content-type") ??
          "application/json",
      };
      for (
        const key of [
          "cache-control",
          "x-content-type-options",
          "x-audio-sha256",
        ]
      ) {
        const value = response.headers.get(key);
        if (value !== null) headers[key] = value;
      }
      res.writeHead(lost ? 503 : response.status, headers);
      res.end(
        lost ? '{"error":"synthetic lost final acknowledgement"}' : bytes,
      );
    } catch (error) {
      requests.push({
        error: String(error).slice(0, 200),
        path: req.url.split("?")[0],
      });
      if (!res.headersSent) {
        res.writeHead(503, { "Content-Type": "application/json" });
        res.end('{"error":"native fixture refused"}');
      } else res.destroy();
    }
  });
  try {
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
  } catch (error) {
    await audio.close();
    throw error;
  }
  return {
    url: "http://127.0.0.1:" + server.address().port,
    token: audio.nativeToken,
    audio,
    workspace,
    faults,
    requests,
    async close() {
      server.closeAllConnections();
      await new Promise((r) => server.close(r));
      await audio.close();
      return true;
    },
  };
}

// Actual local production audio handler, PostgreSQL/RLS and pinned Storage API.
// Native HTTPS/Auth/PostgREST routing is synthetic and limited to owned fixtures.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { once } from "node:events";
import { createHash } from "node:crypto";
import { createAudioHttpFixture } from "./audio-comments-postgres-http-fixture.mjs";
import { literal as lit } from "./postgres-fixture.mjs";
import { taskFileWorkspaceAdapter } from "./task-file-workspace-fixture.mjs";
export async function createAudioTeamNativeHttp(pg, storage, user, options = {}) {
  const audio = await createAudioHttpFixture(pg, user.id, user.session, {
    storage,
  });
  const workspace = taskFileWorkspaceAdapter(pg, { actor: user }, {
    actor: audio.nativeToken,
  });
  assert(Object.keys(options).every((key) => key === "expiredRecovery"));
  const faults = { losePublicationReply: true, expireAfterDeletion: options.expiredRecovery === true, loseOmissionReply: options.expiredRecovery === true };
  const requests = [];
  const server = createServer(async (req, res) => {
    try {
      assert.equal(req.headers.authorization, "Bearer " + audio.nativeToken);
      assert.equal(req.headers.apikey, "synthetic-public");
      const url = new URL(req.url, "http://127.0.0.1");
      if (
        [
          "/rest/v1/rpc/taskfold_team_audio_lifecycle_review",
          "/rest/v1/rpc/taskfold_team_task_lifecycle",
          "/rest/v1/rpc/taskfold_audio_restore_recovery",
        ].includes(url.pathname)
      ) {
        assert.equal(req.method, "POST");
        const chunks = [];
        let size = 0;
        for await (const part of req) {
          size += part.length;
          assert(size <= 129000);
          chunks.push(part);
        }
        const bytes = Buffer.concat(chunks),
          body = JSON.parse(bytes.toString());
        const preview = url.pathname.endsWith("_review");
        assert.deepEqual(
          Object.keys(body).sort(),
          preview ? ["_body"] : ["_action", "_body"],
        );
        const recovery = url.pathname.endsWith("_restore_recovery");
        if (!preview) assert((recovery ? ["inspect", "close"] : ["delete", "restore"]).includes(body._action));
        const expression = preview
          ? `public.taskfold_team_audio_lifecycle_review(${
            lit(JSON.stringify(body._body))
          }::jsonb)`
          : recovery ? `public.taskfold_audio_restore_recovery(${lit(body._action)},${lit(JSON.stringify(body._body))}::jsonb)`
          : `public.taskfold_team_task_lifecycle(${lit(body._action)},${
            lit(JSON.stringify(body._body))
          }::jsonb)`;
        let value;
        try { value = await pg.scalar(
          `begin;set local role authenticated;set local request.jwt.claim.sub=${
            lit(user.id)
          };set local request.jwt.claims=${
            lit(JSON.stringify({ sub: user.id, session_id: user.session }))
          };select ${expression};commit;`,
        ); } catch (error) {
          const statuses = { PT409: 409, PT412: 412, PT503: 503, "42501": 403, "28000": 401, "22023": 400 };
          assert(Object.hasOwn(statuses, error.code), "Expected SQL refusal code, never invented success");
          requests.push({ action: (preview ? "lifecycle_review" : recovery ? "restore_recovery_" + body._action : "task_" + body._action) + "_refused", code: error.code, responseStatus: statuses[error.code], deliveredStatus: statuses[error.code], bodySHA256: createHash("sha256").update(bytes).digest("hex"), requestID: body._body.request_id, ack: body._body.audio_restoration_ack });
          res.writeHead(statuses[error.code], { "Content-Type": "application/json", "Cache-Control": "no-store" });
          res.end(JSON.stringify({ code: error.code, message: "Controlled native SQL refusal" })); return;
        }
        if (!preview && !recovery && body._action === "delete" && faults.expireAfterDeletion) {
          faults.expireAfterDeletion = false;
          const source = lit(body._body.request_id);
          await pg.raw(`update taskfold_private.audio_task_deletions set expires_at=clock_timestamp()-interval '1 second' where request_id=${source};update taskfold_private.audio_comment_publications r set cleanup_after=d.expires_at from taskfold_private.audio_task_deletions d where d.request_id=${source} and r.operation_id=any(d.operations)`);
          const maintenance = await audio.maintain(), result = await maintenance.json();
          assert.equal(maintenance.status, 200); assert.equal(result.purged, 1);
          faults.expiryProof = { actualRetentionExpired: true, actualFencedCleanup: result };
        }
        const lost = !preview && !recovery && body._action === "restore" && body._body.audio_restoration_ack?.policy === "expired_recordings_omitted_v1" && faults.loseOmissionReply;
        if (lost) faults.loseOmissionReply = false;
        requests.push({
          action: preview ? "lifecycle_review" : recovery ? "restore_recovery_" + body._action : "task_" + body._action,
          responseStatus: 200,
          deliveredStatus: lost ? 503 : 200,
          bodySHA256: createHash("sha256").update(bytes).digest("hex"),
          command: body,
          ...(preview ? { recordingCount: value.recording_count } : {
            generation: value.task_generation,
            requestID: value.request_id,
            ack: body._body.audio_restoration_ack,
            ...(recovery ? { state: value.state } : {}),
          }),
        });
        res.writeHead(lost ? 503 : 200, {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
          "X-Content-Type-Options": "nosniff",
        });
        res.end(lost ? '{"error":"synthetic lost restoration acknowledgement"}' : JSON.stringify(value));
        return;
      }
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

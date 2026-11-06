// Owned loopback acceptance only: no hosted credentials or real Auth/Storage.
import { createAudioCommentsHandler } from "../../supabase/functions/audio-comments/handler.ts";
import { createAudioMaintenanceHandler } from "../../supabase/functions/audio-comment-maintenance/handler.ts";
const port = Number(Deno.args[0]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw Error("Owned adapter port required");
}
const audio = createAudioCommentsHandler({
  url: "https://audio-http-fixture.invalid",
  serviceKey: "synthetic-loopback-service",
  enabled: true,
}, {
  send: (request) => {
    const u = new URL(request.url);
    if (
      u.origin !== "https://audio-http-fixture.invalid" ||
      !([
        "/auth/v1/user",
        "/rest/v1/rpc/taskfold_audio_comment_admit",
        "/rest/v1/rpc/taskfold_audio_comment_command",
        "/rest/v1/rpc/taskfold_audio_comment_page",
        "/rest/v1/rpc/taskfold_audio_owner_publication",
      ].includes(u.pathname) ||
        /^\/storage\/v1\/object\/taskfold-audio-v1\/audio-comments\/v1\/[a-f0-9-]+\/[a-f0-9-]+\/[a-f0-9-]+\.m4a$/
          .test(u.pathname))
    ) throw Error("Unknown fixture route");
    return fetch(
      new Request("http://127.0.0.1:" + port + u.pathname, {
        method: request.method,
        headers: request.headers,
        body: request.body,
        signal: request.signal,
        redirect: "error",
      }),
    );
  },
});
const maintenance = createAudioMaintenanceHandler({
  url: "https://audio-http-fixture.invalid",
  serviceKey: "synthetic-loopback-service",
  maintenanceKey: "b".repeat(64),
  schedulerProject: "a".repeat(20),
  enabled: true,
}, {
  send: (request) => {
    const u = new URL(request.url);
    if (
      u.origin !== "https://audio-http-fixture.invalid" ||
      u.pathname !== "/rest/v1/rpc/taskfold_audio_comment_maintenance" &&
        !u.pathname.startsWith("/storage/v1/object/taskfold-audio-v1")
    ) throw Error("Unknown maintenance adapter route");
    return fetch(
      new Request("http://127.0.0.1:" + port + u.pathname, {
        method: request.method,
        headers: request.headers,
        body: request.body,
        signal: request.signal,
        redirect: "error",
      }),
    );
  },
});
Deno.serve(
  {
    hostname: "127.0.0.1",
    port: 0,
    onListen: (a) => console.log(JSON.stringify({ ready: a.port })),
  },
  (r) => new URL(r.url).pathname === "/maintenance" ? maintenance(r) : audio(r),
);

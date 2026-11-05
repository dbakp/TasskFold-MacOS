import { createAudioCommentsHandler } from "../../supabase/functions/audio-comments/handler.ts";
import { createAudioMaintenanceHandler } from "../../supabase/functions/audio-comment-maintenance/handler.ts";
// Real upstream fetch with a task-owned CA; no synthetic Auth, SQL, Storage or TLS bypass.
const url = Deno.env.get("TASKFOLD_AUDIO_LOCAL_URL") ?? "";
if (!/^https:\/\/127\.0\.0\.1:\d+$/.test(url)) throw Error("Owned TLS upstream required");
const cert = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_CERT")!);
const key = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_KEY")!);
const config = { url, serviceKey: Deno.env.get("TASKFOLD_AUDIO_LOCAL_SERVICE") ?? "", enabled: true };
const audio = createAudioCommentsHandler(config);
const maintenance = createAudioMaintenanceHandler({ ...config, maintenanceKey: Deno.env.get("TASKFOLD_AUDIO_LOCAL_MAINTENANCE") ?? "" });
Deno.serve({ hostname: "127.0.0.1", port: 0, cert, key, onListen({ port }) { console.log(JSON.stringify({ ready: port })); } },
  request => new URL(request.url).pathname === "/maintenance" ? maintenance(request) : audio(request));

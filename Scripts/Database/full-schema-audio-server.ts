import { createAudioCommentsHandler } from "../../supabase/functions/audio-comments/handler.ts";
// Real upstream fetch with a task-owned CA; no synthetic Auth, SQL, Storage or TLS bypass.
const url = Deno.env.get("TASKFOLD_AUDIO_LOCAL_URL") ?? "";
if (!/^https:\/\/127\.0\.0\.1:\d+$/.test(url)) throw Error("Owned TLS upstream required");
const cert = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_CERT")!);
const key = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_KEY")!);
Deno.serve({ hostname: "127.0.0.1", port: 0, cert, key, onListen({ port }) { console.log(JSON.stringify({ ready: port })); } },
  createAudioCommentsHandler({ url, serviceKey: Deno.env.get("TASKFOLD_AUDIO_LOCAL_SERVICE") ?? "", enabled: true }));

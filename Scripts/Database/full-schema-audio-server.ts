import { createProjectFilesHandler } from "../../supabase/functions/project-files/handler.ts";
import { createTaskFilesHandler } from "../../supabase/functions/task-files/handler.ts";
import { createAudioCommentsHandler } from "../../supabase/functions/audio-comments/handler.ts";
import { createAudioMaintenanceHandler } from "../../supabase/functions/audio-comment-maintenance/handler.ts";
// Real upstream fetch with a task-owned CA; no synthetic Auth, SQL, Storage or TLS bypass.
const url = Deno.env.get("TASKFOLD_AUDIO_LOCAL_URL") ?? "";
if (!/^https:\/\/127\.0\.0\.1:\d+$/.test(url)) throw Error("Owned TLS upstream required");
const cert = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_CERT")!);
const key = await Deno.readTextFile(Deno.env.get("TASKFOLD_AUDIO_LOCAL_KEY")!);
const config = { url, serviceKey: Deno.env.get("TASKFOLD_AUDIO_LOCAL_SERVICE") ?? "", enabled: true };
const audio = createAudioCommentsHandler(config);
const filesEnabled = Deno.env.get("TASKFOLD_AUDIO_LOCAL_PROJECT_FILES") === "1";
const projectFiles = createProjectFilesHandler(config), taskFiles = createTaskFilesHandler(config);
const maintenance = createAudioMaintenanceHandler({ ...config, maintenanceKey: Deno.env.get("TASKFOLD_AUDIO_LOCAL_MAINTENANCE") ?? "" });
Deno.serve({ hostname: "127.0.0.1", port: 0, cert, key, onListen({ port }) { console.log(JSON.stringify({ ready: port })); } },
  request => {
    const path = new URL(request.url).pathname;
    if (path === "/project-files" || path === "/task-files") {
      if (!filesEnabled) return new Response(null, {status: 404});
      return path === "/project-files" ? projectFiles(request) : taskFiles(request);
    }
    return path === "/maintenance" ? maintenance(request) : audio(request);
  });

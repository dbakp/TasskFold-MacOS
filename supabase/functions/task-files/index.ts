import { createTaskFilesHandler } from "./handler.ts";
// Keep platform JWT verification on. This source is not deployed or enabled.
Deno.serve(createTaskFilesHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_TASK_FILES_ENABLED") === "true",
}));

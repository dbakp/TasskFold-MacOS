import { createProjectFilesHandler } from "./handler.ts";
// Platform JWT verification stays on. No deployment or normal-use enablement.
Deno.serve(createProjectFilesHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_PROJECT_FILE_PREPARATION_ENABLED") === "true",
}));

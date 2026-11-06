import { createTaskFileMaintenanceHandler } from "./handler.ts";
// JWT verification remains on. No schedule, deployment or default enablement.
Deno.serve(createTaskFileMaintenanceHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  maintenanceKey: Deno.env.get("TASKFOLD_TASK_FILE_MAINTENANCE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_TASK_FILE_MAINTENANCE_ENABLED") === "true",
}));

import { createRemovalRepairHandler } from "./handler.ts";
Deno.serve(createRemovalRepairHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  maintenanceKey: Deno.env.get("TASKFOLD_REMOVAL_REPAIR_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_REMOVAL_REPAIR_ENABLED") === "true",
}));

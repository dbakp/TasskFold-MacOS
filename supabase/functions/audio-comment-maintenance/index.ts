import { createAudioMaintenanceHandler } from "./handler.ts";
// Keep platform JWT verification enabled; the scheduler additionally needs this
// dedicated secret. Never expose either service credential to a native client.
Deno.serve(createAudioMaintenanceHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  maintenanceKey: Deno.env.get("TASKFOLD_AUDIO_MAINTENANCE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_AUDIO_MAINTENANCE_ENABLED") === "true",
}));

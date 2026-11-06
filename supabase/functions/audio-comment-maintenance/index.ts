import { createAudioMaintenanceHandler } from "./handler.ts";
// Signed schedules authenticate inside this handler with HMAC plus one-use SQL
// admission. Deploy with --no-verify-jwt only after accepting this complete path;
// the scheduler proof is not a JWT. Never expose service credentials to a client.
Deno.serve(createAudioMaintenanceHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  maintenanceKey: Deno.env.get("TASKFOLD_AUDIO_MAINTENANCE_KEY") ?? "",
  enabled: Deno.env.get("TASKFOLD_AUDIO_MAINTENANCE_ENABLED") === "true",
}));

import { createHandler } from "./handler.ts";
Deno.serve(createHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  cronSecret: Deno.env.get("CRON_SECRET") ?? "",
  appID: Deno.env.get("VITE_ONESIGNAL_APP_ID") ?? "",
  providerKey: Deno.env.get("ONESIGNAL_REST_API_KEY") ?? "",
}));

import { createEmailRoutesHandler } from "./handler.ts";
// Keep platform verify_jwt enabled. Live Auth and SQL session/account guards
// independently authorize management. No inbound email/provider handler here.
Deno.serve(createEmailRoutesHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  forwardedForMode: Deno.env.get("TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE") ??
    "",
  inboundDomain: Deno.env.get("TASKFOLD_EMAIL_INBOUND_DOMAIN") ?? "",
}));

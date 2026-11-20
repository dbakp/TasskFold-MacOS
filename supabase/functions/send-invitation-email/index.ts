import { createHandler } from "./handler.ts";
// Sender and provider key come only from function secrets. There is no
// fallback sender: a missing TASKFOLD_EMAIL_FROM makes the function answer 503.
Deno.serve(createHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  resendKey: Deno.env.get("RESEND_API_KEY") ?? "",
  from: Deno.env.get("TASKFOLD_EMAIL_FROM") ?? "",
}));

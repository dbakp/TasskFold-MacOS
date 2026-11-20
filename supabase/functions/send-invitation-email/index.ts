import { createHandler } from "./handler.ts";
// Sender and Lettermint project token come only from function secrets
// (Lettermint: EU-hosted, Netherlands). There is no
// fallback sender: a missing TASKFOLD_EMAIL_FROM makes the function answer 503.
Deno.serve(createHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  lettermintToken: Deno.env.get("LETTERMINT_API_TOKEN") ?? "",
  from: Deno.env.get("TASKFOLD_EMAIL_FROM") ?? "",
}));

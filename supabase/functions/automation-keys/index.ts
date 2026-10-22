import { createHandler } from "./handler.ts";
// Keep gateway JWT verification enabled. The handler also verifies the live
// subject, and SQL verifies the session/account before any management command.
Deno.serve(
  createHandler({
    url: Deno.env.get("SUPABASE_URL") ?? "",
    serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  }),
);

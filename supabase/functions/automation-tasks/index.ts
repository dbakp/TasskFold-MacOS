import { createHandler } from "./handler.ts";
// Custom task keys are not native Auth JWTs. This candidate requires
// verify_jwt:false at deployment; SQL validates the exact key hash, account,
// expiry, scopes and quotas in the same transaction as authorized reads and writes.
// It is intentionally undeployed until the complete task-operation feature,
// native management/review and real HTTP acceptance are ready.
Deno.serve(createHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  forwardedForMode: Deno.env.get("TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE") ??
    "",
}));

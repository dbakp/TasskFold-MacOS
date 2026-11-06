import { webhookMasterCatalog } from "./master-config.ts";
import { createWebhookHandler } from "./handler.ts";
// Inactive until subscriptions, event outbox, native management and hosted
// acceptance can be enabled together. Missing master configuration still leaves
// authenticated list/revoke/discard available; creating/verifying fails closed.
const masterKeys = webhookMasterCatalog(
  Deno.env.get("TASKFOLD_WEBHOOK_MASTER_KEYS") ?? "{}",
);
Deno.serve(createWebhookHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  forwardedForMode: Deno.env.get("TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE") ??
    "",
  currentMasterVersion:
    Deno.env.get("TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION") ?? "",
  masterKeys,
}));

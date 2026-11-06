import { createWebhookWorker } from "../automation-webhooks/worker.ts";
import { webhookMasterCatalog } from "../automation-webhooks/master-config.ts";
// Candidate only. A scheduler is not installed here. Enable only after hosted
// and native acceptance; its random worker credential never belongs in an app.
Deno.serve(createWebhookWorker({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  workerToken: Deno.env.get("TASKFOLD_WEBHOOK_WORKER_TOKEN") ?? "",
  enabled: Deno.env.get("TASKFOLD_WEBHOOK_DISPATCH_ENABLED") === "1",
  masterKeys: webhookMasterCatalog(
    Deno.env.get("TASKFOLD_WEBHOOK_MASTER_KEYS") ?? "{}",
  ),
}));

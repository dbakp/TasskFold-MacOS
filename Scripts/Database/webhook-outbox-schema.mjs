import { readFile } from "node:fs/promises";
import { loadAutomationPostgresSchema } from "./automation-postgres-schema.mjs";
export async function loadWebhookOutboxSchema(execute) {
  await loadAutomationPostgresSchema(execute);
  for (
    const file of [
      "20261023050732_webhook_subscriptions.sql",
      "20261023054251_webhook_outbox.sql",
    ]
  ) {
    await execute(
      await readFile(
        new URL("../../supabase/migrations/" + file, import.meta.url),
        "utf8",
      ),
    );
  }
}

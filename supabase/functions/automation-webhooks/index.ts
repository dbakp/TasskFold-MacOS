import { createWebhookHandler } from "./handler.ts";
// Inactive until subscriptions, event outbox, native management and hosted
// acceptance can be enabled together. Missing master configuration still leaves
// authenticated list/revoke/discard available; creating/verifying fails closed.
const masterKeys: Record<string, Uint8Array> = {};
try {
  const values = JSON.parse(
    Deno.env.get("TASKFOLD_WEBHOOK_MASTER_KEYS") ?? "{}",
  );
  if (
    !values || typeof values !== "object" || Array.isArray(values) ||
    Object.keys(values).length > 3
  ) throw Error("Invalid master catalog");
  for (const [version, value] of Object.entries(values)) {
    if (
      !/^[a-z0-9-]{1,32}$/.test(version) || typeof value !== "string" ||
      !/^[a-f0-9]{64}$/.test(value)
    ) throw Error("Invalid master version");
    masterKeys[version] = Uint8Array.from(
      value.match(/../g) as string[],
      (byte) => parseInt(byte, 16),
    );
  }
} catch {
  for (const key of Object.keys(masterKeys)) delete masterKeys[key];
}
Deno.serve(createWebhookHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  forwardedForMode: Deno.env.get("TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE") ??
    "",
  currentMasterVersion:
    Deno.env.get("TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION") ?? "",
  masterKeys,
}));

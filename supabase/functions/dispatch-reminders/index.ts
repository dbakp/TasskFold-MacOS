import { createAPNsProvider, parseKeys, type Provider } from "./apns.ts";
import { createHandler } from "./handler.ts";
// Native delivery has its own secret and switch. Installing this function cannot arm the
// existing web cron. No APNs key, token, task title, payload or response is logged.
let provider: Provider = {
  ready: () => Promise.reject(new Error("configuration")),
  send: () => Promise.reject(new Error("configuration")),
};
try {
  const keys = parseKeys(Deno.env.get("TASKFOLD_APNS_KEYS") ?? "");
  const pools = new Map(
    keys.map((
      key,
    ) => [
      key.bundle + "/" + key.environment,
      Deno.createHttpClient({ http1: false, http2: true }),
    ]),
  );
  provider = createAPNsProvider(keys, {
    send: (request) => {
      const environment =
        new URL(request.url).hostname === "api.sandbox.push.apple.com"
          ? "development"
          : "production";
      const client = pools.get(
        request.headers.get("apns-topic") + "/" + environment,
      );
      if (!client) throw new Error("configuration");
      return fetch(request, { client });
    },
  });
} catch {
  /* Unsupported HTTP/2 runtime or absent credentials fails closed before claiming. */
}
Deno.serve(createHandler({
  url: Deno.env.get("SUPABASE_URL") ?? "",
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  cronSecret: Deno.env.get("TASKFOLD_REMINDER_CRON_SECRET") ?? "",
  enabled: Deno.env.get("TASKFOLD_APNS_DELIVERY_ENABLED") === "true",
}, provider));

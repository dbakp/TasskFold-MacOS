// Local synthetic integration adapter only. Production handler still requires
// HTTPS; redirect only its known test origin to the owned loopback SQL bridge.
import { createEmailRoutesHandler } from "../../supabase/functions/email-routes/handler.ts";
const bridge = new URL(Deno.args[0]);
if (bridge.hostname !== "127.0.0.1" || bridge.protocol !== "http:") {
  throw Error("Fixture only");
}
const handler = createEmailRoutesHandler({
  url: "https://email-fixture.invalid",
  serviceKey: "synthetic-service-only",
  inboundDomain: "mail.example.invalid",
  forwardedForMode: "supabase-cloudflare-v1",
}, {
  send: (request) => {
    const url = new URL(request.url);
    if (url.origin !== "https://email-fixture.invalid") {
      throw Error("Unexpected upstream");
    }
    return fetch(new Request(bridge.origin + url.pathname, request));
  },
});
Deno.serve({
  hostname: "127.0.0.1",
  port: 0,
  onListen: ({ port }) => console.log(JSON.stringify({ port })),
}, handler);

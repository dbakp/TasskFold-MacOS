// Temporary acceptance-branch entry only; never deploy on main. No database,
// Auth users, task content or real recipient. The caller must hold this branch's
// private acceptance token; the receiver authenticates only fixed synthetic messages.
import { lookup } from "node:dns/promises";
import { connectWebhookSocket } from "../../supabase/functions/automation-webhooks/socket.ts";
import {
  createWebhookTransport,
  webhookHeaders,
} from "../../supabase/functions/automation-webhooks/transport.ts";
import {
  openWebhookSecret,
  sealWebhookSecret,
} from "../../supabase/functions/automation-webhooks/secret.ts";

const secret = new Uint8Array(32).fill(23);
const subscription = "f091cafe-0000-4000-8000-000000000001";
const body = '{"version":1,"fixture":"Taskfold synthetic webhook acceptance"}';
async function syntheticBody(request: Request) {
  const reader = request.body?.getReader();
  if (!reader) return false;
  const signal = AbortSignal.timeout(2000);
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  let received = "", length = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (signal.aborted) return false;
      if (chunk.done) break;
      length += chunk.value.length;
      if (length > body.length) {
        abort();
        return false;
      }
      received += new TextDecoder("utf-8", { fatal: true }).decode(chunk.value);
    }
    return received === body;
  } catch {
    return false;
  } finally {
    signal.removeEventListener("abort", abort);
    reader.releaseLock();
  }
}
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
export function createProbe(
  origin: string,
  acceptanceToken: string,
  ownedProject: string,
) {
  if (
    ownedProject === "zqxflydiyfjeedqvyova" ||
    origin !== `https://${ownedProject}.supabase.co` ||
    !/^[a-f0-9]{64}$/.test(acceptanceToken)
  ) {
    throw Error("Disposable acceptance branch required");
  }
  const diagnostics: Record<string, string> = {};
  const classify = (error: unknown) => {
    // This probe sends only the fixed fixture above, with no credentials in its
    // URL or headers. Never add this diagnostic logging to production delivery.
    console.error(
      "Taskfold synthetic transport: " +
        (error instanceof Error
          ? error.message.slice(0, 300)
          : "Unknown failure"),
    );
    const code = error && typeof error === "object" && "code" in error
      ? String(error.code)
      : "";
    return /^[A-Z_]{3,64}$/.test(code) ? code : error instanceof Error &&
        /not implemented|not supported/i.test(error.message)
      ? "UNSUPPORTED"
      : "UNCLASSIFIED";
  };
  const send = createWebhookTransport({
    resolve: async (hostname) => {
      try {
        const result = await lookup(hostname, { all: true, verbatim: true });
        diagnostics.dns = "RESOLVED";
        return result;
      } catch (error) {
        diagnostics.dns = classify(error);
        throw error;
      }
    },
    connect: async (address, port, hostname, signal) => {
      try {
        return await connectWebhookSocket(address, port, hostname, signal);
      } catch (error) {
        diagnostics.socket = classify(error);
        throw error;
      }
    },
  });
  return async (request: Request) => {
    if (request.method !== "POST") return json({ error: "POST required" }, 405);
    const route = new URL(request.url).pathname.split("/").at(-1)!;
    if (
      ["delivery", "challenge", "redirect", "gone", "retry", "oversize"]
        .includes(route)
    ) {
      const event = request.headers.get("X-Taskfold-Event-Id") ?? "";
      const timestamp = Number(request.headers.get("X-Taskfold-Timestamp"));
      if (
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
          event,
        ) ||
        !Number.isSafeInteger(timestamp) ||
        Math.abs(Date.now() / 1000 - timestamp) > 60 ||
        request.headers.get("Content-Length") !== String(body.length)
      ) return json({ error: "Synthetic signature required" }, 401);
      if (!await syntheticBody(request)) {
        return json({ error: "Synthetic body required" }, 401);
      }
      const expected = await webhookHeaders({
        subscription,
        event,
        timestamp,
        body,
        secret,
      });
      if (
        request.headers.get("X-Taskfold-Webhook-Id") !== subscription ||
        request.headers.get("X-Taskfold-Signature") !==
          expected["X-Taskfold-Signature"]
      ) return json({ error: "Synthetic signature required" }, 401);
      if (route === "redirect") {
        return new Response(null, {
          status: 302,
          headers: { Location: "https://127.0.0.1/private" },
        });
      }
      if (route === "gone") return json({ fixture: true }, 410);
      if (route === "retry") {
        return new Response(null, {
          status: 429,
          headers: { "Retry-After": "120" },
        });
      }
      if (route === "oversize") return new Response("x".repeat(8193));
      return json({ verified: true, event });
    }
    if (
      route !== "webhook-transport-probe" ||
      request.headers.get("X-Taskfold-Acceptance") !== acceptanceToken
    ) return json({ error: "Unavailable" }, 401);
    const checks: Record<string, boolean> = {};
    const outcomes: Record<string, unknown> = {};
    const master = new Uint8Array(32).fill(74);
    const envelope = await sealWebhookSecret(
      secret,
      master,
      subscription,
      subscription,
      "fixture-1",
    );
    checks.secretEnvelope =
      (await openWebhookSecret(envelope, master, subscription, subscription))
        .every((b, i) => b === secret[i]);
    for (
      const mode of [
        "delivery",
        "challenge",
        "redirect",
        "gone",
        "retry",
        "oversize",
      ]
    ) {
      const event = crypto.randomUUID();
      const result = await send(
        origin + "/functions/v1/webhook-transport-probe/" + mode,
        {
          subscription,
          event,
          timestamp: Math.floor(Date.now() / 1000),
          body,
          secret,
        },
        { challenge: ["challenge", "oversize"].includes(mode) },
      );
      outcomes[mode] = { outcome: result.outcome, status: result.status };
      checks[mode] = mode === "delivery"
        ? result.outcome === "delivered" && result.status === 200
        : mode === "challenge"
        ? result.outcome === "delivered" &&
          result.challengeResponse === JSON.stringify({ verified: true, event })
        : mode === "redirect"
        ? result.outcome === "refused" && result.status === 302
        : mode === "gone"
        ? result.outcome === "gone" && result.status === 410
        : mode === "retry"
        ? result.outcome === "retry" && result.retryAfterSeconds === 120
        : result.outcome === "refused" && result.status === 200;
    }
    return json({
      passed: Object.values(checks).every(Boolean),
      checks,
      outcomes,
      diagnostics,
    });
  };
}

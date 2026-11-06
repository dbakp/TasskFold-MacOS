// Synthetic hosted peer only, protected from accidental main deployment. Native
// credentials never belong here. Each task body is test data on a no-data branch.
import { webhookChallengeProof } from "../../supabase/functions/automation-webhooks/challenge.ts";
const encoder = new TextEncoder();
const id = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const json = (v: unknown, status = 200) =>
  new Response(JSON.stringify(v), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
async function privateCaller(given: string, expected: string) {
  if (!/^[a-f0-9]{64}$/.test(given) || !/^[a-f0-9]{64}$/.test(expected)) {
    return false;
  }
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(expected),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const proof = await crypto.subtle.sign(
    "HMAC",
    key,
    encoder.encode("Taskfold fixture control"),
  );
  const candidate = await crypto.subtle.importKey(
    "raw",
    encoder.encode(given),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  return crypto.subtle.verify(
    "HMAC",
    candidate,
    proof,
    encoder.encode("Taskfold fixture control"),
  );
}
async function text(request: Request, maximum: number) {
  const reader = request.body?.getReader();
  if (!reader) throw Error();
  let count = 0;
  const parts: Uint8Array[] = [];
  const deadline = AbortSignal.timeout(3000);
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  deadline.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      const part = await reader.read();
      if (deadline.aborted) throw Error();
      if (part.done) break;
      if ((count += part.value.length) > maximum) throw Error();
      parts.push(part.value);
    }
    const bytes = new Uint8Array(count);
    let n = 0;
    for (const p of parts) {
      bytes.set(p, n);
      n += p.length;
    }
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } finally {
    deadline.removeEventListener("abort", abort);
    reader.releaseLock();
  }
}
export function receiver(
  config: {
    url: string;
    service: string;
    project: string;
    token: string;
    secret: Uint8Array;
  },
) {
  return async (request: Request) => {
    if (
      !/^[a-z]{20}$/.test(config.project) ||
      config.project === "zqxflydiyfjeedqvyova" ||
      config.url !== `https://${config.project}.supabase.co` ||
      config.secret.length !== 32
    ) return json({ error: "unavailable" }, 503);
    if (request.method !== "POST") return json({ error: "method" }, 405);
    const rpc = async (name: string, body: unknown) => {
      const r = await fetch(config.url + "/rest/v1/rpc/" + name, {
        method: "POST",
        redirect: "error",
        signal: AbortSignal.timeout(8000),
        headers: {
          apikey: config.service,
          Authorization: "Bearer " + config.service,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(body),
      });
      if (!r.ok) {
        await r.body?.cancel();
        throw Error();
      }
      return await r.json();
    };
    try {
      const route = new URL(request.url).pathname.split("/").at(-1);
      if (route === "inspect") {
        if (
          !await privateCaller(
            request.headers.get("X-Taskfold-Acceptance") ?? "",
            config.token,
          )
        ) return json({ error: "unauthorized" }, 401);
        const input = JSON.parse(await text(request, 1024));
        if (
          !id.test(input.subscription) ||
          Object.keys(input).join(",") !== "subscription"
        ) return json({ error: "input" }, 400);
        return json(
          await rpc("taskfold_webhook_acceptance_inspect", {
            _subscription: input.subscription,
          }),
        );
      }
      if (!["receive", "retry", "refuse", "gone"].includes(route ?? "")) {
        return json({ error: "route" }, 404);
      }
      const body = await text(request, 262144),
        sub = request.headers.get("X-Taskfold-Webhook-Id") ?? "",
        message = request.headers.get("X-Taskfold-Event-Id") ?? "",
        stamp = request.headers.get("X-Taskfold-Timestamp") ?? "",
        signature = request.headers.get("X-Taskfold-Signature") ?? "";
      if (
        !id.test(sub) || !id.test(message) || !/^\d{10}$/.test(stamp) ||
        Math.abs(Date.now() / 1000 - Number(stamp)) > 300 ||
        !/^v1=[a-f0-9]{64}$/.test(signature)
      ) return json({ error: "signature" }, 401);
      const key = await crypto.subtle.importKey(
          "raw",
          config.secret as BufferSource,
          { name: "HMAC", hash: "SHA-256" },
          false,
          ["verify"],
        ),
        sig = Uint8Array.from(
          signature.slice(3).match(/../g)!,
          (x) => parseInt(x, 16),
        );
      if (
        !await crypto.subtle.verify(
          "HMAC",
          key,
          sig,
          encoder.encode(`v1.${stamp}.${sub}.${message}.${body}`),
        )
      ) return json({ error: "signature" }, 401);
      const value = JSON.parse(body);
      if (value.type === "taskfold.webhook.verify") {
        if (value.subscription_id !== sub || value.attempt_id !== message) {
          return json({ error: "identity" }, 400);
        }
        return json({
          challenge: value.challenge,
          proof: await webhookChallengeProof(
            config.secret,
            sub,
            message,
            value.challenge,
          ),
        });
      }
      const safe = !request.headers.has("Authorization") &&
        !request.headers.has("apikey") && !request.headers.has("Cookie");
      const stored = await rpc("taskfold_webhook_acceptance_record", {
        _subscription: sub,
        _message: message,
        _body: body,
        _route: route,
        _safe: safe,
      });
      if (route === "retry" && stored.attempts === 1) {
        return new Response(null, {
          status: 503,
          headers: { "Retry-After": "1" },
        });
      }
      return new Response(null, {
        status: route === "refuse" ? 403 : route === "gone" ? 410 : 204,
      });
    } catch {
      return json({ error: "fixture-failed" }, 500);
    }
  };
}

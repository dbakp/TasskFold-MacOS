import { abortable } from "./socket.ts";
import { openWebhookSecret, type WebhookSecretEnvelope } from "./secret.ts";
import { createWebhookTransport } from "./transport.ts";
type Config = {
  url: string;
  serviceKey: string;
  workerToken: string;
  enabled: boolean;
  masterKeys: Record<string, Uint8Array>;
};
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  deliver?: ReturnType<typeof createWebhookTransport>;
};
const encoder = new TextEncoder(),
  uuid = /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/;
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
const record = (value: unknown): Record<string, unknown> => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw Error("Invalid worker response");
  }
  return value as Record<string, unknown>;
};
async function read(
  stream: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
) {
  if (!stream) throw Error("Missing worker response");
  const reader = stream.getReader(), parts: Uint8Array[] = [];
  let size = 0;
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      const part = await abortable(reader.read(), signal);
      if (part.done) break;
      if ((size += part.value.length) > maximum) {
        throw Error("Worker input bound");
      }
      parts.push(part.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const part of parts) {
      bytes.set(part, offset);
      offset += part.length;
    }
    return record(
      JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes)),
    );
  } finally {
    signal.removeEventListener("abort", abort);
    abort();
    try {
      reader.releaseLock();
    } catch { /* Pending cancelled read. */ }
  }
}
function packet(value: Record<string, unknown>, expected: string) {
  if (
    value.ready !== true || value.event_id !== expected ||
    [value.part_id, value.subscription_id, value.account].some((v) =>
      typeof v !== "string" || !uuid.test(v)
    ) || typeof value.endpoint !== "string" || typeof value.body !== "string" ||
    encoder.encode(value.body).length > 262144 ||
    typeof value.lease_until !== "string" ||
    !Number.isFinite(Date.parse(value.lease_until))
  ) throw Error("Invalid packet");
  const body = record(JSON.parse(value.body));
  if (body.version !== 1 || body.event_id !== expected) {
    throw Error("Invalid event");
  }
  if (body.type === "taskfold.event.part") {
    if (
      Object.keys(body).sort().join(",") !==
        "data,encoding,event_id,part_count,part_id,part_index,sha256,type,version" ||
      body.part_id !== value.part_id || body.encoding !== "base64" ||
      !Number.isInteger(body.part_index) ||
      !Number.isInteger(body.part_count) || (body.part_index as number) < 0 ||
      (body.part_count as number) < 2 || (body.part_count as number) > 94 ||
      (body.part_index as number) >= (body.part_count as number) ||
      typeof body.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(body.sha256) ||
      typeof body.data !== "string" || body.data.length > 240000 ||
      !/^[A-Za-z0-9+/]+={0,2}$/.test(body.data)
    ) throw Error("Invalid part");
  } else {
    if (
      Object.keys(body).sort().join(",") !==
        "event_id,occurred_at,task,type,version" ||
      ![
        "task.created",
        "task.updated",
        "task.completed",
        "task.reopened",
        "task.deleted",
        "task.removed",
      ].includes(body.type as string) || value.part_id !== expected ||
      typeof body.occurred_at !== "string" ||
      !Number.isFinite(Date.parse(body.occurred_at))
    ) throw Error("Invalid event");
    const task = record(body.task);
    if (
      typeof task.id !== "string" || !uuid.test(task.id) ||
      typeof task.task_generation !== "string" ||
      !uuid.test(task.task_generation)
    ) throw Error("Invalid task identity");
  }
  return {
    event_id: expected,
    part_id: value.part_id as string,
    subscription_id: value.subscription_id as string,
    account: value.account as string,
    endpoint: value.endpoint,
    body: value.body,
    lease_until: value.lease_until,
    secret_envelope: record(
      value.secret_envelope,
    ) as unknown as WebhookSecretEnvelope,
  };
}
export function createWebhookWorker(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch,
    deliver = dependencies.deliver ?? createWebhookTransport();
  const workerMessage = encoder.encode("taskfold.webhook.worker.v1");
  let expected: Promise<ArrayBuffer> | undefined;
  const authenticated = async (header: string | null) => {
    const supplied = /^Bearer ([a-f0-9]{64})$/.exec(header ?? "")?.[1];
    if (!supplied || !/^[a-f0-9]{64}$/.test(config.workerToken)) return false;
    expected ??= crypto.subtle.importKey(
      "raw",
      encoder.encode(config.workerToken),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    ).then((key) => crypto.subtle.sign("HMAC", key, workerMessage));
    const verifier = await crypto.subtle.importKey(
      "raw",
      encoder.encode(supplied),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      "HMAC",
      verifier,
      await expected,
      workerMessage,
    );
  };
  return async (request: Request) => {
    if (!config.enabled) {
      return json({ error: "Webhook delivery is unavailable." }, 503);
    }
    if (request.method !== "POST") return json({ error: "Use POST." }, 405);
    if (!await authenticated(request.headers.get("Authorization"))) {
      return json({ error: "Unavailable." }, 401);
    }
    const started = performance.now(),
      deadline = AbortSignal.any([request.signal, AbortSignal.timeout(55000)]);
    const counts = {
      claimed: 0,
      delivered: 0,
      retrying: 0,
      failed: 0,
      skipped: 0,
      maintenance: 0,
    };
    try {
      if (request.body) {
        const input = await read(
          request.body,
          1024,
          AbortSignal.any([deadline, AbortSignal.timeout(2000)]),
        );
        if (Object.keys(input).length) {
          return json({ error: "Use an empty worker request." }, 400);
        }
      }
      const origin = new URL(config.url);
      if (
        origin.protocol !== "https:" || origin.pathname !== "/" ||
        origin.username || origin.password || origin.search || origin.hash ||
        !config.serviceKey
      ) throw Error("Invalid worker backend");
      const api = async (action: string, body: Record<string, unknown>) => {
        const signal = AbortSignal.any([deadline, AbortSignal.timeout(9000)]);
        if (signal.aborted) throw Error("Worker deadline");
        const response = await abortable(
          send(
            new Request(
              origin.origin + "/rest/v1/rpc/taskfold_webhook_dispatch",
              {
                method: "POST",
                redirect: "error",
                signal,
                headers: {
                  Authorization: "Bearer " + config.serviceKey,
                  apikey: config.serviceKey,
                  "Content-Type": "application/json",
                },
                body: JSON.stringify({ _action: action, _body: body }),
              },
            ),
          ),
          signal,
        );
        const value = await read(response.body, 1048576, signal);
        if (response.status < 200 || response.status >= 300) {
          throw Error("Worker RPC unavailable");
        }
        return value;
      };
      for (
        let i = 0;
        i < 8 && !deadline.aborted && performance.now() - started < 40000;
        i++
      ) {
        const claim = await api("claim", {});
        if (
          Number.isInteger(claim.maintenance) &&
          (claim.maintenance as number) >= 0 &&
          (claim.maintenance as number) <= 512
        ) counts.maintenance += claim.maintenance as number;
        if (claim.event_id === null) break;
        if (
          typeof claim.event_id !== "string" || !uuid.test(claim.event_id) ||
          typeof claim.lease_id !== "string" || !uuid.test(claim.lease_id)
        ) throw Error("Invalid claim");
        counts.claimed++;
        const ref = { event_id: claim.event_id, lease_id: claim.lease_id };
        const value = await api("prepare", ref);
        if (value.ready === false) {
          counts.skipped++;
          continue;
        }
        let prepared: ReturnType<typeof packet>, secret: Uint8Array;
        try {
          prepared = packet(value, claim.event_id);
          const master = config.masterKeys[prepared.secret_envelope.keyVersion];
          if (!master) throw Error("Unavailable master");
          secret = await openWebhookSecret(
            prepared.secret_envelope,
            master,
            prepared.account,
            prepared.subscription_id,
          );
        } catch {
          await api("ack", { ...ref, outcome: "configuration" });
          counts.failed++;
          continue;
        }
        try {
          if (Date.parse(prepared.lease_until) - Date.now() < 12000) {
            await api("ack", { ...ref, outcome: "retry" });
            counts.skipped++;
            continue;
          }
          let denied = false, authorized = false;
          const result = await deliver(prepared.endpoint, {
            subscription: prepared.subscription_id,
            event: prepared.part_id,
            timestamp: Math.floor(Date.now() / 1000),
            body: prepared.body,
            secret,
          }, {
            signal: deadline,
            beforeWrite: async () => {
              const permission = await api("authorize", ref);
              if (permission.ready !== true) {
                denied = true;
                throw Error("Delivery authority changed");
              }
              authorized = true;
            },
          });
          if (denied) {
            counts.skipped++;
            continue;
          }
          if (result.outcome === "delivered" && !authorized) {
            await api("ack", { ...ref, outcome: "configuration" });
            counts.failed++;
            continue;
          }
          if (
            !["delivered", "retry", "refused", "gone"].includes(result.outcome)
          ) throw Error("Invalid outcome");
          const ack = await api("ack", {
            ...ref,
            outcome: result.outcome,
            ...(result.status !== undefined ? { status: result.status } : {}),
            ...(result.retryAfterSeconds !== undefined
              ? { retry_after: result.retryAfterSeconds }
              : {}),
          });
          if (ack.applied !== true) counts.skipped++;
          else if (result.outcome === "delivered") counts.delivered++;
          else if (result.outcome === "retry") counts.retrying++;
          else counts.failed++;
        } finally {
          secret.fill(0);
        }
      }
      return json(counts);
    } catch {
      return json({
        error: "Delivery will retry after its lease is recovered.",
        ...counts,
      }, 503);
    }
  };
}

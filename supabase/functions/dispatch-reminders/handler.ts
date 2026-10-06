import {
  type Claim,
  type DeliveryResult,
  type Provider,
  type Transport,
  uuid,
  validClaim,
  validPrepared,
} from "./apns.ts";
export interface Config {
  url: string;
  serviceKey: string;
  cronSecret: string;
  enabled: boolean;
}
const json = (status: number, value: unknown) =>
  Response.json(value, { status, headers: { "Cache-Control": "no-store" } });
function equal(a: string, b: string): boolean {
  if (a.length !== b.length || b.length < 32 || b.length > 512) return false;
  let difference = 0;
  for (let i = 0; i < b.length; i++) {
    difference |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return difference === 0;
}
/** Just-in-time single-job claims keep later jobs out of leases during a provider outage. */
export function createHandler(
  config: Config,
  provider: Provider,
  options: { send?: Transport; now?: () => number } = {},
) {
  const send = options.send ?? ((request) => fetch(request)),
    now = options.now ?? (() => performance.now());
  return async (req: Request): Promise<Response> => {
    if (!equal(req.headers.get("x-cron-secret") ?? "", config.cronSecret)) {
      return json(401, { error: "Unauthorized" });
    }
    if (req.method !== "POST") return json(405, { error: "Use POST" });
    // The database owns cursor progress. A caller cannot reset/skip the durable sweep.
    if ([...new URL(req.url).searchParams.keys()].length) {
      return json(400, { error: "Query parameters are not supported" });
    }
    if (!config.enabled) return json(200, { status: "disabled" });
    if (!config.serviceKey || !/^https:\/\/[^/]+\/?$/.test(config.url)) {
      return json(503, { error: "Delivery configuration unavailable" });
    }
    try {
      await provider.ready();
    } catch {
      return json(503, { error: "Delivery configuration unavailable" });
    }
    const deadline = now() + 50_000;
    const rpc = async (
      name: string,
      body: Record<string, unknown>,
    ): Promise<unknown> => {
      const response = await send(
        new Request(config.url.replace(/\/$/, "") + "/rest/v1/rpc/" + name, {
          method: "POST",
          redirect: "error",
          signal: AbortSignal.any([req.signal, AbortSignal.timeout(5000)]),
          headers: {
            apikey: config.serviceKey,
            Authorization: "Bearer " + config.serviceKey,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        }),
      );
      if (!response.ok) {
        await response.body?.cancel().catch(() => {});
        throw new Error("database");
      }
      return await response.json();
    };
    const counts = {
      devices: 0,
      accepted: 0,
      retry: 0,
      failed: 0,
      obsolete: 0,
      receiptRejected: 0,
    };
    const diagnostics: Partial<Record<DeliveryResult["code"], number>> = {};
    let sweep: { lease: string; after: string | null } | undefined;
    let cursor: string | null = null, retryAfter = 0;
    const finishSweep = (status: "processed" | "paused" | "error") =>
      rpc("taskfold_finish_reminder_sweep", {
        _lease: sweep!.lease,
        _after: sweep!.after,
        _next: status === "error" ? sweep!.after : cursor,
        _status: status,
        _counts: counts,
        _retry_after_seconds: status === "error" ? 30 : retryAfter,
      });
    try {
      const claimed = await rpc("taskfold_claim_reminder_sweep", {});
      if (claimed === null) return json(200, { status: "busy" });
      if (
        typeof claimed !== "object" || Array.isArray(claimed) ||
        Object.keys(claimed).sort().join(",") !== "after,lease,version" ||
        (claimed as Record<string, unknown>).version !== 1 ||
        !uuid((claimed as Record<string, unknown>).lease) ||
        ((claimed as Record<string, unknown>).after !== null &&
          !uuid((claimed as Record<string, unknown>).after))
      ) throw new Error("database");
      sweep = claimed as { lease: string; after: string | null };
      const after = sweep.after;
      cursor = after;
      await rpc("taskfold_maintain_reminder_queue", { _limit: 1000 });
      const page = await rpc("taskfold_reminder_device_page", {
        _after: after,
        _limit: 20,
      });
      if (
        !Array.isArray(page) || page.length > 20 ||
        page.some((v, i) =>
          !uuid(v) || (i > 0 ? v <= page[i - 1] : after !== null && v <= after)
        )
      ) throw new Error("database");
      let stop = false;
      for (const device of page) {
        if (req.signal.aborted || now() > deadline - 25_000) {
          stop = true;
          break;
        }
        await rpc("taskfold_reconcile_reminder_jobs", { _device: device });
        counts.devices++;
        for (let i = 0; i < 4; i++) {
          if (req.signal.aborted || now() > deadline - 25_000) {
            stop = true;
            break;
          }
          const jobs = await rpc("taskfold_claim_reminder_jobs", {
            _device: device,
            _limit: 1,
          });
          if (!Array.isArray(jobs) || jobs.length > 1) {
            throw new Error("database");
          }
          if (jobs.length === 0) break;
          if (!validClaim(jobs[0], device)) throw new Error("database");
          const job: Claim = jobs[0];
          const prepared = await rpc("taskfold_prepare_sweep_reminder_job", {
            _sweep: sweep.lease,
            _id: job.id,
            _lease: job.lease,
          });
          if (prepared === null) {
            counts.obsolete++;
            continue;
          }
          if (!validPrepared(prepared, job)) throw new Error("database");
          // A delayed response must not dispatch after our invocation/sweep budget expired.
          if (req.signal.aborted || now() > deadline - 25_000) {
            stop = true;
            break;
          }
          // No await between final preparation and dispatch apart from provider token reuse.
          const result = await provider.send(
            prepared,
            AbortSignal.any([req.signal, AbortSignal.timeout(8000)]),
          );
          diagnostics[result.code] = (diagnostics[result.code] ?? 0) + 1;
          const confirmed = await rpc("taskfold_finish_reminder_delivery", {
            _id: job.id,
            _lease: job.lease,
            _outcome: result.outcome,
            _retry_after_seconds: result.retryAfter,
          });
          if (typeof confirmed !== "boolean") throw new Error("database");
          if (!confirmed) counts.receiptRejected++;
          else if (result.outcome === "accepted") counts.accepted++;
          else if (result.outcome === "transient") counts.retry++;
          else counts.failed++;
          if (result.halt) {
            retryAfter = Math.min(3600, Math.max(30, result.retryAfter ?? 900));
            stop = true;
            break;
          }
        }
        // A halted/partially processed device is visited again, with the previous cursor.
        if (stop) break;
        cursor = device;
      }
      if (!stop && page.length < 20) cursor = null;
      const status = stop ? "paused" : "processed";
      if (await finishSweep(status) !== true) throw new Error("database");
      return json(200, {
        status,
        ...counts,
        diagnostics,
        nextCursor: cursor,
      });
    } catch {
      if (sweep && !req.signal.aborted) {
        // Never advance after a lost response. The nonce also fences a lost sweep receipt;
        // if it committed already, this cleanup cannot overwrite the newer progress.
        try {
          await finishSweep("error");
        } catch { /* two-minute lease recovery */ }
      }
      // Leases recover after two minutes. Never retry an accepted provider request in this
      // invocation after a lost database acknowledgement, or include private exception text.
      return json(502, { error: "Reminder delivery could not be completed" });
    }
  };
}

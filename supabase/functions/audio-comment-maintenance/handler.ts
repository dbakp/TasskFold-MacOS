import {
  bucket,
  digest,
  exact,
  identity,
  maximumAudioBytes,
  object,
  type Row,
} from "../audio-comments/wire.ts";
type Config = {
  url: string;
  serviceKey: string;
  maintenanceKey: string;
  enabled?: boolean;
  timeoutMilliseconds?: number;
  schedulerProject?: string;
};
type Dependencies = { send?: (request: Request) => Promise<Response> };
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
export function createAudioMaintenanceHandler(
  config: Config,
  dependencies: Dependencies = {},
) {
  const send = dependencies.send ?? fetch;
  return async (request: Request) => {
    void request.body?.cancel().catch(() => {});
    if (request.method !== "POST" || new URL(request.url).search) {
      return json({ code: "invalid" }, 400);
    }
    if (
      config.enabled !== true || config.maintenanceKey.length < 32 ||
      config.maintenanceKey.length > 256 ||
      !config.serviceKey
    ) return json({ code: "disabled" }, 503);
    const schedule = request.headers.get("X-Taskfold-Audio-Schedule");
    const presented = request.headers.get("X-Taskfold-Audio-Maintenance") ?? "";
    let scheduleProof: { nonce: string; issued: number } | null = null;
    const same = (a: Uint8Array, b: Uint8Array) => {
      let different = a.length ^ b.length;
      for (let i = 0; i < a.length; i++) different |= a[i] ^ (b[i] ?? 0);
      return different === 0;
    };
    if (schedule !== null) {
      if (
        presented || schedule.length > 160 ||
        !/^[a-f0-9]{64}$/.test(config.maintenanceKey)
      ) return json({ code: "unauthorized" }, 401);
      const parts = /^([0-9]{1,12})\.([a-f0-9-]{36})\.([a-f0-9]{64})$/.exec(
        schedule,
      );
      const now = Math.floor(Date.now() / 1000),
        ref = config.schedulerProject ??
          /^https:\/\/([a-z]{20})\.supabase\.co\/?$/.exec(config.url)?.[1];
      if (
        !parts || !identity(parts[2]) || !ref || !/^[a-z]{20}$/.test(ref) ||
        Number(parts[1]) < now - 90 || Number(parts[1]) > now + 5
      ) return json({ code: "unauthorized" }, 401);
      const key = await crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(config.maintenanceKey),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
      );
      const proof = new Uint8Array(
        await crypto.subtle.sign(
          "HMAC",
          key,
          new TextEncoder().encode(
            `taskfold.audio.maintenance.v1.${parts[1]}.${parts[2]}.${ref}`,
          ),
        ),
      );
      const received = Uint8Array.from(
        parts[3].match(/../g)!,
        (p) => parseInt(p, 16),
      );
      if (!same(proof, received)) return json({ code: "unauthorized" }, 401);
      scheduleProof = { nonce: parts[2], issued: Number(parts[1]) };
    } else {
      if (presented.length > 256) return json({ code: "unauthorized" }, 401);
      const hash = async (x: string) =>
        new Uint8Array(
          await crypto.subtle.digest("SHA-256", new TextEncoder().encode(x)),
        );
      const [a, b] = await Promise.all([
        hash(presented),
        hash(config.maintenanceKey),
      ]);
      if (!same(a, b)) return json({ code: "unauthorized" }, 401);
    }
    const expiry = new AbortController(),
      timer = setTimeout(
        () => expiry.abort(),
        Math.max(50, Math.min(25000, config.timeoutMilliseconds ?? 20000)),
      );
    const signal = AbortSignal.any([request.signal, expiry.signal]);
    const wait = <T>(work: Promise<T>) =>
      new Promise<T>((resolve, reject) => {
        const abort = () => reject(Error("deadline"));
        work.then(resolve, reject).finally(() =>
          signal.removeEventListener("abort", abort)
        );
        if (signal.aborted) abort();
        else signal.addEventListener("abort", abort, { once: true });
      });
    try {
      const origin = new URL(config.url);
      if (
        origin.protocol !== "https:" || origin.username || origin.password ||
        origin.pathname !== "/" || origin.search || origin.hash ||
        /\s/.test(config.serviceKey)
      ) throw Error();
      const headers = {
        apikey: config.serviceKey,
        Authorization: "Bearer " + config.serviceKey,
      };
      const fetchResponse = async (path: string, init: RequestInit) => {
        signal.throwIfAborted();
        const pending = send(
          new Request(origin.origin + path, {
            ...init,
            signal,
            redirect: "error",
          }),
        );
        pending.then((r) => {
          if (signal.aborted) void r.body?.cancel().catch(() => {});
        }, () => {});
        return await wait(pending);
      };
      const readBytes = async (r: Response, maximum: number) => {
        const reader = r.body?.getReader();
        if (!reader) throw Error();
        let size = 0;
        const chunks: Uint8Array[] = [];
        const cancel = () => {
          void reader.cancel().catch(() => {});
        };
        signal.addEventListener("abort", cancel, { once: true });
        try {
          while (true) {
            const p = await wait(reader.read());
            signal.throwIfAborted();
            if (p.done) break;
            size += p.value.length;
            if (size > maximum) throw Error();
            chunks.push(p.value);
          }
          const bytes = new Uint8Array(size);
          let at = 0;
          for (const c of chunks) {
            bytes.set(c, at);
            at += c.length;
          }
          return bytes;
        } catch (e) {
          cancel();
          throw e;
        } finally {
          signal.removeEventListener("abort", cancel);
          try {
            reader.releaseLock();
          } catch { /* Aborted stream. */ }
        }
      };
      const rpc = async (action: string, body: Row) => {
        const r = await fetchResponse(
          "/rest/v1/rpc/taskfold_audio_comment_maintenance",
          {
            method: "POST",
            headers: { ...headers, "Content-Type": "application/json" },
            body: JSON.stringify({ _action: action, _body: body }),
          },
        );
        if (!r.ok) {
          void r.body?.cancel().catch(() => {});
          throw Error();
        }
        return object(
          JSON.parse(
            new TextDecoder("utf-8", { fatal: true }).decode(
              await readBytes(r, 128000),
            ),
          ),
        );
      };
      if (scheduleProof) {
        const admitted = await rpc("admit_schedule", scheduleProof);
        exact(admitted, ["protocol", "admitted"]);
        if (admitted.protocol !== 1 || admitted.admitted !== true) {
          return json({ code: "unauthorized" }, 401);
        }
      }
      const canonicalPath = (r: Row) => {
        const parts = typeof r.object_name === "string"
          ? /^audio-comments\/v1\/([^/]+)\/([^/]+)\/([^/]+)\.m4a$/.exec(
            r.object_name,
          )
          : null;
        if (
          ![r.operation_id, r.asset_id].every(identity) ||
          r.bucket !== bucket || !parts || !parts.slice(1).every(identity) ||
          parts[3] !== r.asset_id
        ) throw Error();
      };
      const probe = await rpc("probe", {});
      exact(probe, ["protocol", "items"]);
      if (
        probe.protocol !== 1 || !Array.isArray(probe.items) ||
        probe.items.length > 25
      ) throw Error();
      const probes = probe.items.map((value) => {
        const r = object(value);
        exact(r, [
          "operation_id",
          "asset_id",
          "bucket",
          "object_name",
          "ticket_id",
          "sha256",
          "byte_count",
        ]);
        canonicalPath(r);
        if (
          !identity(r.ticket_id) || typeof r.sha256 !== "string" ||
          !/^([a-f0-9]{64})$/.test(r.sha256) ||
          !Number.isInteger(r.byte_count) || Number(r.byte_count) < 1 ||
          Number(r.byte_count) > maximumAudioBytes
        ) throw Error();
        return r;
      });
      if (new Set(probes.map((r) => r.operation_id)).size !== probes.length) {
        throw Error();
      }
      let recovered = 0, probeUnresolved = 0;
      for (const item of probes) {
        try {
          const stored = await fetchResponse(
            "/storage/v1/object/" + bucket + "/" + item.object_name,
            {
              method: "GET",
              headers: { ...headers, "Accept-Encoding": "identity" },
            },
          );
          if (
            !stored.ok ||
            stored.headers.get("Content-Type")?.split(";")[0].toLowerCase() !==
              "audio/mp4"
          ) {
            void stored.body?.cancel().catch(() => {});
            throw Error();
          }
          const bytes = await readBytes(stored, maximumAudioBytes);
          if (
            bytes.length !== item.byte_count ||
            await digest(bytes) !== item.sha256
          ) throw Error();
          const result = await rpc("reconcile", {
            operation_id: item.operation_id,
            asset_id: item.asset_id,
            object_name: item.object_name,
            ticket_id: item.ticket_id,
            stored_sha256: item.sha256,
            stored_bytes: bytes.length,
          });
          exact(result, ["protocol", "settled"]);
          if (result.protocol !== 1 || result.settled !== true) throw Error();
          recovered++;
        } catch {
          probeUnresolved++;
          if (signal.aborted) break;
        }
      }
      signal.throwIfAborted();
      const claim = await rpc("claim", {});
      exact(claim, ["protocol", "items", "blocked_uploads"]);
      if (
        claim.protocol !== 1 || !Array.isArray(claim.items) ||
        claim.items.length > 25 ||
        !Number.isSafeInteger(claim.blocked_uploads) ||
        Number(claim.blocked_uploads) < 0
      ) throw Error();
      // Validate the entire manifest before making even one destructive request.
      const items = claim.items.map((value) => {
        const r = object(value);
        exact(r, [
          "operation_id",
          "asset_id",
          "bucket",
          "object_name",
          "token",
        ]);
        const parts = typeof r.object_name === "string"
          ? /^audio-comments\/v1\/([^/]+)\/([^/]+)\/([^/]+)\.m4a$/.exec(
            r.object_name,
          )
          : null;
        if (
          ![r.operation_id, r.asset_id, r.token].every(identity) ||
          r.bucket !== bucket || !parts || !parts.slice(1).every(identity) ||
          parts[3] !== r.asset_id
        ) throw Error();
        return r;
      });
      if (new Set(items.map((r) => r.operation_id)).size !== items.length) {
        throw Error();
      }
      let purged = 0, unresolved = 0;
      for (const item of items) {
        try {
          const removed = await fetchResponse("/storage/v1/object/" + bucket, {
            method: "DELETE",
            headers: { ...headers, "Content-Type": "application/json" },
            body: JSON.stringify({ prefixes: [item.object_name] }),
          });
          const ok = removed.ok;
          void removed.body?.cancel().catch(() => {});
          if (!ok) throw Error();
          const absence = await fetchResponse(
            "/storage/v1/object/" + bucket + "/" + item.object_name,
            {
              method: "GET",
              headers: { ...headers, "Accept-Encoding": "identity" },
            },
          );
          const missing = absence.status === 404;
          void absence.body?.cancel().catch(() => {});
          if (!missing) throw Error();
          const result = await rpc("confirm", {
            operation_id: item.operation_id,
            asset_id: item.asset_id,
            object_name: item.object_name,
            token: item.token,
          });
          exact(result, ["protocol", "purged"]);
          if (result.protocol !== 1 || result.purged !== true) throw Error();
          purged++;
        } catch {
          unresolved++;
          if (signal.aborted) break;
        }
      }
      signal.throwIfAborted();
      return json({
        protocol: 1,
        claimed: items.length,
        recovered,
        probe_unresolved: probeUnresolved,
        blocked_uploads: claim.blocked_uploads,
        purged,
        unresolved,
      });
    } catch {
      return json({ code: "retry" }, 503);
    } finally {
      clearTimeout(timer);
    }
  };
}

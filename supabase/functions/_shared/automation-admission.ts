export type Admission = (request: Request) => Promise<Response | null>;
export type AdmissionConfig = {
  url: string;
  serviceKey: string;
  forwardedForMode?: string;
};
// Enabling this mode requires a real hosted spoof/append probe first. An unset mode or
// malformed last hop fails closed; other forwarding headers are ignored.
export function forwardedIP(
  request: Request,
  mode: string | undefined,
): string | null {
  if (mode !== "supabase-append-v1") return null;
  const header = request.headers.get("X-Forwarded-For");
  if (!header || header.length > 2048) return null;
  const text = header.split(",").at(-1)!.trim();
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(text)) {
    const parts = text.split(".");
    if (parts.some((p) => Number(p) > 255 || p !== String(Number(p)))) {
      return null;
    }
    return parts.join(".");
  }
  if (!/^[0-9a-fA-F:]+$/.test(text) || !text.includes(":")) return null;
  try {
    const host = new URL("http://[" + text + "]/").hostname;
    return host.slice(1, -1).toLowerCase();
  } catch {
    return null;
  }
}
const response = (status: number, retry = 0) =>
  new Response(
    JSON.stringify({
      error: status === 429
        ? "Too many automation requests. Try again shortly."
        : "Automation access is temporarily unavailable.",
    }),
    {
      status,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Expose-Headers": "Retry-After",
        ...(retry ? { "Retry-After": String(retry) } : {}),
      },
    },
  );
export function createAdmission(
  config: AdmissionConfig,
  route: "tasks" | "keys",
  send: (request: Request) => Promise<Response> = fetch,
): Admission {
  // Only negative decisions are cached. Positive admissions always reach the
  // durable shared budget; concurrent cold workers cannot multiply that allowance.
  const denied = new Map<string, number>();
  let key: Promise<CryptoKey> | undefined;
  const fingerprint = async (domain: string, text: string) => {
    key ??= crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(config.serviceKey),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const data = await crypto.subtle.sign(
      "HMAC",
      await key,
      new TextEncoder().encode("taskfold.ingress.v1|" + domain + "|" + text),
    );
    return Array.from(
      new Uint8Array(data),
      (b) => b.toString(16).padStart(2, "0"),
    ).join("");
  };
  return async (request) => {
    if (request.method === "OPTIONS") return null;
    const ip = forwardedIP(request, config.forwardedForMode);
    let origin: string;
    try {
      const url = new URL(config.url);
      if (
        url.protocol !== "https:" || url.username || url.password ||
        url.search || url.hash || url.pathname !== "/" || !config.serviceKey ||
        !ip
      ) throw new Error();
      origin = url.origin;
    } catch {
      void request.body?.cancel().catch(() => {});
      return response(503);
    }
    const authorization = request.headers.get("Authorization") ?? "";
    const credential = /^Bearer ([^\s]{1,8192})$/i.exec(authorization)?.[1] ??
      (authorization.length > 8200 ? "oversized" : authorization);
    try {
      const [ipHash, credentialHash] = await Promise.all([
        fingerprint("ip", ip!),
        fingerprint("credential", credential),
      ]);
      const now = Date.now();
      for (const [id, expires] of denied) if (expires <= now) denied.delete(id);
      for (
        const id of ["global", "ip:" + ipHash, "credential:" + credentialHash]
      ) {
        const end = denied.get(id);
        if (end && end > now) {
          void request.body?.cancel().catch(() => {});
          return response(429, Math.max(1, Math.ceil((end - now) / 1000)));
        }
      }
      const signal = AbortSignal.any([
        request.signal,
        AbortSignal.timeout(2000),
      ]);
      if (signal.aborted) throw new Error();
      const upstream = await send(
        new Request(origin + "/rest/v1/rpc/taskfold_automation_admit", {
          method: "POST",
          redirect: "error",
          signal,
          headers: {
            "Content-Type": "application/json",
            apikey: config.serviceKey,
            Authorization: "Bearer " + config.serviceKey,
          },
          body: JSON.stringify({
            _route: route,
            _ip_hash: ipHash,
            _credential_hash: credentialHash,
          }),
        }),
      );
      if (signal.aborted) {
        void upstream.body?.cancel().catch(() => {});
        throw new Error();
      }
      const reader = upstream.body?.getReader();
      if (!reader) throw new Error();
      const abort = () => {
        void reader.cancel().catch(() => {});
      };
      signal.addEventListener("abort", abort, { once: true });
      let size = 0, text = "";
      const decoder = new TextDecoder("utf-8", { fatal: true });
      try {
        while (true) {
          const part = await reader.read();
          if (signal.aborted) throw new Error();
          if (part.done) break;
          size += part.value.length;
          if (size > 2048) throw new Error();
          text += decoder.decode(part.value, { stream: true });
        }
        text += decoder.decode();
      } finally {
        signal.removeEventListener("abort", abort);
        void reader.cancel().catch(() => {});
        reader.releaseLock();
      }
      if (!upstream.ok) throw new Error();
      const value = JSON.parse(text);
      if (
        !value || typeof value !== "object" || Array.isArray(value) ||
        typeof value.allowed !== "boolean" ||
        !Number.isInteger(value.retry_after)
      ) throw new Error();
      if (value.allowed) {
        if (value.retry_after !== 0 || value.limited_by !== null) {
          throw new Error();
        }
        return null;
      }
      if (
        value.retry_after < 1 || value.retry_after > 60 ||
        !["global", "ip", "credential"].includes(value.limited_by)
      ) throw new Error();
      const cacheKey = value.limited_by === "global"
        ? "global"
        : value.limited_by + ":" +
          (value.limited_by === "ip" ? ipHash : credentialHash);
      if (denied.size >= 1024) denied.delete(denied.keys().next().value!);
      // Start at request arrival, so network latency cannot lengthen a deny window.
      denied.set(cacheKey, now + value.retry_after * 1000);
      void request.body?.cancel().catch(() => {});
      return response(429, value.retry_after);
    } catch {
      void request.body?.cancel().catch(() => {});
      return response(503);
    }
  };
}

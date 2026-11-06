// Temporary authenticated diagnostics only. This is never a production entrypoint.
// The deployment harness supplies a fresh public key and deletes its unique slug.
import {
  canonicalAutomationIP,
  forwardedIP,
} from "../../supabase/functions/_shared/automation-admission.ts";
type ProbeConfig = {
  publicKey: JsonWebKey;
  expires: number;
  selfURL: string;
  fingerprintKey: string;
};
const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
async function text(
  body: ReadableStream<Uint8Array> | null,
  maximum: number,
  signal: AbortSignal,
) {
  const reader = body?.getReader();
  if (!reader) throw new Error();
  let size = 0, result = "";
  const decoder = new TextDecoder("utf-8", { fatal: true });
  const abort = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", abort, { once: true });
  try {
    if (signal.aborted) throw new Error();
    while (true) {
      const part = await reader.read();
      if (signal.aborted) throw new Error();
      if (part.done) break;
      size += part.value.length;
      if (size > maximum) throw new Error();
      result += decoder.decode(part.value, { stream: true });
    }
    return result + decoder.decode();
  } finally {
    signal.removeEventListener("abort", abort);
    void reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
function publicAddress(ip: string): boolean {
  if (ip.includes(":")) return !/^(::|f[cd]|fe[89ab]|2001:db8)/i.test(ip);
  const [a, b, c] = ip.split(".").map(Number);
  return a > 0 && a < 224 && a !== 10 && a !== 127 &&
    !(a === 100 && b >= 64 && b <= 127) && !(a === 169 && b === 254) &&
    !(a === 172 && b >= 16 && b <= 31) &&
    !(a === 192 && (b === 168 || (b === 0 && (c === 0 || c === 2)))) &&
    !(a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) &&
    !(a === 203 && b === 0 && c === 113);
}
export function createIngressProbe(
  config: ProbeConfig,
  send: (r: Request) => Promise<Response> = fetch,
) {
  let key: Promise<CryptoKey> | undefined, hmac: Promise<CryptoKey> | undefined;
  return async (request: Request): Promise<Response> => {
    if (!config.fingerprintKey) {
      return json({ error: "Probe unavailable" }, 503);
    }
    if (Date.now() > config.expires) {
      return json({ error: "Probe expired" }, 410);
    }
    if (request.method !== "POST") return json({ error: "POST required" }, 405);
    const signal = AbortSignal.any([request.signal, AbortSignal.timeout(5000)]);
    let raw: string;
    try {
      raw = await text(request.body, 2048, signal);
    } catch {
      return json({ error: "Invalid probe body" }, 400);
    }
    const signature = request.headers.get("X-Taskfold-Probe-Signature") ?? "";
    if (!/^[A-Za-z0-9_-]{86}$/.test(signature)) {
      return json({ error: "Probe authentication required" }, 401);
    }
    try {
      key ??= crypto.subtle.importKey(
        "jwk",
        config.publicKey,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"],
      );
      hmac ??= crypto.subtle.importKey(
        "raw",
        new TextEncoder().encode(config.fingerprintKey),
        { name: "HMAC", hash: "SHA-256" },
        false,
        ["sign"],
      );

      const bytes = Uint8Array.from(
        atob(signature.replaceAll("-", "+").replaceAll("_", "/") + "=="),
        (c) => c.charCodeAt(0),
      );
      if (
        !await crypto.subtle.verify(
          { name: "ECDSA", hash: "SHA-256" },
          await key,
          bytes,
          new TextEncoder().encode(raw),
        )
      ) return json({ error: "Probe authentication required" }, 401);
      const body = JSON.parse(raw);
      if (
        !body || !Number.isSafeInteger(body.at) ||
        Math.abs(Date.now() - body.at) > 60000 ||
        typeof body.nonce !== "string" || !/^[a-f0-9-]{36}$/.test(body.nonce)
      ) return json({ error: "Probe authentication required" }, 401);
      if (body.mode === "relay") {
        const child = body.child;
        if (
          !child || typeof child.body !== "string" || child.body.length > 512 ||
          typeof child.signature !== "string" ||
          JSON.parse(child.body).mode !== "direct"
        ) return json({ error: "Invalid relay" }, 400);
        const url = new URL(config.selfURL);
        if (
          url.protocol !== "https:" || url.search || url.hash || url.username ||
          url.password
        ) throw new Error();
        const result = await send(
          new Request(config.selfURL, {
            method: "POST",
            redirect: "error",
            signal,
            headers: {
              "Content-Type": "application/json",
              "X-Taskfold-Probe-Signature": child.signature,
              ...(body.spoof ? { "X-Forwarded-For": "192.0.2.222" } : {}),
            },
            body: child.body,
          }),
        );
        const value = JSON.parse(await text(result.body, 4096, signal));
        if (
          !result.ok || value.nonce !== JSON.parse(child.body).nonce ||
          typeof value.lastFingerprint !== "string"
        ) throw new Error();
        return json({ nonce: body.nonce, relayed: value });
      }
      if (body.mode !== "direct") return json({ error: "Invalid mode" }, 400);
      const ip = canonicalAutomationIP(
        (request.headers.get("X-Forwarded-For") ?? "").split(",").at(-1)!
          .trim(),
      );
      const source = request.headers.get("X-Forwarded-For") ?? "";
      const hops = source.split(",").map((v) => v.trim());
      const data = ip
        ? await crypto.subtle.sign(
          "HMAC",
          await hmac,
          new TextEncoder().encode("taskfold.probe.ip.v1|" + ip),
        )
        : null;
      const rawCandidates: Record<string, string | null> = {
        xff_first: hops[0],
        xff_last: hops.at(-1) ?? null,
        x_real_ip: request.headers.get("X-Real-IP"),
        cf_connecting_ip: request.headers.get("CF-Connecting-IP"),
        true_client_ip: request.headers.get("True-Client-IP"),
        x_client_ip: request.headers.get("X-Client-IP"),
        envoy_external: request.headers.get("X-Envoy-External-Address"),
        sb_client_ip: request.headers.get("X-SB-Client-IP"),
      };
      const identities: Record<string, unknown> = {};
      for (const [name, value] of Object.entries(rawCandidates)) {
        const candidate = value && !value.includes(",")
          ? canonicalAutomationIP(value.trim())
          : null;
        const signed = candidate
          ? await crypto.subtle.sign(
            "HMAC",
            await hmac,
            new TextEncoder().encode("taskfold.probe.ip.v1|" + candidate),
          )
          : null;
        identities[name] = {
          canonical: candidate !== null,
          public: candidate ? publicAddress(candidate) : false,
          injected: candidate === "192.0.2.222",
          fingerprint: signed
            ? Array.from(
              new Uint8Array(signed),
              (b) => b.toString(16).padStart(2, "0"),
            ).join("")
            : null,
        };
      }
      return json({
        nonce: body.nonce,
        identities,
        productionPairVerified:
          forwardedIP(request, "supabase-cloudflare-v1") !== null,
        canonicalLastHop: ip !== null,
        hopCount: source ? hops.length : 0,
        lastPublic: ip ? publicAddress(ip) : false,
        lastFingerprint: data
          ? Array.from(
            new Uint8Array(data),
            (b) => b.toString(16).padStart(2, "0"),
          ).join("")
          : null,
        injectedInPrefix: hops.slice(0, -1).includes("192.0.2.222"),
        injectedInLast: hops.at(-1) === "192.0.2.222",
      });
    } catch {
      return json({ error: "Probe unavailable" }, 503);
    }
  };
}

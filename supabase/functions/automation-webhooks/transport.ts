// Inactive webhook candidate. There is deliberately no public handler yet.
// Never replace this socket path with fetch(url): a second DNS lookup would
// separate address authorization from the connection that receives task data.
import { lookup } from "node:dns/promises";
import { BlockList, isIP } from "node:net";
import { abortable, connectWebhookSocket, postWebhook } from "./socket.ts";

const encoder = new TextEncoder();
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const v4 = new BlockList(), v6 = new BlockList(), specialV6 = new BlockList();
// IANA special-purpose registries, reviewed 23 October 2026. Multicast is
// excluded separately. Global special-purpose exceptions remain usable.
for (
  const [address, prefix] of [
    ["0.0.0.0", 8],
    ["10.0.0.0", 8],
    ["100.64.0.0", 10],
    ["127.0.0.0", 8],
    ["169.254.0.0", 16],
    ["172.16.0.0", 12],
    ["192.0.0.0", 24],
    ["192.0.2.0", 24],
    ["192.88.99.0", 24],
    ["192.168.0.0", 16],
    ["198.18.0.0", 15],
    ["198.51.100.0", 24],
    ["203.0.113.0", 24],
    ["224.0.0.0", 4],
    ["240.0.0.0", 4],
  ] as const
) v4.addSubnet(address, prefix, "ipv4");
v6.addSubnet("2001:db8::", 32, "ipv6");
v6.addSubnet("2002::", 16, "ipv6"); // 6to4 can encode a private IPv4 destination.
v6.addSubnet("3fff::", 20, "ipv6");
specialV6.addSubnet("2001::", 23, "ipv6");
const globalV6Exceptions = new BlockList();
for (const address of ["2001:1::1", "2001:1::2", "2001:1::3"]) {
  globalV6Exceptions.addAddress(address, "ipv6");
}
for (
  const [address, prefix] of [
    ["2001:3::", 32],
    ["2001:4:112::", 48],
    ["2001:20::", 28],
    ["2001:30::", 28],
  ] as const
) globalV6Exceptions.addSubnet(address, prefix, "ipv6");
const globalUnicastV6 = new BlockList();
globalUnicastV6.addSubnet("2000::", 3, "ipv6");

export function publicWebhookAddress(address: string): boolean {
  if (isIP(address) === 4) {
    return address === "192.0.0.9" || address === "192.0.0.10" ||
      !v4.check(address, "ipv4");
  }
  // Reject mapped/compatible/NAT64, ULA, link-local, zone IDs and all addresses
  // outside ordinary global unicast. Do not reinterpret embedded IPv4 text.
  return isIP(address) === 6 && globalUnicastV6.check(address, "ipv6") &&
    !v6.check(address, "ipv6") &&
    (!specialV6.check(address, "ipv6") ||
      globalV6Exceptions.check(address, "ipv6"));
}

export function webhookTarget(value: string) {
  if (
    typeof value !== "string" || value.length > 4096 ||
    !/^https:\/\//i.test(value) || /[\s\\#]/.test(value) ||
    Array.from(value).some((c) =>
      c.charCodeAt(0) < 32 || c.charCodeAt(0) === 127
    )
  ) {
    throw new Error("Invalid webhook destination");
  }
  const url = new URL(value);
  if (
    url.protocol !== "https:" || url.username || url.password || url.hash ||
    url.port === "0"
  ) {
    throw new Error("Invalid webhook destination");
  }
  const hostname = url.hostname.replace(/^\[|\]$/g, "").replace(/\.$/, "");
  const literal = isIP(hostname);
  if (
    literal ? !publicWebhookAddress(hostname) : (
      hostname.length > 253 || !hostname.includes(".") ||
      hostname.split(".").some((label) =>
        !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label)
      ) ||
      /(?:^|\.)(?:localhost|local|internal|invalid|test)$/.test(hostname) ||
      hostname.endsWith(".home.arpa")
    )
  ) throw new Error("Invalid webhook destination");
  // Normalize the certificate/HTTP identity as well as the resolver input.
  url.hostname = literal === 6 ? "[" + hostname + "]" : hostname;
  return {
    url: url.href,
    hostname,
    authority: url.host,
    port: Number(url.port || 443),
    path: url.pathname + url.search,
  };
}

export type WebhookMessage = {
  subscription: string;
  event: string;
  timestamp: number; // Unix seconds, refreshed for each delivery attempt.
  body: string; // Immutable UTF-8 JSON; retry the same event ID and body.
  secret: Uint8Array; // A distinct 256-bit receiver secret, not an API key.
};
export async function webhookHeaders(message: WebhookMessage) {
  if (
    !uuid.test(message.subscription) || !uuid.test(message.event) ||
    !Number.isSafeInteger(message.timestamp) || message.timestamp < 0 ||
    message.secret.length !== 32 || typeof message.body !== "string" ||
    encoder.encode(message.body).length > 262144
  ) {
    throw new Error("Invalid webhook message");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    message.secret as BufferSource,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signed = encoder.encode(
    `v1.${message.timestamp}.${message.subscription}.${message.event}.${message.body}`,
  );
  const signature = new Uint8Array(
    await crypto.subtle.sign("HMAC", key, signed),
  );
  return {
    "Content-Type": "application/json",
    "Content-Length": String(encoder.encode(message.body).length),
    "User-Agent": "Taskfold-Webhooks/1",
    "X-Taskfold-Webhook-Id": message.subscription,
    "X-Taskfold-Event-Id": message.event,
    "X-Taskfold-Timestamp": String(message.timestamp),
    "X-Taskfold-Signature": "v1=" +
      Array.from(signature, (x) => x.toString(16).padStart(2, "0")).join(""),
  };
}

export type WebhookResult = {
  outcome: "delivered" | "retry" | "refused" | "gone";
  status?: number;
  retryAfterSeconds?: number;
  // Only requested for a verification challenge. Delivery never exposes bodies.
  challengeResponse?: string;
};
type Address = { address: string; family: number };
type Dependencies = {
  resolve?: (hostname: string) => Promise<Address[]>;
  connect?: typeof connectWebhookSocket;
};

function retryAfter(value: string | string[] | undefined, now: number) {
  if (typeof value !== "string" || value.length > 128) return undefined;
  const seconds = /^\d{1,10}$/.test(value)
    ? Number(value)
    : (Date.parse(value) - now) / 1000;
  if (!Number.isFinite(seconds) || seconds < 0) return undefined;
  return Math.min(86400, Math.max(1, Math.ceil(seconds)));
}

export function createWebhookTransport(dependencies: Dependencies = {}) {
  const resolve = dependencies.resolve ??
    ((host) => lookup(host, { all: true, verbatim: true }));
  const connect = dependencies.connect ?? connectWebhookSocket;
  return async function deliver(
    destination: string,
    message: WebhookMessage,
    options: { signal?: AbortSignal; challenge?: boolean } = {},
  ): Promise<WebhookResult> {
    const signal = AbortSignal.any([
      AbortSignal.timeout(10000),
      ...(options.signal ? [options.signal] : []),
    ]);
    let target: ReturnType<typeof webhookTarget>;
    let headers: Awaited<ReturnType<typeof webhookHeaders>>;
    try {
      // Caller-owned mutable buffers/records cannot change after signing.
      message = { ...message, secret: message.secret.slice() };
      target = webhookTarget(destination);
      headers = await abortable(webhookHeaders(message), signal);
    } catch {
      return { outcome: "refused" };
    }
    let addresses: Address[];
    try {
      addresses = isIP(target.hostname)
        ? [{ address: target.hostname, family: isIP(target.hostname) }]
        : await abortable(resolve(target.hostname), signal);
    } catch {
      return { outcome: "retry" };
    }
    // Reject the entire answer set if it contains a private/unknown address.
    // A later retry resolves anew, but this attempt uses only this checked IP.
    if (
      !addresses.length || addresses.length > 16 ||
      addresses.some((a) =>
        !publicWebhookAddress(a.address) || isIP(a.address) !== a.family
      )
    ) {
      return { outcome: "refused" };
    }
    const pinned = addresses[0];
    try {
      const socket = await connect(
        pinned.address,
        target.port,
        target.hostname,
        signal,
      );
      const result = await postWebhook(
        socket,
        target,
        headers,
        message.body,
        signal,
        options.challenge === true,
      );
      const status = result.status;
      if (result.refused) return { outcome: "refused", status };
      if (status >= 200 && status < 300) {
        return {
          outcome: "delivered",
          status,
          ...(result.challengeResponse !== undefined
            ? { challengeResponse: result.challengeResponse }
            : {}),
        };
      }
      if (status === 410) return { outcome: "gone", status };
      if ([408, 425, 429].includes(status) || status >= 500) {
        const seconds = retryAfter(result.retryAfter, Date.now());
        return {
          outcome: "retry",
          status,
          ...(seconds ? { retryAfterSeconds: seconds } : {}),
        };
      }
      return { outcome: "refused", status };
    } catch {
      return { outcome: "retry" };
    }
  };
}

/** Provider-only addresses/keys. Never return these objects from an HTTP handler or log errors. */
export type Outcome = "accepted" | "transient" | "permanent" | "invalid_token";
export interface DeliveryResult {
  outcome: Outcome;
  retryAfter: number | null;
  halt: boolean;
  code:
    | "accepted"
    | "retry"
    | "unregistered"
    | "payload"
    | "provider_configuration"
    | "transport";
}
export interface KeyConfig {
  platform: "ios" | "macos";
  environment: "development" | "production";
  bundle: string;
  teamID: string;
  keyID: string;
  privateKey: string;
}
export interface Claim {
  id: string;
  lease: string;
  device: string;
  account: string;
  task: string;
  spec: string;
  signature: string;
  fire_at: string;
  attempt: number;
}
export interface Prepared {
  id: string;
  provider_id: string;
  collapse_id: string;
  binding: {
    platform: string;
    environment: string;
    bundle: string;
    token: string;
    enabled: boolean;
    permission: string;
  };
  content: { title: string; info: Record<string, unknown> };
}
export interface Provider {
  ready(): Promise<void>;
  send(payload: Prepared, signal: AbortSignal): Promise<DeliveryResult>;
}
export type Transport = (request: Request) => Promise<Response>;
export const uuid = (value: unknown): value is string =>
  typeof value === "string" &&
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value);
const hash = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const signature = (value: unknown): value is string =>
  typeof value === "string" && /^r[34]:[0-9a-f]{64}$/.test(value);
const object = (v: unknown): v is Record<string, unknown> =>
  !!v && typeof v === "object" && !Array.isArray(v);
const scope = (k: { platform: string; environment: string; bundle: string }) =>
  `${k.platform}/${k.environment}/${k.bundle}`;
export function validClaim(v: unknown, device: string): v is Claim {
  return object(v) && hash(v.id) && uuid(v.lease) && v.device === device &&
    uuid(v.account) && uuid(v.task) && uuid(v.spec) && signature(v.signature) &&
    typeof v.fire_at === "string" && Number.isFinite(Date.parse(v.fire_at)) &&
    Number.isInteger(v.attempt) && Number(v.attempt) >= 1 &&
    Number(v.attempt) <= 8;
}
export function validPrepared(v: unknown, job: Claim): v is Prepared {
  if (
    !object(v) || v.id !== job.id || v.collapse_id !== job.id ||
    !uuid(v.provider_id) || !object(v.binding) || !object(v.content) ||
    !object(v.content.info)
  ) return false;
  const b = v.binding,
    info = v.content.info,
    instant = Date.parse(job.fire_at) / 1000;
  return (b.platform === "ios" || b.platform === "macos") &&
    b.bundle ===
      (b.platform === "ios"
        ? "com.dbakp.taskfold"
        : "com.dbakp.taskfold.mac") &&
    (b.environment === "development" || b.environment === "production") &&
    b.enabled === true &&
    (b.permission === "authorized" || b.permission === "provisional") &&
    typeof b.token === "string" && /^[0-9a-f]{2,1024}$/.test(b.token) &&
    b.token.length % 2 === 0 && typeof v.content.title === "string" &&
    info.eventKind === "task" &&
    (info.eventID === job.task || info.eventID === `${job.task}.${job.spec}`) &&
    info.accountID === job.account && info.taskID === job.task &&
    info.specID === job.spec && info.signature === job.signature &&
    info.snoozed === false && typeof info.originalAt === "number" &&
    typeof info.fireAt === "number" &&
    Math.abs(info.originalAt - instant) < 0.001 &&
    Math.abs(info.fireAt - instant) < 0.001;
}
export function parseKeys(json: string): KeyConfig[] {
  const values: unknown = JSON.parse(json);
  if (!Array.isArray(values) || values.length < 1 || values.length > 4) {
    throw new Error("configuration");
  }
  const seen = new Set<string>();
  return values.map((v) => {
    if (
      !object(v) || !["ios", "macos"].includes(String(v.platform)) ||
      !["development", "production"].includes(String(v.environment)) ||
      v.bundle !==
        (v.platform === "ios"
          ? "com.dbakp.taskfold"
          : "com.dbakp.taskfold.mac") ||
      typeof v.teamID !== "string" || !/^[A-Z0-9]{10}$/.test(v.teamID) ||
      typeof v.keyID !== "string" || !/^[A-Z0-9]{10}$/.test(v.keyID) ||
      typeof v.privateKey !== "string" || v.privateKey.length > 4096 ||
      !v.privateKey.includes("-----BEGIN PRIVATE KEY-----")
    ) throw new Error("configuration");
    const key = v as unknown as KeyConfig;
    if (seen.has(scope(key))) throw new Error("configuration");
    seen.add(scope(key));
    return key;
  });
}
function base64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replaceAll("+", "-").replaceAll(
    "/",
    "_",
  ).replace(/=+$/, "");
}
const encoded = (value: unknown) =>
  base64url(new TextEncoder().encode(JSON.stringify(value)));
async function importKey(pem: string): Promise<CryptoKey> {
  const data = pem.replace("-----BEGIN PRIVATE KEY-----", "").replace(
    "-----END PRIVATE KEY-----",
    "",
  ).replace(/\s/g, "");
  return await crypto.subtle.importKey(
    "pkcs8",
    Uint8Array.from(atob(data), (c) => c.charCodeAt(0)),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}
/** Isolate-local token reuse; scopes have separate HTTP/2 pools in index.ts. */
export function createAPNsProvider(
  keys: KeyConfig[],
  options: { send: Transport; now?: () => number },
): Provider {
  const now = options.now ?? Date.now;
  const signers = new Map<
    string,
    {
      config: KeyConfig;
      key?: Promise<CryptoKey>;
      cached?: { token: string; at: number };
      signing?: Promise<string>;
    }
  >();
  for (const config of keys) signers.set(scope(config), { config });
  const token = async (
    signer: NonNullable<ReturnType<typeof signers.get>>,
  ): Promise<string> => {
    const seconds = Math.floor(now() / 1000);
    if (
      signer.cached && seconds >= signer.cached.at &&
      seconds - signer.cached.at < 45 * 60
    ) return signer.cached.token;
    if (signer.signing) return await signer.signing;
    signer.signing = (async () => {
      const data = encoded({ alg: "ES256", kid: signer.config.keyID }) + "." +
        encoded({ iss: signer.config.teamID, iat: seconds });
      signer.key ??= importKey(signer.config.privateKey);
      const signature = new Uint8Array(
        await crypto.subtle.sign(
          { name: "ECDSA", hash: "SHA-256" },
          await signer.key,
          new TextEncoder().encode(data),
        ),
      );
      if (signature.length !== 64) throw new Error("configuration");
      const value = data + "." + base64url(signature);
      signer.cached = { token: value, at: seconds };
      return value;
    })();
    try {
      return await signer.signing;
    } finally {
      signer.signing = undefined;
    }
  };
  return {
    async ready() {
      if (keys.length === 0) throw new Error("configuration");
      await Promise.all([...signers.values()].map(token));
    },
    async send(payload, signal) {
      const signer = signers.get(scope(payload.binding));
      if (!signer) {
        return {
          outcome: "transient",
          retryAfter: 900,
          halt: true,
          code: "provider_configuration",
        };
      }
      const info = payload.content.info;
      // Copy only the documented route. Extra server fields/notes never become provider payload.
      const route = Object.fromEntries(
        [
          "eventKind",
          "eventID",
          "accountID",
          "taskID",
          "specID",
          "signature",
          "originalAt",
          "fireAt",
          "snoozed",
        ].map((key) => [key, info[key]]),
      );
      const title = [...payload.content.title].slice(0, 128).join("");
      const body = JSON.stringify({
        aps: {
          alert: { title, body: "Open Taskfold to review this task." },
          sound: "default",
          category: "taskfold.reminder",
        },
        ...route,
      });
      if (new TextEncoder().encode(body).length > 4096) {
        return {
          outcome: "permanent",
          retryAfter: null,
          halt: false,
          code: "payload",
        };
      }
      try {
        const server = payload.binding.environment === "development"
          ? "api.sandbox.push.apple.com"
          : "api.push.apple.com";
        const response = await options.send(
          new Request(`https://${server}/3/device/${payload.binding.token}`, {
            method: "POST",
            signal,
            redirect: "error",
            headers: {
              authorization: "bearer " + await token(signer),
              "content-type": "application/json",
              "apns-topic": payload.binding.bundle,
              "apns-push-type": "alert",
              "apns-priority": "10",
              "apns-id": payload.provider_id,
              "apns-collapse-id": payload.collapse_id,
              "apns-expiration": "0",
            },
            body,
          }),
        );
        if (response.status === 200) {
          await response.body?.cancel().catch(() => {});
          return {
            outcome: "accepted",
            retryAfter: null,
            halt: false,
            code: "accepted",
          };
        }
        const reason = await boundedReason(response);
        if (
          (response.status === 410 &&
            ["Unregistered", "ExpiredToken"].includes(reason)) ||
          (response.status === 400 &&
            ["BadDeviceToken", "DeviceTokenNotForTopic"].includes(reason))
        ) {
          return {
            outcome: "invalid_token",
            retryAfter: null,
            halt: false,
            code: "unregistered",
          };
        }
        // Stop a batch on signing/topic errors rather than exhausting every device's queue.
        if (
          response.status === 403 ||
          (response.status === 429 &&
            reason === "TooManyProviderTokenUpdates") ||
          ["BadTopic", "MissingTopic", "TopicDisallowed"].includes(reason)
        ) {
          return {
            outcome: "transient",
            retryAfter: 900,
            halt: true,
            code: "provider_configuration",
          };
        }
        if (response.status === 429 || response.status >= 500) {
          const minimum = response.status >= 500 ? 900 : 30;
          return {
            outcome: "transient",
            retryAfter: retryDelay(
              response.headers.get("retry-after"),
              now(),
              minimum,
            ),
            halt: response.status >= 500,
            code: "retry",
          };
        }
        if (response.status === 413 || reason === "PayloadTooLarge") {
          return {
            outcome: "permanent",
            retryAfter: null,
            halt: false,
            code: "payload",
          };
        }
        // Unknown 4xx/endpoint responses indicate an adapter/configuration problem. Avoid
        // permanently discarding valid task occurrences or retiring an unconfirmed token.
        return {
          outcome: "transient",
          retryAfter: 900,
          halt: true,
          code: "provider_configuration",
        };
      } catch {
        return {
          outcome: "transient",
          retryAfter: 900,
          halt: true,
          code: "transport",
        };
      }
    },
  };
}
async function boundedReason(response: Response): Promise<string> {
  if (!response.body) return "";
  const reader = response.body.getReader();
  let text = "", count = 0;
  try {
    const decoder = new TextDecoder();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      count += value.length;
      if (count > 4096) return "";
      text += decoder.decode(value, { stream: true });
    }
    const data: unknown = JSON.parse(text + decoder.decode());
    return object(data) && typeof data.reason === "string" ? data.reason : "";
  } catch {
    return "";
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}
function retryDelay(
  value: string | null,
  now: number,
  minimum: number,
): number {
  const seconds = value && /^\d{1,10}$/.test(value)
    ? Number(value)
    : value
    ? Math.ceil((Date.parse(value) - now) / 1000)
    : NaN;
  return Math.max(
    minimum,
    Math.min(3600, Number.isFinite(seconds) ? seconds : minimum),
  );
}

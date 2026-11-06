// Composition layer only. No Deno.serve, credentials, deployment or permissive
// admission default. An actual provider verifier and durable email-specific
// admission must be wired and accepted before any public endpoint is enabled.
import {
  type EmailIngressConfig,
  EmailIngressError,
  emailIngressLimits,
  type EmailJournalArguments,
  prepareVerifiedEmailDelivery,
  validateEmailIngressConfig,
  verifyEmailEnvelope,
} from "./mod.ts";
type Admission = { allowed: true } | { allowed: false; retryAfter: number };
export type EmailIngressDependencies = {
  admit: (
    phase: "before_read" | "verified",
    headers: Headers,
    provider: string,
    signal: AbortSignal,
  ) => Promise<Admission>;
  deliver: (
    args: EmailJournalArguments,
    signal: AbortSignal,
  ) => Promise<{ accepted: true; replayed: boolean }>;
  now?: () => number;
};
export class EmailJournalRefusal extends Error {
  constructor(readonly code: string) {
    super("Email journal refused delivery");
  }
}
const response = (status: number, reason: string, retry = false) =>
  new Response(JSON.stringify({ error: reason }), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...(retry ? { "Retry-After": "1" } : {}),
    },
  });
function until<T>(promise: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const aborted = () => reject(new EmailIngressError("deadline", 503));
    if (signal.aborted) {
      aborted();
      void promise.catch(() => {});
      return;
    }
    signal.addEventListener("abort", aborted, { once: true });
    promise.then(resolve, reject).finally(() =>
      signal.removeEventListener("abort", aborted)
    );
  });
}
async function readBody(request: Request, signal: AbortSignal) {
  const reader = request.body?.getReader();
  if (!reader) throw new EmailIngressError("body_size", 413);
  const parts: Uint8Array[] = [];
  let length = 0;
  const cancel = () => {
    void reader.cancel().catch(() => {});
  };
  signal.addEventListener("abort", cancel, { once: true });
  try {
    while (true) {
      const part = await until(reader.read(), signal);
      if (signal.aborted) throw new EmailIngressError("deadline", 503);
      if (part.done) break;
      length += part.value.length;
      if (
        parts.length >= emailIngressLimits.streamChunks ||
        length > emailIngressLimits.bodyBytes
      ) {
        throw new EmailIngressError("body_size", 413);
      }
      parts.push(part.value);
    }
    const data = new Uint8Array(length);
    let offset = 0;
    for (const part of parts) {
      data.set(part, offset);
      offset += part.length;
    }
    return data;
  } finally {
    signal.removeEventListener("abort", cancel);
    cancel();
    try {
      reader.releaseLock();
    } catch { /* Cancelled read unwinding. */ }
  }
}
export function createEmailIngressHandler(
  config: EmailIngressConfig,
  dependencies: EmailIngressDependencies,
) {
  return async (request: Request): Promise<Response> => {
    const deadline = AbortSignal.any([
      request.signal,
      AbortSignal.timeout(15000),
    ]);
    const cancel = () => {
      void request.body?.cancel().catch(() => {});
    };
    try {
      const settings = validateEmailIngressConfig(config);
      if (
        typeof dependencies?.admit !== "function" ||
        typeof dependencies?.deliver !== "function"
      ) {
        throw new EmailIngressError("not_configured", 503);
      }
      if (request.method !== "POST") {
        cancel();
        return response(405, "use_post");
      }
      let headerBytes = 0, headerCount = 0;
      for (const [name, value] of request.headers) {
        if (
          ++headerCount > emailIngressLimits.headerCount ||
          name.length > emailIngressLimits.headerBytes ||
          value.length > emailIngressLimits.headerBytes ||
          (headerBytes += new TextEncoder().encode(name + value).length) >
            emailIngressLimits.headerBytes
        ) {
          throw new EmailIngressError("header_size", 431);
        }
      }
      if (
        request.headers.get("Content-Type")?.toLowerCase() !==
          "application/json"
      ) {
        throw new EmailIngressError("content_type", 415);
      }
      if (
        request.headers.has("Content-Encoding") &&
        request.headers.get("Content-Encoding") !== "identity"
      ) {
        throw new EmailIngressError("content_encoding", 415);
      }
      const admission = async (phase: "before_read" | "verified") => {
        const decision = await until(
          dependencies.admit(
            phase,
            new Headers(request.headers),
            settings.provider,
            deadline,
          ),
          deadline,
        );
        if (!decision || typeof decision.allowed !== "boolean") {
          throw new EmailIngressError("admission", 503);
        }
        if (!decision.allowed) {
          if (
            !Number.isInteger(decision.retryAfter) || decision.retryAfter < 1 ||
            decision.retryAfter > 60
          ) throw new EmailIngressError("admission", 503);
          throw new EmailIngressError("limited", 429);
        }
      };
      await admission("before_read");
      const body = await readBody(
        request,
        AbortSignal.any([deadline, AbortSignal.timeout(2000)]),
      );
      const verified = await verifyEmailEnvelope(
        body,
        request.headers,
        settings,
        dependencies.now?.() ?? Date.now(),
      );
      await admission("verified");
      const args = await until(
        prepareVerifiedEmailDelivery(verified),
        deadline,
      );
      if (deadline.aborted) throw new EmailIngressError("deadline", 503);
      const result = await until(
        dependencies.deliver(args, deadline),
        deadline,
      );
      if (
        deadline.aborted || result?.accepted !== true ||
        typeof result.replayed !== "boolean"
      ) {
        throw new EmailIngressError("uncertain", 503);
      }
      return new Response(
        JSON.stringify({ accepted: true, replayed: result.replayed }),
        {
          headers: {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
          },
        },
      );
    } catch (error) {
      cancel();
      if (error instanceof EmailIngressError) {
        return response(
          error.status,
          error.reason,
          [429, 503].includes(error.status),
        );
      }
      if (error instanceof EmailJournalRefusal) {
        const status = error.code === "PT409"
          ? 409
          : error.code === "PT429"
          ? 429
          : ["42501", "PT404", "22023"].includes(error.code)
          ? 422
          : 503;
        return response(
          status,
          status === 503 ? "uncertain" : "delivery_refused",
          [429, 503].includes(status),
        );
      }
      return response(503, "uncertain", true);
    }
  };
}

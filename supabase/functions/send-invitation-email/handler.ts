import { buildInvitationEmail, clean } from "./content.ts";

type Config = {
  url: string;
  serviceKey: string;
  resendKey: string;
  from: string;
};
type Dependencies = {
  send?: (request: Request) => Promise<Response>;
  now?: () => number;
};
type Invitation = {
  id: string;
  project_id: string;
  invited_by: string;
  invited_email: string | null;
  status: string;
};

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const emailShape = /^[^\s@<>"',;()]{1,64}@[^\s@<>"',;()]{1,255}$/;
const legacyWindowMs = 10 * 60 * 1000;

class Refusal extends Error {
  constructor(
    public status: number,
    message: string,
    public retryAfter?: number,
  ) {
    super(message);
  }
}
const json = (
  body: unknown,
  status = 200,
  headers: Record<string, string> = {},
) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      ...headers,
    },
  });

async function limited(response: Response): Promise<unknown> {
  const reader = response.body?.getReader();
  if (!reader) return null;
  const parts: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      size += item.value.length;
      if (size > 1_000_000) throw new Error("Response limit");
      parts.push(item.value);
    }
  } catch (error) {
    await reader.cancel().catch(() => {});
    throw error;
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  if (!size) return null;
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return null;
  }
}

async function readBody(request: Request): Promise<Record<string, unknown>> {
  const reader = request.body?.getReader();
  let size = 0;
  const parts: Uint8Array[] = [];
  if (reader) {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      size += item.value.length;
      if (size > 4096) {
        await reader.cancel().catch(() => {});
        throw new Refusal(413, "Request is too large.");
      }
      parts.push(item.value);
    }
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  try {
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      throw new Error();
    }
    return body as Record<string, unknown>;
  } catch {
    throw new Refusal(400, "Send a JSON invitation request.");
  }
}

export function createHandler(config: Config, dependencies: Dependencies = {}) {
  const send = dependencies.send ?? fetch, now = dependencies.now ?? Date.now;
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return json({ error: "Use POST." }, 405);
    const token = /^Bearer ([^\s]{1,8192})$/i.exec(
      request.headers.get("Authorization") ?? "",
    )?.[1];
    if (!token) return json({ error: "Sign in to send invitations." }, 401);

    let origin: string;
    try {
      const url = new URL(config.url);
      if (url.protocol !== "https:" || !config.serviceKey) throw new Error();
      origin = url.origin;
    } catch {
      return json(
        { error: "Invitation email is temporarily unavailable." },
        503,
      );
    }

    async function call(
      target: string,
      init: {
        method?: string;
        body?: unknown;
        headers?: Record<string, string>;
      },
    ) {
      const controller = new AbortController(),
        timer = setTimeout(() => controller.abort(), 8_000);
      try {
        const response = await send(
          new Request(target, {
            method: init.method ?? "GET",
            redirect: "error",
            signal: controller.signal,
            headers: {
              "Content-Type": "application/json",
              ...init.headers,
            },
            body: init.body === undefined
              ? undefined
              : JSON.stringify(init.body),
          }),
        );
        return { status: response.status, value: await limited(response) };
      } finally {
        clearTimeout(timer);
      }
    }
    const service = {
      apikey: config.serviceKey,
      Authorization: "Bearer " + config.serviceKey,
    };
    const rest = async (path: string) => {
      const response = await call(origin + "/rest/v1/" + path, {
        headers: service,
      });
      if (response.status !== 200 || !Array.isArray(response.value)) {
        throw new Error("Data service unavailable");
      }
      return response.value as Record<string, unknown>[];
    };
    const rpc = async (name: string, args: Record<string, unknown>) => {
      const response = await call(origin + "/rest/v1/rpc/" + name, {
        method: "POST",
        headers: service,
        body: args,
      });
      if (response.status < 200 || response.status >= 300) {
        throw new Error("Data service unavailable");
      }
      return response.value;
    };

    try {
      // The user's JWT is verified by Auth itself, never trusted locally.
      const authenticated = await call(origin + "/auth/v1/user", {
        headers: {
          apikey: config.serviceKey,
          Authorization: "Bearer " + token,
        },
      });
      if (authenticated.status === 401 || authenticated.status === 403) {
        throw new Refusal(401, "Sign in again to send invitations.");
      }
      if (authenticated.status !== 200) {
        throw new Error("Authentication service unavailable");
      }
      const user = authenticated.value as
        | { id?: string; email?: string }
        | null;
      if (!user?.id || !uuid.test(user.id)) {
        throw new Refusal(401, "Sign in again to send invitations.");
      }
      const userId = user.id.toLowerCase();

      const body = await readBody(request);
      // Only an invitation id or (old builds) the invitee address is read. Every
      // other client-supplied field, such as names, colour and URL, is ignored.
      let invitation: Invitation | undefined;
      if (body.invitationId !== undefined) {
        if (
          typeof body.invitationId !== "string" || !uuid.test(body.invitationId)
        ) {
          throw new Refusal(400, "Invalid invitation.");
        }
        const rows = await rest(
          "project_collaborators?select=id,project_id,invited_by,invited_email,status&id=eq." +
            body.invitationId.toLowerCase(),
        );
        invitation = rows[0] as unknown as Invitation | undefined;
      } else if (typeof body.inviteeEmail === "string") {
        const invitee = body.inviteeEmail.trim().toLowerCase();
        if (!emailShape.test(invitee)) {
          throw new Refusal(400, "Invalid invitation.");
        }
        const since = new Date(now() - legacyWindowMs).toISOString();
        const rows = await rest(
          "project_collaborators?select=id,project_id,invited_by,invited_email,status" +
            "&invited_by=eq." + userId + "&status=eq.pending" +
            "&invited_email=eq." + encodeURIComponent(invitee) +
            "&created_at=gte." + encodeURIComponent(since) +
            "&order=created_at.desc&limit=1",
        );
        invitation = rows[0] as unknown as Invitation | undefined;
      } else {
        throw new Refusal(400, "Invalid invitation.");
      }
      // Someone else's invitation is indistinguishable from a missing one.
      if (!invitation || invitation.invited_by !== userId) {
        throw new Refusal(404, "Invitation not found.");
      }
      if (invitation.status !== "pending") {
        throw new Refusal(409, "This invitation is no longer pending.");
      }
      const invitee = typeof invitation.invited_email === "string"
        ? invitation.invited_email.trim().toLowerCase()
        : "";
      if (!emailShape.test(invitee)) {
        throw new Refusal(422, "This invitation has no email address.");
      }

      const projects = await rest(
        "projects?select=name,color,user_id&id=eq." + invitation.project_id,
      );
      const project = projects[0] as {
        name?: string;
        color?: string;
        user_id?: string;
      } | undefined;
      if (!project) throw new Refusal(404, "Invitation not found.");
      if (project.user_id !== userId) {
        throw new Refusal(403, "Only the project owner can send invitations.");
      }

      if (!config.resendKey || !config.from || /[\r\n]/.test(config.from)) {
        throw new Refusal(503, "Invitation email is temporarily unavailable.");
      }

      const profiles = await rest(
        "profiles?select=display_name&user_id=eq." + userId,
      );
      const display = clean(
        (profiles[0] as { display_name?: string } | undefined)?.display_name,
        80,
      );
      const local = clean(
        typeof user.email === "string" ? user.email.split("@")[0] : "",
        80,
      );
      const inviterName = display || local || "A Taskfold user";

      const claim = await rpc("taskfold_claim_invitation_email", {
        _invitation: invitation.id,
        _user: userId,
      }) as { status?: string; claim?: number } | null;
      if (claim?.status === "recent") {
        return json({ ok: true, status: "already_sent" });
      }
      if (claim?.status === "rate_limited") {
        return json(
          { error: "Too many invitation emails. Try again later." },
          429,
          { "Retry-After": "3600" },
        );
      }
      if (claim?.status !== "claimed" || typeof claim.claim !== "number") {
        throw new Error("Unexpected claim response");
      }

      const email = buildInvitationEmail({
        inviterName,
        projectName: project.name ?? "",
        projectColor: project.color,
      });
      let delivered = false;
      try {
        const sent = await call("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            Authorization: "Bearer " + config.resendKey,
            "Idempotency-Key": "taskfold-invitation-" + invitation.id + "-" +
              claim.claim,
          },
          body: {
            from: config.from,
            to: [invitee],
            subject: email.subject,
            html: email.html,
            text: email.text,
          },
        });
        delivered = sent.status >= 200 && sent.status < 300;
      } catch {
        delivered = false;
      }
      if (!delivered) {
        // Give the claim back so the owner can retry; the log holds no content.
        await rpc("taskfold_release_invitation_email", { _claim: claim.claim })
          .catch(() => {});
        console.error(
          "send-invitation-email: provider did not accept the message",
        );
        throw new Refusal(502, "The invitation email could not be sent.");
      }
      return json({ ok: true, status: "sent" });
    } catch (error) {
      if (error instanceof Refusal) {
        return json(
          { error: error.message },
          error.status,
          error.retryAfter ? { "Retry-After": String(error.retryAfter) } : {},
        );
      }
      console.error("send-invitation-email: unavailable");
      return json(
        { error: "Invitation email is temporarily unavailable." },
        503,
      );
    }
  };
}

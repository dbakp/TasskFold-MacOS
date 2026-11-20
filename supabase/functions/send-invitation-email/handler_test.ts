import { createHandler } from "./handler.ts";
import { buildInvitationEmail, escapeHtml } from "./content.ts";

const owner = "b0b0cafe-0000-4000-8000-000000000001",
  other = "b0b0cafe-0000-4000-8000-000000000002",
  invitationId = "b0b0cafe-0000-4000-8000-0000000000a1",
  projectId = "b0b0cafe-0000-4000-8000-0000000000b1";
const config = {
  url: "https://invite.test",
  serviceKey: "service-fixture",
  resendKey: "resend-fixture",
  from: "Taskfold <invites@mail.example.test>",
};
const assert = (value: unknown, message: string) => {
  if (!value) throw new Error(message);
};
const reply = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), { status });

type Options = {
  auth?: number;
  authUser?: { id: string; email?: string };
  invitation?: Record<string, unknown> | null;
  legacyRows?: Record<string, unknown>[];
  projectOwner?: string;
  projectName?: string;
  displayName?: string | null;
  claim?: Record<string, unknown>;
  resend?: number;
  resendThrows?: boolean;
};
function fixture(options: Options = {}) {
  const calls: {
    url: string;
    method: string;
    body: unknown;
    headers: Headers;
  }[] = [];
  const invitation = options.invitation === undefined
    ? {
      id: invitationId,
      project_id: projectId,
      invited_by: owner,
      invited_email: "friend@example.test",
      status: "pending",
    }
    : options.invitation;
  const send = async (request: Request) => {
    const url = new URL(request.url);
    const text = request.body ? await request.text() : "";
    calls.push({
      url: request.url,
      method: request.method,
      body: text ? JSON.parse(text) : undefined,
      headers: request.headers,
    });
    if (url.pathname === "/auth/v1/user") {
      return options.auth && options.auth !== 200
        ? reply({}, options.auth)
        : reply(
          options.authUser ?? { id: owner, email: "casey.owner@example.test" },
        );
    }
    if (url.pathname === "/rest/v1/project_collaborators") {
      if (url.searchParams.has("invited_by")) {
        return reply(options.legacyRows ?? []);
      }
      return reply(invitation ? [invitation] : []);
    }
    if (url.pathname === "/rest/v1/projects") {
      return reply([{
        name: options.projectName ?? "Launch",
        color: "#ff0000",
        user_id: options.projectOwner ?? owner,
      }]);
    }
    if (url.pathname === "/rest/v1/profiles") {
      return reply(
        options.displayName === null
          ? []
          : [{ display_name: options.displayName ?? "Casey" }],
      );
    }
    if (url.pathname === "/rest/v1/rpc/taskfold_claim_invitation_email") {
      return reply(options.claim ?? { status: "claimed", claim: 7 });
    }
    if (url.pathname === "/rest/v1/rpc/taskfold_release_invitation_email") {
      return reply(null, 204);
    }
    if (url.hostname === "api.resend.com") {
      if (options.resendThrows) throw new Error("network");
      return reply({ id: "x" }, options.resend ?? 200);
    }
    return reply({}, 500);
  };
  const handler = (overrides: Partial<typeof config> = {}) =>
    createHandler({ ...config, ...overrides }, {
      send,
      now: () => Date.parse("2026-11-20T12:00:00Z"),
    });
  return { calls, handler };
}
const post = (
  body: unknown,
  token: string | null = "user.jwt.value",
  method = "POST",
) =>
  new Request("https://edge.test", {
    method,
    headers: token ? { Authorization: "Bearer " + token } : {},
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
const sentEmails = (calls: ReturnType<typeof fixture>["calls"]) =>
  calls.filter((c) => new URL(c.url).hostname === "api.resend.com");

Deno.test("method and bearer token are required", async () => {
  const f = fixture();
  assert(
    (await f.handler()(post({}, "t", "GET"))).status === 405,
    "GET refused",
  );
  assert(
    (await f.handler()(post({ invitationId }, null))).status === 401,
    "no token",
  );
  assert(f.calls.length === 0, "nothing contacted without a token");
});

Deno.test("an invalid session is refused before any lookup or send", async () => {
  const f = fixture({ auth: 401 });
  const res = await f.handler()(post({ invitationId }));
  assert(res.status === 401, "401");
  assert(
    f.calls.length === 1 && sentEmails(f.calls).length === 0,
    "only the auth call happened",
  );
});

Deno.test("happy path sends one email derived only from server data", async () => {
  const f = fixture({ projectName: "Quarterly plan", displayName: "Casey" });
  const res = await f.handler()(post({
    invitationId,
    inviteeEmail: "victim@example.test",
    projectName: "Spoofed",
    inviterName: "Bank Support",
    projectColor: "red",
    appUrl: "https://evil.test",
  }));
  assert(res.status === 200 && (await res.json()).status === "sent", "sent");
  const mail = sentEmails(f.calls);
  assert(mail.length === 1, "one email");
  const body = mail[0].body as {
    from: string;
    to: string[];
    subject: string;
    html: string;
    text: string;
  };
  assert(body.from === config.from, "fixed from");
  assert(
    body.to.length === 1 && body.to[0] === "friend@example.test",
    "address from the invitation row",
  );
  const all = JSON.stringify(body);
  for (const forbidden of ["victim@", "Spoofed", "Bank Support", "evil.test"]) {
    assert(!all.includes(forbidden), "client value leaked: " + forbidden);
  }
  assert(
    body.subject.includes("Casey") && body.subject.includes("Quarterly plan"),
    "server names",
  );
  assert(
    mail[0].headers.get("Authorization") === "Bearer resend-fixture",
    "provider key",
  );
  assert(
    mail[0].headers.get("Idempotency-Key")?.includes(invitationId),
    "provider idempotency key",
  );
});

Deno.test("inviter name falls back to the email local part", async () => {
  const f = fixture({ displayName: null });
  await f.handler()(post({ invitationId }));
  const subject = (sentEmails(f.calls)[0].body as { subject: string }).subject;
  assert(
    subject.startsWith("casey.owner invited you"),
    "local part used: " + subject,
  );
});

Deno.test("another user's invitation is a 404 and sends nothing", async () => {
  const f = fixture({ authUser: { id: other, email: "x@example.test" } });
  const res = await f.handler()(post({ invitationId }));
  assert(res.status === 404, "404");
  assert(sentEmails(f.calls).length === 0, "no email");
  assert(!f.calls.some((c) => c.url.includes("rpc/")), "no claim");
});

Deno.test("an inviter who is not the project owner is refused", async () => {
  const f = fixture({ projectOwner: other });
  const res = await f.handler()(post({ invitationId }));
  assert(res.status === 403, "403");
  assert(sentEmails(f.calls).length === 0, "no email");
});

Deno.test("only pending invitations are emailed", async () => {
  for (const status of ["accepted", "declined"]) {
    const f = fixture({
      invitation: {
        id: invitationId,
        project_id: projectId,
        invited_by: owner,
        invited_email: "f@example.test",
        status,
      },
    });
    const res = await f.handler()(post({ invitationId }));
    assert(res.status === 409, status + " refused");
    assert(sentEmails(f.calls).length === 0, "no email for " + status);
  }
});

Deno.test("missing invitation and malformed ids", async () => {
  assert(
    (await fixture({ invitation: null }).handler()(post({ invitationId })))
      .status === 404,
    "unknown id",
  );
  assert(
    (await fixture().handler()(post({ invitationId: "nope" }))).status === 400,
    "bad id",
  );
  assert((await fixture().handler()(post({}))).status === 400, "empty body");
  assert(
    (await fixture().handler()(post({ inviteeEmail: "not an email" })))
      .status === 400,
    "bad email",
  );
});

Deno.test("legacy body maps to the caller's recent pending invitation", async () => {
  const f = fixture({
    legacyRows: [{
      id: invitationId,
      project_id: projectId,
      invited_by: owner,
      invited_email: "friend@example.test",
      status: "pending",
    }],
  });
  const res = await f.handler()(post({
    inviteeEmail: " Friend@Example.test ",
    projectName: "Spoofed",
    inviterName: "Bank Support",
    inviterEmail: "ceo@example.test",
    appUrl: "https://evil.test",
  }));
  assert(res.status === 200, "sent");
  const query = f.calls.find((c) => c.url.includes("invited_by="))!;
  const url = new URL(query.url);
  assert(
    url.searchParams.get("invited_by") === "eq." + owner,
    "scoped to caller",
  );
  assert(url.searchParams.get("status") === "eq.pending", "pending only");
  assert(
    url.searchParams.get("invited_email") === "eq.friend@example.test",
    "normalised address",
  );
  assert(
    url.searchParams.get("created_at") === "gte.2026-11-20T11:50:00.000Z",
    "10 minute window",
  );
  assert(
    !JSON.stringify(sentEmails(f.calls)[0].body).includes("Spoofed"),
    "client text ignored",
  );
});

Deno.test("legacy body with no recent pending invitation is a 404", async () => {
  const f = fixture({ legacyRows: [] });
  const res = await f.handler()(post({ inviteeEmail: "friend@example.test" }));
  assert(res.status === 404, "404");
  assert(sentEmails(f.calls).length === 0, "no email");
});

Deno.test("a repeat within the idempotency window sends nothing", async () => {
  const f = fixture({ claim: { status: "recent" } });
  const res = await f.handler()(post({ invitationId }));
  const body = await res.json();
  assert(
    res.status === 200 && body.status === "already_sent",
    "reported as already sent",
  );
  assert(sentEmails(f.calls).length === 0, "no second email");
});

Deno.test("the per-user hourly limit returns 429 and sends nothing", async () => {
  const f = fixture({ claim: { status: "rate_limited" } });
  const res = await f.handler()(post({ invitationId }));
  assert(
    res.status === 429 && res.headers.get("Retry-After") === "3600",
    "429 with Retry-After",
  );
  assert(sentEmails(f.calls).length === 0, "no email");
});

Deno.test("a provider failure releases the claim and reports 502", async () => {
  for (const options of [{ resend: 500 }, { resendThrows: true }]) {
    const f = fixture(options);
    const res = await f.handler()(post({ invitationId }));
    assert(res.status === 502, "502");
    const release = f.calls.find((c) =>
      c.url.includes("taskfold_release_invitation_email")
    );
    assert(
      release && (release.body as { _claim: number })._claim === 7,
      "claim released",
    );
  }
});

Deno.test("missing sender or provider key fails closed with 503", async () => {
  for (
    const override of [{ from: "" }, { resendKey: "" }, {
      from: "a@b.test\r\nBcc: x@y.test",
    }]
  ) {
    const f = fixture();
    const res = await f.handler(override)(post({ invitationId }));
    assert(res.status === 503, "503");
    assert(
      sentEmails(f.calls).length === 0 &&
        !f.calls.some((c) => c.url.includes("rpc/")),
      "nothing claimed or sent",
    );
  }
  assert(
    (await fixture().handler({ url: "http://insecure.test" })(
      post({ invitationId }),
    )).status === 503,
    "https required",
  );
});

Deno.test("names are escaped in html and text, and cannot add lines", () => {
  const hostile = `<script>alert(1)</script>"'&\r\nBcc: x@y.test`;
  const mail = buildInvitationEmail({
    inviterName: hostile,
    projectName: hostile,
    projectColor: `red;"><b>`,
  });
  for (const part of [mail.html, mail.text]) {
    assert(!part.includes("<script>"), "script tag escaped");
    assert(part.includes("&lt;script&gt;"), "escaped form present");
  }
  assert(
    !mail.html.includes('"><b>') && mail.html.includes("#3b82f6"),
    "invalid colour replaced",
  );
  assert(!/[\r\n]/.test(mail.subject), "subject is one line");
  assert(escapeHtml(`&<>"'`) === "&amp;&lt;&gt;&quot;&#39;", "escape table");
});

Deno.test("logs never contain addresses or content", async () => {
  const lines: string[] = [], original = console.error;
  console.error = (...args: unknown[]) => lines.push(args.join(" "));
  try {
    await fixture({ resend: 500 }).handler()(post({ invitationId }));
  } finally {
    console.error = original;
  }
  assert(lines.length > 0, "failure is logged");
  assert(
    !lines.join(" ").match(/example\.test|Casey|Launch|fixture/),
    "no private values logged",
  );
});

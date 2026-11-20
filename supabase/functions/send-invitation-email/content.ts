// Email content is built only from values the server read itself. Every
// interpolated value is HTML-escaped (in the plain-text part too) and stripped of
// control characters, so no name can inject markup, headers or extra lines.
export const OPEN_URL = "taskfold://invitations";
const defaultColor = "#3b82f6";

export const escapeHtml = (value: string) =>
  value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");

// Single line, no control or bidi-override characters, bounded length.
export function clean(value: unknown, max: number): string {
  const text = typeof value === "string" ? value : "";
  // deno-lint-ignore no-control-regex
  const stripped = text.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩﻿]/g, " ")
    .replace(/\s+/g, " ").trim();
  return [...stripped].slice(0, max).join("");
}

export function accent(color: unknown): string {
  return typeof color === "string" && /^#[0-9a-fA-F]{6}$/.test(color)
    ? color
    : defaultColor;
}

export type InvitationEmailInput = {
  inviterName: string;
  projectName: string;
  projectColor: unknown;
};

export function buildInvitationEmail(input: InvitationEmailInput) {
  const inviter = clean(input.inviterName, 80) || "A Taskfold user";
  const project = clean(input.projectName, 120) || "a project";
  const color = accent(input.projectColor);
  // A header is not HTML: it is single-line (clean) and left unescaped so a name
  // like "A & B" reads correctly in the inbox list.
  const subject = `${inviter} invited you to ${project} on Taskfold`;
  const who = escapeHtml(inviter), what = escapeHtml(project);
  const html = `<!doctype html>
<html><body style="margin:0;padding:24px;background:#f6f5f2;font-family:-apple-system,Helvetica,Arial,sans-serif;color:#1c1c1e">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center">
<table role="presentation" width="480" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:12px;padding:28px">
<tr><td>
<p style="margin:0 0 16px;font-size:15px;color:#6b6b70">Taskfold</p>
<h1 style="margin:0 0 16px;font-size:20px;line-height:1.3"><span style="display:inline-block;width:12px;height:12px;border-radius:6px;background:${
    escapeHtml(color)
  };margin-right:8px"></span>${what}</h1>
<p style="margin:0 0 20px;font-size:16px;line-height:1.5"><strong>${who}</strong> invited you to collaborate on this project in Taskfold.</p>
<p style="margin:0 0 24px"><a href="${OPEN_URL}" style="background:#1c1c1e;color:#ffffff;text-decoration:none;padding:12px 20px;border-radius:8px;font-size:15px;display:inline-block">Open invitation</a></p>
<p style="margin:0;font-size:13px;line-height:1.5;color:#6b6b70">Open Taskfold and sign in with this email address, then choose Invitations to accept. If you were not expecting this, you can ignore this email.</p>
</td></tr></table></td></tr></table></body></html>`;
  const text = `${who} invited you to collaborate on "${what}" in Taskfold.

Open Taskfold and sign in with this email address, then choose Invitations to accept: ${OPEN_URL}

If you were not expecting this, you can ignore this email.
`;
  return { subject, html, text };
}

// Internal contract for a future verified inbound-provider adapter. Not an endpoint.
// Authentication, sender verification, recipient authorization and admission must
// happen before this content is committed. Header Message-ID is never a receipt ID.
export const emailContentLimits = Object.freeze({
  subjectBytes: 512,
  textBytes: 60_000,
  attachments: 100,
});
export class EmailContentError extends Error {
  constructor(
    readonly reason:
      | "invalid_content"
      | "unsupported_version"
      | "content_too_large"
      | "empty_content"
      | "invalid_delivery",
  ) {
    super("Email could not be prepared: " + reason);
    this.name = "EmailContentError";
  }
}
function object(
  value: unknown,
  fields: readonly string[],
): Record<string, unknown> {
  if (
    !value || typeof value !== "object" || Array.isArray(value) ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value))
  ) {
    throw new EmailContentError("invalid_content");
  }
  const row = value as Record<string, unknown>;
  if (
    Object.keys(row).length !== fields.length ||
    fields.some((k) => !Object.hasOwn(row, k))
  ) {
    throw new EmailContentError("invalid_content");
  }
  return row;
}
function bounded(value: unknown, bytes: number): string {
  if (typeof value !== "string") throw new EmailContentError("invalid_content");
  // Reject before encoding a very large string. Do not silently truncate a note.
  if (value.length > bytes || new TextEncoder().encode(value).length > bytes) {
    throw new EmailContentError("content_too_large");
  }
  // Unpaired surrogates would be replaced during UTF-8 encoding/JSON transfer.
  if (!value.isWellFormed()) throw new EmailContentError("invalid_content");
  return value;
}
function containsControls(value: string, body: boolean): boolean {
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code === 127 || (code < 32 && !(body && [9, 10, 13].includes(code)))) {
      return true;
    }
  }
  return false;
}
export function normalizeEmailContent(input: unknown) {
  const row = object(input, ["version", "subject", "text", "attachmentCount"]);
  if (row.version !== 1) throw new EmailContentError("unsupported_version");
  const subject = bounded(row.subject, emailContentLimits.subjectBytes);
  const text = bounded(row.text, emailContentLimits.textBytes);
  if (
    containsControls(subject, false) ||
    containsControls(text, true) ||
    !Number.isInteger(row.attachmentCount) ||
    (row.attachmentCount as number) < 0 ||
    (row.attachmentCount as number) > emailContentLimits.attachments
  ) {
    throw new EmailContentError("invalid_content");
  }
  const attachmentCount = row.attachmentCount as number;
  if (!subject.trim() && !text.trim()) {
    throw new EmailContentError("empty_content");
  }
  const body = text.replace(/\r\n?/g, "\n");
  const omitted = attachmentCount === 1
    ? "1 attachment was not imported."
    : attachmentCount + " attachments were not imported.";
  return Object.freeze({
    title: subject.trim() || "Email task",
    description: body + (attachmentCount ? (body ? "\n\n" : "") + omitted : ""),
    attachmentCount,
  });
}
async function digest(parts: unknown[]): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(parts));
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(
    new Uint8Array(hash),
    (n) => n.toString(16).padStart(2, "0"),
  ).join("");
}
export async function prepareEmailDelivery(identity: unknown, input: unknown) {
  const row = object(identity, ["provider", "deliveryID", "routeID"]);
  if (
    typeof row.provider !== "string" ||
    !/^[a-z0-9][a-z0-9_-]{0,47}$/.test(row.provider) ||
    typeof row.deliveryID !== "string" ||
    !/^[!-~]{1,256}$/.test(row.deliveryID) ||
    typeof row.routeID !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
      row.routeID,
    )
  ) {
    throw new EmailContentError("invalid_delivery");
  }
  const content = normalizeEmailContent(input);
  // Provider identity must come from a verified adapter event, never email headers.
  // Keep identity separate from content: changed-body replays must conflict in the
  // future atomic journal, rather than minting another task ID or overwriting work.
  const deliveryKey = await digest([
    "taskfold-email-delivery",
    1,
    row.provider,
    row.deliveryID,
    row.routeID,
  ]);
  const contentFingerprint = await digest([
    "taskfold-email-content",
    1,
    content.title,
    content.description,
    content.attachmentCount,
  ]);
  return Object.freeze({ content, deliveryKey, contentFingerprint });
}

// Internal decoding only. A provider adapter must authenticate the original
// event/envelope and perform admission BEFORE passing bounded raw bytes here.
// Exact inline pins let future function entrypoints import this shared module
// without depending on an unrelated function's import map.
// deno-lint-ignore no-import-prefix
import PostalMime from "npm:postal-mime@4.1.4";
// deno-lint-ignore no-import-prefix
import { convert } from "npm:html-to-text@10.0.1";
import {
  normalizeEmailContent,
  prepareEmailDelivery,
} from "../email-content.ts";

export const emailMimeLimits = Object.freeze({
  rawBytes: 1_048_576,
  headerBytes: 32_768,
  parts: 128,
  depth: 16,
  htmlBytes: 200_000,
  htmlDepth: 64,
  htmlChildren: 5_000,
});
export class EmailMimeError extends Error {
  constructor(
    readonly reason:
      | "invalid_message"
      | "message_too_large"
      | "structure_too_large"
      | "unsupported_message",
  ) {
    // Never propagate parser messages, raw headers, private aliases or contents.
    super("Email could not be decoded: " + reason);
    this.name = "EmailMimeError";
  }
}

export async function decodeEmailMessage(raw: unknown) {
  // Raw strings are ambiguous (UTF-8 vs. binary strings); require provider bytes.
  if (!(raw instanceof Uint8Array) || raw.byteLength === 0) {
    throw new EmailMimeError("invalid_message");
  }
  if (raw.byteLength > emailMimeLimits.rawBytes) {
    throw new EmailMimeError("message_too_large");
  }
  let email;
  try {
    email = await PostalMime.parse(raw, {
      maxHeadersSize: emailMimeLimits.headerBytes,
      maxPartCount: emailMimeLimits.parts,
      maxNestingDepth: emailMimeLimits.depth,
      // A forwarded .eml is an omitted attachment, never a second sender, receipt
      // or unbounded recursive text expansion. Inline images are omitted too.
      forceRfc822Attachments: true,
      maxRfc822NestingDepth: 0,
      maxForwardedAddresses: 0,
    });
  } catch (error) {
    const code = error && typeof error === "object" && "code" in error
      ? error.code
      : undefined;
    throw new EmailMimeError(
      typeof code === "string" && code.startsWith("EMAX")
        ? "structure_too_large"
        : "invalid_message",
    );
  }
  // Do not pretend an encrypted body has been imported as a subject-only task.
  const types = email.headers.filter((h) => h.key === "content-type");
  if (types.length > 1) throw new EmailMimeError("invalid_message");
  const type = types[0]?.value.split(";")[0].trim().toLowerCase();
  if (
    type === "multipart/encrypted" || type === "application/pkcs7-mime" ||
    type === "application/x-pkcs7-mime"
  ) throw new EmailMimeError("unsupported_message");
  // A plain alternative has precedence, even if its whitespace is intentional.
  // HTML conversion is explicit: the MIME parser does not synthesize plain text.
  // Conversion never loads a browser, remote resources or attachment contents.
  let text = email.text ?? "";
  if (!text && email.html) {
    if (
      new TextEncoder().encode(email.html).length > emailMimeLimits.htmlBytes
    ) {
      throw new EmailMimeError("message_too_large");
    }
    const omission = "\u0000taskfold-html-limit\u0000";
    try {
      text = convert(email.html, {
        wordwrap: false,
        baseElements: { selectors: [], returnDomByDefault: true },
        limits: {
          maxInputLength: emailMimeLimits.htmlBytes,
          maxDepth: emailMimeLimits.htmlDepth,
          maxChildNodes: emailMimeLimits.htmlChildren,
          ellipsis: omission,
        },
        selectors: [
          ...[
            "head",
            "script",
            "style",
            "img",
            "svg",
            "canvas",
            "iframe",
            "object",
            "template",
            "noscript",
          ].map((selector) => ({ selector, format: "skip" })),
          { selector: "a", options: { ignoreHref: true } },
          ...["h1", "h2", "h3", "h4", "h5", "h6"].map((selector) => ({
            selector,
            options: { uppercase: false },
          })),
        ],
      });
    } catch {
      throw new EmailMimeError("invalid_message");
    }
    if (typeof text !== "string") throw new EmailMimeError("invalid_message");
    if (text.includes(omission)) {
      throw new EmailMimeError("structure_too_large");
    }
  }
  if (email.html && !text.trim()) {
    throw new EmailMimeError("unsupported_message");
  }
  const input = Object.freeze({
    version: 1,
    subject: email.subject ?? "",
    text,
    attachmentCount: email.attachments.length,
  });
  // Reuse the exact existing decoded-content limits and control validation.
  // Overlong decoded data is refused, never silently truncated.
  normalizeEmailContent(input);
  return input;
}

export async function prepareMimeEmailDelivery(
  identity: unknown,
  raw: unknown,
) {
  // identity is supplied by a VERIFIED provider adapter. Message-ID, Date,
  // From, To, Authentication-Results and any senderVerified header are ignored.
  return await prepareEmailDelivery(identity, await decodeEmailMessage(raw));
}

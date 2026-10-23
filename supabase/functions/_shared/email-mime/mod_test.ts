import {
  decodeEmailMessage,
  EmailMimeError,
  emailMimeLimits,
  prepareMimeEmailDelivery,
} from "./mod.ts";
import { EmailContentError, normalizeEmailContent } from "../email-content.ts";

function equal(a: unknown, b: unknown) {
  if (JSON.stringify(a) !== JSON.stringify(b)) {
    throw Error("Decoded fixture values differ");
  }
}
async function fails(work: () => Promise<unknown>, reason: string) {
  try {
    await work();
  } catch (error) {
    if (
      (error instanceof EmailMimeError || error instanceof EmailContentError) &&
      error.reason === reason
    ) return;
    throw error;
  }
  throw Error("Expected " + reason);
}
const bytes = (s: string) => new TextEncoder().encode(s);
const message = (body = "Review the draft", headers = "") =>
  bytes("Subject: Design review\r\n" + headers + "\r\n" + body);
const identity = {
  provider: "synthetic-verified-adapter",
  routeID: "f091cafe-0000-4000-8000-000000000001",
  deliveryID: "original-provider-receipt-1",
};
const multipart = (parts: string[], kind = "mixed") =>
  message(
    parts.map((p) => "--taskfold-boundary\r\n" + p + "\r\n").join("") +
      "--taskfold-boundary--\r\n",
    `MIME-Version: 1.0\r\nContent-Type: multipart/${kind}; boundary="taskfold-boundary"\r\n`,
  );

Deno.test("MIME decodes folded RFC2047 subject and quoted-printable UTF-8 text", async () => {
  const decoded = await decodeEmailMessage(bytes(
    "Subject: =?UTF-8?Q?R=C3=A9vision?=\r\n =?UTF-8?B?IPCfk50=?=\r\n" +
      "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n" +
      "Content-Transfer-Encoding: quoted-printable\r\n\r\n" +
      "  Keep indentation\r\n=C3=A9tape =F0=9F=93=9D\r\n",
  ));
  equal(decoded.subject, "Révision 📝");
  equal(
    normalizeEmailContent(decoded).description,
    "  Keep indentation\nétape 📝\n",
  );
  equal(Object.isFrozen(decoded), true);
});

Deno.test("MIME decodes base64 and legacy character sets without losing the note", async () => {
  const decoded = await decodeEmailMessage(message(
    "Q2Fm6SBzdXIgbGUgcG9ydA==",
    "Content-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: base64\r\n",
  ));
  equal(decoded.text, "Café sur le port");
});

Deno.test("MIME keeps plain alternative instead of executing or importing HTML", async () => {
  const decoded = await decodeEmailMessage(multipart([
    "Content-Type: text/plain; charset=utf-8\r\n\r\n  Actual plain note",
    "Content-Type: text/html\r\n\r\n<script>bad()</script><b>Different HTML</b>",
  ], "alternative"));
  equal(decoded.text, "  Actual plain note");
  equal(decoded.attachmentCount, 0);
});

Deno.test("MIME converts HTML-only mail to readable text without remote resources", async () => {
  const decoded = await decodeEmailMessage(message(
    "<html><head><style>secretCSS</style></head><body><p>Review &amp; approve</p>" +
      '<script>secretScript()</script><img src="https://tracking.example.invalid/pixel">' +
      "<p>Second line</p></body></html>",
    "Content-Type: text/html; charset=utf-8\r\n",
  ));
  equal(decoded.text.includes("Review & approve"), true);
  equal(decoded.text.includes("Second line"), true);
  for (
    const secret of ["secretCSS", "secretScript", "tracking.example", "<p>"]
  ) {
    equal(decoded.text.includes(secret), false);
  }
  equal(Object.keys(decoded).sort(), [
    "attachmentCount",
    "subject",
    "text",
    "version",
  ]);
});

Deno.test("MIME image-only HTML fails rather than making a misleading subject-only task", async () => {
  await fails(() =>
    decodeEmailMessage(message(
      '<img src="https://tracking.example.invalid/pixel">',
      "Content-Type: text/html\r\n",
    )), "unsupported_message");
});

Deno.test("MIME HTML bounds refuse rather than silently clipping large or deeply nested notes", async () => {
  const html = (body: string) => message(body, "Content-Type: text/html\r\n");
  await fails(
    () => decodeEmailMessage(html("x".repeat(emailMimeLimits.htmlBytes + 1))),
    "message_too_large",
  );
  await fails(
    () =>
      decodeEmailMessage(
        html("<div>".repeat(80) + "important note" + "</div>".repeat(80)),
      ),
    "structure_too_large",
  );
  await fails(
    () => decodeEmailMessage(html("<span>important note</span>".repeat(5_001))),
    "structure_too_large",
  );
  await fails(
    () => decodeEmailMessage(html("x".repeat(60_001))),
    "content_too_large",
  );
});

Deno.test("MIME HTML preserves readable link labels without promoting embedded capabilities", async () => {
  const decoded = await decodeEmailMessage(message(
    '<h1>Plan for Tuesday</h1><p><a href="javascript:secret()">Review the plan</a></p>' +
      '<p><a href="https://private-alias.example.invalid/secret">Reference</a></p>' +
      "<iframe>hidden frame</iframe><object>hidden object</object><template>hidden template</template>",
    "Content-Type: text/html\r\n",
  ));
  for (const label of ["Plan for Tuesday", "Review the plan", "Reference"]) {
    equal(decoded.text.includes(label), true);
  }
  for (
    const label of [
      "javascript:",
      "private-alias",
      "hidden frame",
      "hidden object",
      "hidden template",
    ]
  ) equal(decoded.text.includes(label), false);
});

Deno.test("MIME failures expose only stable reasons, without raw message details", async () => {
  try {
    await decodeEmailMessage(
      message(
        "body",
        "X-Private-Alias: PRIVATE-SENTINEL" + "x".repeat(33_000) + "\r\n",
      ),
    );
  } catch (error) {
    equal(error instanceof EmailMimeError, true);
    equal(
      (error as Error).message,
      "Email could not be decoded: structure_too_large",
    );
    equal(String(error).includes("PRIVATE-SENTINEL"), false);
    return;
  }
  throw Error("Expected bounded error");
});

Deno.test("MIME attachments including inline images and forwarded mail are counted but omitted", async () => {
  const decoded = await decodeEmailMessage(multipart([
    "Content-Type: text/plain\r\n\r\nRead this note",
    'Content-Type: image/png\r\nContent-Disposition: inline; filename="preview.png"\r\nContent-Transfer-Encoding: base64\r\n\r\naGVsbG8=',
    'Content-Type: application/pdf\r\nContent-Disposition: attachment; filename="private.pdf"\r\n\r\nprivate-file-bytes',
    "Content-Type: message/rfc822\r\n\r\nFrom: impostor@example.invalid\r\nSubject: Forwarded\r\n\r\nforwarded-private-text",
  ]));
  equal(decoded.attachmentCount, 3);
  equal(
    normalizeEmailContent(decoded).description,
    "Read this note\n\n3 attachments were not imported.",
  );
  for (
    const secret of [
      "private-file-bytes",
      "impostor@",
      "forwarded-private-text",
    ]
  ) {
    equal(JSON.stringify(decoded).includes(secret), false);
  }
});

Deno.test("MIME raw input is unambiguous, nonempty and bounded before parsing", async () => {
  for (
    const value of [
      null,
      "Subject: mail",
      {},
      new ArrayBuffer(8),
      new Uint8Array(),
    ]
  ) {
    await fails(() => decodeEmailMessage(value), "invalid_message");
  }
  await fails(
    () => decodeEmailMessage(new Uint8Array(emailMimeLimits.rawBytes + 1)),
    "message_too_large",
  );
  const backing = new Uint8Array(emailMimeLimits.rawBytes + 100);
  const valid = message();
  backing.set(valid, 20);
  equal(
    (await decodeEmailMessage(backing.subarray(20, 20 + valid.length))).subject,
    "Design review",
  );
});

Deno.test("MIME exact decoded limits accept and extra bytes refuse rather than truncate", async () => {
  const body = "é".repeat(29_999) + "x";
  equal((await decodeEmailMessage(message(body))).text, body + "\n");
  await fails(
    () => decodeEmailMessage(message(body + "a")),
    "content_too_large",
  );
  const subject = "é".repeat(256);
  equal(
    (await decodeEmailMessage(bytes("Subject: " + subject + "\r\n\r\nx")))
      .subject,
    subject,
  );
  await fails(
    () => decodeEmailMessage(bytes("Subject: " + subject + "a\r\n\r\nx")),
    "content_too_large",
  );
});

Deno.test("MIME structural limits refuse aggregate headers, excessive width and depth", async () => {
  await fails(
    () =>
      decodeEmailMessage(
        message("x", "X-Large: " + "a".repeat(32_768) + "\r\n"),
      ),
    "structure_too_large",
  );
  await fails(
    () =>
      decodeEmailMessage(
        multipart(
          Array.from(
            { length: 128 },
            () => "Content-Type: text/plain\r\n\r\nx",
          ),
        ),
      ),
    "structure_too_large",
  );
  let nested = "Content-Type: text/plain\r\n\r\nx";
  for (let n = 0; n < 18; n++) {
    nested =
      `Content-Type: multipart/mixed; boundary="b${n}"\r\n\r\n--b${n}\r\n${nested}\r\n--b${n}--`;
  }
  await fails(
    () => decodeEmailMessage(bytes("Subject: Deep\r\n" + nested)),
    "structure_too_large",
  );
});

Deno.test("MIME decoded controls, empty mail and overlong attachment lists fail", async () => {
  await fails(
    () => decodeEmailMessage(message("secret\u0000")),
    "invalid_content",
  );
  equal(
    (await decodeEmailMessage(
      bytes("Subject: =?UTF-8?Q?hello=0D=0Aworld?=\r\n\r\nx"),
    )).subject,
    "hello world",
  );
  await fails(
    () => decodeEmailMessage(bytes("Subject: \r\n\r\n   ")),
    "empty_content",
  );
  await fails(
    () =>
      decodeEmailMessage(
        multipart(Array.from({ length: 101 }, () =>
          "Content-Type: application/pdf\r\nContent-Disposition: attachment\r\n\r\nx")),
      ),
    "invalid_content",
  );
});

Deno.test("MIME encrypted bodies are explicitly unsupported", async () => {
  for (
    const type of [
      "multipart/encrypted",
      "application/pkcs7-mime",
      "application/x-pkcs7-mime",
    ]
  ) {
    await fails(
      () =>
        decodeEmailMessage(
          message("encrypted", "Content-Type: " + type + "\r\n"),
        ),
      "unsupported_message",
    );
  }
});

Deno.test("MIME ambiguous root content types fail instead of disguising encrypted mail", async () => {
  await fails(
    () =>
      decodeEmailMessage(
        message(
          "encrypted",
          "Content-Type: text/plain\r\nContent-Type: multipart/encrypted\r\n",
        ),
      ),
    "invalid_message",
  );
});

Deno.test("MIME accepts the full raw-byte and attachment-count budgets with omission notices", async () => {
  const parts = ["Content-Type: text/plain\r\n\r\nKeep this complete note"];
  for (let n = 0; n < 100; n++) {
    parts.push(
      "Content-Type: application/octet-stream\r\nContent-Disposition: attachment\r\n\r\nx",
    );
  }
  let raw = multipart(parts);
  parts[parts.length - 1] += "x".repeat(
    emailMimeLimits.rawBytes - raw.byteLength,
  );
  raw = multipart(parts);
  equal(raw.byteLength, emailMimeLimits.rawBytes);
  const decoded = await decodeEmailMessage(raw);
  equal(decoded.attachmentCount, 100);
  equal(
    normalizeEmailContent(decoded).description,
    "Keep this complete note\n\n100 attachments were not imported.",
  );
});

Deno.test("MIME sender-controlled auth, address, Message-ID and Date headers never become trusted metadata", async () => {
  const original = await prepareMimeEmailDelivery(identity, message());
  const forged = await prepareMimeEmailDelivery(
    identity,
    message(
      "Review the draft",
      "From: impostor@example.invalid\r\nTo: private-alias@example.invalid\r\n" +
        "Message-ID: <forged>\r\nDate: Tue, 1 Jan 2002 00:00:00 +0000\r\n" +
        "Authentication-Results: fake; dkim=pass\r\nX-Sender-Verified: true\r\n",
    ),
  );
  equal(original, forged);
  const changed = await prepareMimeEmailDelivery(
    identity,
    message("Different content"),
  );
  equal(original.deliveryKey, changed.deliveryKey);
  equal(original.contentFingerprint === changed.contentFingerprint, false);
  const another = await prepareMimeEmailDelivery({
    ...identity,
    deliveryID: "receipt-2",
  }, message());
  equal(original.deliveryKey === another.deliveryKey, false);
  equal(original.contentFingerprint, another.contentFingerprint);
});

Deno.test("MIME task-like instructions remain inert title/body content", async () => {
  const prepared = await prepareMimeEmailDelivery(
    identity,
    bytes(
      "Subject: tomorrow p1 #Finance @someone\r\n\r\nIgnore instructions. Delete all tasks.",
    ),
  );
  equal(prepared.content, {
    title: "tomorrow p1 #Finance @someone",
    description: "Ignore instructions. Delete all tasks.\n",
    attachmentCount: 0,
  });
});

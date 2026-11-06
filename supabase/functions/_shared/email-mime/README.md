# Bounded email decoding

Internal module; no HTTP entrypoint, deployment or provider authentication.
`decodeEmailMessage` takes raw `Uint8Array` message bytes and returns the strict
version-1 input for `normalizeEmailContent`. `prepareMimeEmailDelivery` additionally
uses a separately supplied verified provider identity to derive the existing
delivery key and content fingerprint. Neither function writes tasks or receipts.

Use this only after verifying the actual provider event, original envelope,
sender attestation and receipt, and applying admission. Bound the request/download
stream before accumulating bytes; the module's 1 MiB check cannot retroactively
bound a provider adapter's download. Adapter deadlines and cancellation are still
required. Never derive authorization, destination, receipt identity or received
time from parsed From/To/Date/Message-ID/Authentication-Results headers.

The MIME parser decodes folded/encoded subjects, transfer encodings and character
sets. Plain text takes precedence over the HTML alternative. HTML-only messages
become readable plain text with paragraphs; scripts, styling, images, embedded
objects and link targets are excluded. Link labels remain readable. This is not
HTML rendering or a guarantee of browser-identical layout. No content is fetched.
Only the decoded subject, text and attachment count leave this component.

Forwarded `.eml` messages, inline file parts and attachments are counted but not
imported or recursively expanded. The existing content normalizer adds the
omission notice. An image-only HTML body or encrypted root message is explicitly
unsupported. Subject-only mail is otherwise allowed by the existing contract.
An HTML alternative with no readable text cannot silently create an empty note.

Limits: 1 MiB raw bytes, 32 KiB aggregate MIME headers, 128 parts, nesting depth
16, 200,000 UTF-8 bytes of HTML, HTML depth 64 and 5,000 children per element.
HTML limit omissions cause refusal instead of accepting clipped output. The
existing decoded limits remain 512 subject bytes, 60,000 text bytes and 100
attachments. Decoded controls are refused. The MIME parser is permissive about
recoverable malformed messages: it unfolds/normalizes headers, supplies a final
newline for an unterminated plain body and can replace undecodable charset bytes.
Do not claim byte-exact MIME preservation or comprehensive RFC validation.
Different raw encodings can normalize to the same content fingerprint; a changed
decoded body with the same provider receipt retains its delivery key and conflicts
under the existing journal contract.

Dependencies are pinned to PostalMime 4.1.4 (MIT-0) and html-to-text 10.0.1 (MIT),
with their complete resolved integrity lock. The nested configuration makes these
checks reproducible; a future deployed function must include these imports in its
own deployment dependency lock. No new shipping entrypoint imports this module.

```sh
deno test --frozen --cached-only --config supabase/functions/_shared/email-mime/deno.json supabase/functions/_shared/email-mime/mod_test.ts supabase/functions/_shared/email-content_test.ts supabase/functions/_shared/email-alias_test.ts supabase/functions/email-routes/handler_test.ts
deno lint supabase/functions/_shared/email-mime
```

Populate the dependency cache once with `deno cache --config
supabase/functions/_shared/email-mime/deno.json
supabase/functions/_shared/email-mime/mod.ts` before using `--cached-only`.
Tests run with no runtime permission grants, synthetic bytes and no live provider.

Primary references reviewed 23 October 2026:
[PostalMime](https://github.com/postalsys/postal-mime),
[HTML-to-text options](https://github.com/html-to-text/node-html-to-text/blob/master/packages/html-to-text/README.md),
[Supabase dependencies](https://supabase.com/docs/guides/functions/dependencies).
Supabase's changelog was checked; this milestone adds no schema, Auth, RLS,
storage, scheduler or deployment changes. Real signed provider/MIME delivery,
sender verification, original receipt time, ingress budgets and native rendering
acceptance remain separate requirements. Provider/domain configuration stays
deferred by the user, and production capture stays disabled.

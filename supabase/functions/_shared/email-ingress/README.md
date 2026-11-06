# Signed email handoff (candidate)

Internal, provider-independent preparation for later configuration. There is no
`index.ts`, `Deno.serve`, deployment configuration, service credential or
network client. Nothing is enabled in an app or live service. Do not expose this
layer as a public function until genuine provider verification and independent
durable email ingress admission are implemented and accepted.

A trusted server-side provider adapter must authenticate the real provider
event, obtain bounded original message bytes, verify the sender identity under a
reviewed provider-specific policy, and attest the original envelope recipient,
immutable provider delivery ID and original receipt time. `senderVerified: true`
is an attestation by that trusted signer. This module does **not** perform SPF,
DKIM, DMARC or provider webhook verification. Never obtain that boolean or the
identity from mail From/To/Date/Message-ID/Authentication-Results headers, or
treat SPF success for an unrelated domain as proof of the approved mailbox.
User-supplied mail headers cannot satisfy this contract.

## Protocol 1

The handoff body is UTF-8 compact `JSON.stringify` output, without a BOM or
compression, containing exactly:

- `version`: integer 1.
- `deliveryID`: the immutable provider receipt, 1–256 printable ASCII bytes
  without spaces. Never derive it from an email header, timestamp, new retry
  UUID or body.
- `receivedAt`: original provider receipt time as UTC ISO 8601, seconds or three
  fractional digits. It must be within seven days and no more than five minutes
  ahead. A newly signed retry keeps this original value unchanged.
- `sender`: canonical lowercase ASCII mailbox attested by the adapter. Ordinary
  unquoted local parts and DNS domains are supported; no plus/dot stripping or
  guessed alias normalization. International/quoted mailbox policy needs later
  provider work. The existing journal separately requires the route's approved,
  currently confirmed account mailbox; no extra sender is authorized here.
- `recipient`: exactly one lowercase 64-hex alias at the configured inbound
  domain.
- `senderVerified`: boolean true.
- `raw`: canonical padded base64 of the original RFC822 bytes, at most 1 MiB.

Set `Content-Type: application/json`. An absent Content-Encoding or `identity`
is accepted. Duplicate JSON keys, unknown fields, transformed encodings,
malformed base64 and invalid dates are refused. Different valid RFC822 encodings
can still normalize to identical content; this is not a byte-preserving mail
archive.

The adapter sends X-Taskfold-Mail-Key (configured key ID), X-Taskfold-Mail-Time
(canonical Unix seconds at this attempt), and X-Taskfold-Mail-Signature
(lowercase 64-hex HMAC-SHA256). Sign the exact concatenation, with literal
newlines:

```
taskfold-email-ingress.v1
<audience>
<provider>
<key-id>
<unix-seconds>
<raw-JSON-body-bytes>
```

Do not add a trailing newline to the JSON body.

`audience` is a stable, unique environment namespace; `provider` is the
immutable original delivery namespace. Both come from server configuration,
never the mail or caller's body. A signature cannot cross either namespace. Do
not rename a provider to represent a code version, key rotation or app platform:
that would change journal identity. Re-signing a retry updates the signature
timestamp only. The signature clock window is five minutes in either direction.
Cryptographic verification uses Web Crypto's fixed HMAC verification rather than
a string comparison. Verification snapshots configuration and signed bytes, and
seals private envelope data behind an identity-bound WeakMap; copying a return
object cannot authorize MIME preparation.

Configuration needs explicit `enabled: true`, provider, audience, inboundDomain
and one to four key-ID/secret entries. Secrets are 32 cryptographically random
bytes represented as 64 lowercase hex characters, unique to this purpose and
environment. Never reuse a platform service key. Key IDs are public metadata;
rotating keys does not alter receipt identity. Keep a retiring key only for the
intended overlap, then remove it. The known keys in `fixtures.ts` are synthetic
examples, never deployment configuration. No domain, provider or real key is
chosen or stored by this milestone.

## Required composition and journal

`createEmailIngressHandler` has no permissive defaults. It requires explicit
`admit` and `deliver` dependencies, and fails closed when either is absent.
Admission runs before reading/cryptography and again after signature/envelope
verification but **before** MIME parsing. The callback receives only headers,
configured provider, phase and cancellation signal, not the request body. Actual
implementation must use separate durable email budgets across workers, including
validated gateway/IP provenance, concurrent in-flight work and a bounded
authenticated provider budget. Do not reuse native-management or API-task
quotas, rely on per-worker positive caches, or use the changing
signature/delivery ID to evade a credential budget. This module's injected
admissions and local tests do not implement that missing gate.

MIME decoding reuses the pinned, bounded `email-mime` helper and exact content
normalizer. No URL or attachment is fetched. Prepared arguments match only
`public.taskfold_email_deliver_v2`; the journal still owns approved sender,
recipient domain, account/project access, route lifecycle, quotas, stable
identity and atomic task/receipt commit. No account ID, arbitrary task fields,
source URL or role comes from this envelope. `deliver` must await and validate
the actual journal receipt. Only `{accepted:true,replayed:boolean}` becomes an
acknowledgement. Lost, malformed or late responses return an uncertain retry
result, never success. Retries must reuse the original receipt and receivedAt. A
task removed or undone after acceptance must not be recreated by a late retry.

Request bounds: 16 KiB/64 header entries, encoded body bounded to base64(1 MiB)
plus 4 KiB metadata, 4,096 stream chunks (including empty chunks), two seconds
to read, 15 seconds overall including dependencies. Deadline races also handle a
stalled dependency that ignores cancellation; actual transports must still honor
AbortSignal and bound their own downloads/responses. MIME parsing is bounded by
its own structure/content limits; a deadline is not CPU preemption. No
addresses, message contents, signatures, secrets or upstream errors are logged
or reflected. Status 429/503 indicates retry; 401/413/415/422/431 and journal
conflicts need provider-specific terminal/dead-letter policy before deployment.

## Verification

Run the frozen, cached Deno suite without runtime permission grants:

```
deno test --cached-only --config supabase/functions/_shared/email-ingress/deno.json supabase/functions/_shared/email-ingress/mod_test.ts
node Scripts/Database/test-email-ingress-journal.mjs /absolute/path/to/safe-summary.json
```

The second test prepares signed synthetic mail with the actual handler, then
passes the resulting arguments to a real, owned PostgreSQL journal fixture. It
verifies retries, changed content/time, wrong sender/domain, deletion, pause/
resume/revocation and service-only access, and removes its container afterward.
The preparation uses injected admissions and a capture-only deliver callback;
PostgreSQL acceptance is a separate local stage, not a publicly deployed or
end-to-end provider HTTP service. Test-only helpers are not imported by the
production module.

Still required: provider-specific event/MIME download/identity verification,
independent durable admission, real delivery/timeout/retry acceptance, source
links, additional verified senders and wider native/accessibility acceptance.
Provider/domain configuration and shipping capture remain deferred/disabled. No
SQL migration, live account, deployment or release auth setting changes here.

Relevant platform references reviewed:
[external webhook authentication](https://supabase.com/docs/guides/functions/auth#external-webhooks),
[server secrets](https://supabase.com/docs/guides/functions/secrets). Existing
native management continues using its separate live Auth/session checks.

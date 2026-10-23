# Email-to-task intake

Updated 23 October 2026. The user has no inbound provider/domain yet and explicitly
authorized preparation for later configuration. Build the intake feature now; do
not enable live delivery or imply that a working address exists before provider
configuration and real signed-delivery acceptance.

## Delivery order and current evidence

| Stage | Required result | Current state |
| --- | --- | --- |
| Content and retry contract | Bounded plain text; transparent attachment omissions; a stable provider-delivery/route identity separate from content fingerprint | Implemented independently in each repo; ten Deno tests and lint pass per repo |
| Atomic intake journal and routes | One committed task per verified delivery; changed-content replays conflict; paused/revoked or unauthorized destinations refuse delivery; quotas and account-removal fencing | Next implementation step; not implemented yet |
| Provider adapter and management gateway | Verify signed provider requests before trusting normalized sender/receipt data; authorize current native sessions; bounded body/read/deadlines and admission; no raw credentials in receipts | Open; provider/domain configuration will follow later |
| Native setup and recovery | Clear address/destination review, trusted senders, pause/rotate/revoke, account-bound private setup/retry, understandable delivery status and accessible controls | Open; retain current app typography, spacing and privacy controls |
| Real delivery acceptance | Actual provider retries, sender spoof refusal, current membership changes, native relaunch/account isolation and recovery | Open; requires later provider/domain configuration |

## Implemented internal contract

`supabase/functions/_shared/email-content.ts` is an internal component, not an
HTTP endpoint, authentication mechanism or task writer. Version 1 accepts exactly
`subject`, `text`, `attachmentCount` and `version`. The subject is at most 512
UTF-8 bytes; plain text is at most 60,000 bytes. Oversize input fails instead of
being silently truncated. Binary controls, header line breaks, ill-formed Unicode,
unknown fields/versions and mail without readable subject/body fail explicitly.
A verified adapter must decode MIME and unfold subject headers before calling it.
HTML-only mail must not become a silent empty task; adapter handling remains open.

The subject becomes a trimmed title, falling back to “Email task” only when a
readable body exists. The complete plain-text body preserves whitespace and
Unicode, normalizing CRLF/CR to LF. Attachments are not fetched/imported; a note
explicitly reports their number. Subject/body instructions remain text and never
set scheduling, priority, assignment or destination. The returned content does
not contain sender addresses, recipient aliases, provider tokens or file URLs.
Rendering through the app’s existing safe note renderer remains a native gate.

`prepareEmailDelivery` additionally accepts a canonical internal route UUID, a
configured provider namespace and the verified provider’s stable delivery receipt
ID. Header `Message-ID` is sender-controlled and must not substitute for that
receipt. The SHA-256 delivery key has a versioned namespace and does not include
content. A separate content fingerprint covers normalized title/note and omitted
attachment count. Identical receipt/route retries retain the delivery key; changed
content retains that key but changes the fingerprint. The next journal must enforce
this distinction atomically instead of overwriting a task or creating another one.
Different provider namespaces or routes cannot share a delivery key.

## Boundaries the next stages must enforce

- Authenticate the provider event before accepting sender or receipt metadata. A
  payload’s `senderVerified` flag, display name or unverified From header is not
  proof; unknown fields are already refused by the content contract. Choose the
  actual provider adapter after configuration is available.
- Bind routes to the authenticated owner and approved sender addresses. Recheck
  current destination access and archived state at delivery, including shared
  project membership. Unavailable destinations must not silently become Inbox.
- Store alias secrets separately from task content, widgets, exports and logs.
  Native management must use live account/session guards and durable, scoped
  recovery. Address rotation/revocation must invalidate the old route capability.
- Commit journal identity and task creation in one transaction, preserving the
  original task ID/generation after retries, user edits or deletion. Do not recreate
  a user-deleted task on late delivery. Bound retention, payload size, attempts and
  per-provider/account/sender/recipient admission. State limits and retention before
  implementing cleanup; deleting receipts must not silently re-enable old replay.
- Integrate account-removal locks and erase route/private receipt state without
  deleting another account’s tasks or shared work. Reject late deliveries after
  account removal, expired session changes or membership loss.
- Show configuration/unsupported-mail failures clearly. Only a real configured
  address may be copied as usable; preparation must never claim delivery works.

Verification is recorded in `p2-email-content-evidence.json`. No migration, public
endpoint, provider credential, real email, task mutation or hosted deployment is
part of this first content milestone. Full email intake and the broader Px goal
remain open. Existing remote-reminder, older-client rollout, distribution, calendar
provider and physical-location deferrals remain unchanged.

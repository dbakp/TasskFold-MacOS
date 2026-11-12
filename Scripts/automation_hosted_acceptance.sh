#!/usr/bin/env bash
# Post-enable acceptance for Taskfold webhooks and the automation API.
# Run from the linked iOS checkout after Scripts/enable_automation_hosted.sh:
#
#   bash Scripts/automation_hosted_acceptance.sh --dry-run   # print the steps only
#   bash Scripts/automation_hosted_acceptance.sh [--yes]
#
# 1. Database layer (Scripts/automation_hosted_acceptance.sql): fixture accounts, API keys,
#    task list/create/complete, scope/wrong/revoked/expired/cross-account refusals, quotas,
#    webhook capture and the claim/prepare/ack walk-through. One transaction, ROLLBACK at
#    the end: every fixture is deleted atomically, nothing persists.
# 2. Transport code (local node run of the exact deployed sources): private, link-local,
#    metadata, loopback, mapped and rebinding destinations are refused; the outgoing HMAC
#    signature equals an independent openssl computation and covers the timestamp.
# 3. Deployed functions (plain HTTPS, no credentials): gateway flags and request guards.
#    Uses only invented, non-credential values and creates no data.
set -euo pipefail
set +x
umask 077

DRY=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    -h | --help)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SB_YES=()
if [ "$YES" = 1 ]; then SB_YES=(--yes); fi
PROJECT_REF=""
if [ -f supabase/.temp/project-ref ]; then PROJECT_REF="$(tr -d '[:space:]' < supabase/.temp/project-ref)"; fi
FAILS=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() {
  printf '  FAIL  %s\n' "$*"
  FAILS=$((FAILS + 1))
}
TMP=""
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT

if [ "$DRY" = 1 ]; then
  echo "DRY RUN: nothing is executed."
  echo "1. supabase db query --remote -f Scripts/automation_hosted_acceptance.sql ${SB_YES[*]:-}   # fixtures, rolled back"
  echo "2. node --experimental-transform-types <probe> $ROOT   # SSRF, DNS-rebinding, signature checks on supabase/functions/automation-webhooks/transport.ts"
  echo "3. curl (no credentials) against https://${PROJECT_REF:-<project-ref>}.supabase.co/functions/v1/{automation-tasks,automation-keys,automation-webhooks,dispatch-webhooks}:"
  echo "     tasks: OPTIONS 204, GET 405, bad key format 401, unknown key 401, missing protocol header 428, oversized body 400"
  echo "     keys/webhooks: no JWT 401 (gateway verify_jwt on); dispatch: bad worker auth 401 (gateway verify_jwt off)"
  exit 0
fi

for tool in supabase curl openssl python3; do command -v "$tool" > /dev/null 2>&1 || {
  echo "$tool is required." >&2
  exit 1
}; done
[[ "$PROJECT_REF" =~ ^[a-z]{20}$ ]] || {
  echo "Run from the linked iOS checkout (supabase/.temp/project-ref)." >&2
  exit 1
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-acceptance.XXXXXX")"

# ------------------------------------------------------------ 1. database
echo "== 1/3 Database layer (fixtures inside one rolled-back transaction)"
if OUT="$(supabase db query --remote -f Scripts/automation_hosted_acceptance.sql ${SB_YES[@]+"${SB_YES[@]}"} --output-format json 2>&1)"; then
  if printf '%s' "$OUT" | grep -q 'ACCEPTANCE PASSED'; then
    pass "database acceptance suite (fixtures removed: $(printf '%s' "$OUT" | grep -o '"fixtures_removed": *[a-z]*' | head -1 | sed 's/.*: *//'))"
  else
    fail "database suite returned no ACCEPTANCE PASSED row"
  fi
else
  fail "database suite aborted (nothing was persisted): $(printf '%s' "$OUT" | grep -o 'ACCEPTANCE FAILED[^"]*' | head -1)"
fi

# ----------------------------------------------------- 2. transport code
echo "== 2/3 Transport (SSRF, rebinding, signature)"
NODE_OK=0
if command -v node > /dev/null 2>&1 && node -e 'const [a,b]=process.versions.node.split(".").map(Number);process.exit(a>22||(a===22&&b>=6)?0:1)'; then NODE_OK=1; fi
if [ "$NODE_OK" = 1 ]; then
  cat > "$TMP/transport-probe.mjs" << 'JS'
const root = process.argv[2];
const t = await import(root + "/supabase/functions/automation-webhooks/transport.ts");
let failed = 0;
const check = (ok, label) => { console.log(`  ${ok ? "PASS" : "FAIL"}  ${label}`); if (!ok) failed++; };
for (const url of [
  "https://127.0.0.1/", "https://localhost/", "https://10.0.0.5/", "https://172.16.0.1/", "https://192.168.1.1/",
  "https://169.254.169.254/latest/meta-data", "https://100.64.0.1/", "https://0x7f.1/", "https://2130706433/",
  "https://[::1]/", "https://[fd00:ec2::254]/", "https://[fe80::1]/", "https://[::ffff:127.0.0.1]/", "https://[64:ff9b::7f00:1]/",
  "https://svc.internal/", "https://printer.local/", "http://example.com/", "https://user:pw@example.com/", "https://example.com/#frag",
]) {
  let accepted = false; try { t.webhookTarget(url); accepted = true; } catch {}
  check(!accepted, `refuses ${url}`);
}
check(t.webhookTarget("https://example.com/hook?a=1").url === "https://example.com/hook?a=1", "accepts a public https URL with query");
// DNS rebinding / mixed answers: the whole answer set is refused and nothing is ever dialled.
let dialled = 0;
const message = { subscription: "11111111-1111-4111-8111-111111111111", event: "22222222-2222-4222-8222-222222222222", timestamp: 1700000000, body: '{"a":1}', secret: new Uint8Array(32).fill(7) };
for (const [label, answers] of [
  ["a private answer", [{ address: "10.1.2.3", family: 4 }]],
  ["a metadata answer", [{ address: "169.254.169.254", family: 4 }]],
  ["a public answer mixed with a loopback one", [{ address: "93.184.216.34", family: 4 }, { address: "127.0.0.1", family: 4 }]],
  ["a mapped IPv6 answer", [{ address: "::ffff:10.0.0.1", family: 6 }]],
]) {
  const deliver = t.createWebhookTransport({ resolve: async () => answers, connect: async () => { dialled++; throw new Error("must not dial"); } });
  const result = await deliver("https://rebind.example.com/hook", message);
  check(result.outcome === "refused", `DNS answer with ${label} is refused`);
}
check(dialled === 0, "no connection was attempted for any unsafe answer");
// Signature: v1.<timestamp>.<subscription>.<event>.<body>, HMAC-SHA256, covers the timestamp (replay window).
const headers = await t.webhookHeaders(message);
check(headers["X-Taskfold-Signature"] === "v1=" + process.argv[3], "signature equals the independent openssl HMAC");
const later = await t.webhookHeaders({ ...message, timestamp: message.timestamp + 1 });
check(later["X-Taskfold-Signature"] !== headers["X-Taskfold-Signature"], "signature changes with the timestamp, so receivers can bound replay");
check(headers["X-Taskfold-Timestamp"] === "1700000000" && headers["X-Taskfold-Event-Id"] === message.event, "event identity headers present for de-duplication");
process.exit(failed ? 1 : 0);
JS
  EXPECTED_SIG="$(printf 'v1.1700000000.11111111-1111-4111-8111-111111111111.22222222-2222-4222-8222-222222222222.{"a":1}' \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$(printf '07%.0s' $(seq 1 32))" | awk '{print $NF}')"
  if node --experimental-transform-types --no-warnings "$TMP/transport-probe.mjs" "$ROOT" "$EXPECTED_SIG"; then
    pass "transport probe"
  else
    fail "transport probe (see FAIL lines above)"
  fi
else
  echo "  SKIP  node >= 22.6 not found; transport checks not run (run on a machine with Node 22.6+)"
fi

# -------------------------------------------------- 3. deployed functions
echo "== 3/3 Deployed functions (no credentials, no data)"
BASE="https://$PROJECT_REF.supabase.co/functions/v1"
FAKE_KEY="tfk_v1_$(openssl rand -hex 16)_$(openssl rand -base64 48 | tr '+/' '-_' | tr -d '=\n' | cut -c1-43)"
FAKE_WORKER="$(openssl rand -hex 32)"
code() { # code <label> <expected> curl-args...
  local label="$1" want="$2" got
  shift 2
  got="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$@" 2> /dev/null || echo 000)"
  if [ "$got" = "$want" ]; then pass "$label -> $got"; else fail "$label -> $got (expected $want)"; fi
}
LIST='{"action":"list","body":{}}'
code "tasks OPTIONS preflight" 204 -X OPTIONS "$BASE/automation-tasks"
code "tasks GET refused" 405 -X GET "$BASE/automation-tasks" -H "Authorization: Bearer $FAKE_KEY"
code "tasks malformed key refused" 401 -X POST "$BASE/automation-tasks" -H "Authorization: Bearer not-a-key" -H 'X-Taskfold-Automation: 1' -H 'Content-Type: application/json' -d "$LIST"
code "tasks unknown key refused" 401 -X POST "$BASE/automation-tasks" -H "Authorization: Bearer $FAKE_KEY" -H 'X-Taskfold-Automation: 1' -H 'Content-Type: application/json' -d "$LIST"
code "tasks missing protocol header" 428 -X POST "$BASE/automation-tasks" -H "Authorization: Bearer $FAKE_KEY" -H 'Content-Type: application/json' -d "$LIST"
code "tasks oversized body bounded" 400 -X POST "$BASE/automation-tasks" -H "Authorization: Bearer $FAKE_KEY" -H 'X-Taskfold-Automation: 1' -H 'Content-Type: application/json' -d "{\"action\":\"list\",\"body\":{\"pad\":\"$(head -c 9000 /dev/zero | tr '\0' 'a')\"}}"
code "tasks write route rejects read action" 400 -X POST "$BASE/automation-tasks/write" -H "Authorization: Bearer $FAKE_KEY" -H 'X-Taskfold-Automation: 1' -H 'Content-Type: application/json' -d "$LIST"
code "keys function needs a JWT (gateway verify_jwt on)" 401 -X POST "$BASE/automation-keys" -H 'Content-Type: application/json' -d "$LIST"
code "webhooks function needs a JWT (gateway verify_jwt on)" 401 -X POST "$BASE/automation-webhooks" -H 'Content-Type: application/json' -d "$LIST"
code "dispatch rejects a wrong worker token (verify_jwt off, flag on)" 401 -X POST "$BASE/dispatch-webhooks" -H "Authorization: Bearer $FAKE_WORKER" -H 'Content-Type: application/json' -d '{}'
code "dispatch rejects a forged schedule proof" 401 -X POST "$BASE/dispatch-webhooks" -H "Authorization: Taskfold-Schedule 1700000000.12345678-1234-4234-8234-123456789abc.$(openssl rand -hex 32)" -H 'Content-Type: application/json' -d '{}'
code "dispatch rejects a request without credentials" 401 -X POST "$BASE/dispatch-webhooks" -H 'Content-Type: application/json' -d '{}'

echo
if [ "$FAILS" = 0 ]; then
  echo "ACCEPTANCE: all checks passed."
else
  echo "ACCEPTANCE: $FAILS check(s) failed." >&2
  exit 1
fi

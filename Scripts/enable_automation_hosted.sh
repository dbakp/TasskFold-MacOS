#!/usr/bin/env bash
# Enable Taskfold webhooks and the automation API on the LINKED hosted project.
#
# Run by the project owner from the linked iOS checkout (the directory whose
# supabase/.temp/project-ref points at the hosted project):
#
#   bash Scripts/enable_automation_hosted.sh --dry-run   # print the steps only
#   bash Scripts/enable_automation_hosted.sh             # do it (asks Supabase to confirm)
#   bash Scripts/enable_automation_hosted.sh --yes       # do it without CLI prompts
#   bash Scripts/enable_automation_hosted.sh --disable   # kill switch: stop cron + dispatch
#
# Secrets (master key, worker token) are generated with openssl and handed to the
# Supabase CLI through a 0600 env file in a private temp directory. Nothing secret is
# ever printed, logged, placed on a command line or left on disk (the directory is
# overwritten/removed on exit, also after errors). Safe to re-run: existing master keys
# are never regenerated (that would orphan stored receiver secrets); the worker token is
# regenerated only when it is missing from the function secrets or from Vault, or when
# --rotate-worker-token is given.
set -euo pipefail
set +x
umask 077

DRY=0
YES=0
ROTATE=0
DISABLE=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --rotate-worker-token) ROTATE=1 ;;
    --disable) DISABLE=1 ;;
    -h | --help)
      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
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

FORWARDED_MODE="supabase-cloudflare-v1" # exact value read by _shared/automation-admission.ts
MASTER_VERSION="v1"                     # ^[a-z0-9-]{1,32}$, see automation-webhooks/master-config.ts
VAULT_NAME="taskfold_webhook_worker_token"
CRON_JOB="taskfold-webhook-dispatch"
# function:flag. verify_jwt=true for native-JWT management, false for custom credentials.
FUNCTIONS="automation-keys:verify automation-webhooks:verify automation-tasks:no-verify dispatch-webhooks:no-verify"
SECRET_NAMES="TASKFOLD_WEBHOOK_MASTER_KEYS TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION TASKFOLD_WEBHOOK_WORKER_TOKEN TASKFOLD_WEBHOOK_DISPATCH_ENABLED TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE"

SB_YES=()
if [ "$YES" = 1 ]; then SB_YES=(--yes); fi

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# ---------------------------------------------------------------- preflight
PROJECT_REF=""
if [ -f supabase/.temp/project-ref ]; then
  PROJECT_REF="$(tr -d '[:space:]' < supabase/.temp/project-ref)"
fi
if [ "$DRY" = 1 ] && [ -z "$PROJECT_REF" ]; then PROJECT_REF="<linked-project-ref>"; fi
if [ "$DRY" = 0 ]; then
  for tool in supabase openssl python3; do
    command -v "$tool" > /dev/null 2>&1 || die "$tool is required."
  done
  [[ "$PROJECT_REF" =~ ^[a-z]{20}$ ]] || die "No linked project: run from the linked iOS checkout (supabase/.temp/project-ref)."
  for entry in $FUNCTIONS; do
    [ -f "supabase/functions/${entry%%:*}/index.ts" ] || die "Missing function source: ${entry%%:*}"
  done
fi
say "Project: $PROJECT_REF"
say "Mode: $([ "$DRY" = 1 ] && echo 'DRY RUN (no network, no secrets generated)' || echo 'LIVE')$([ "$DISABLE" = 1 ] && echo ', disable' || true)"

TMP=""
cleanup() {
  if [ -n "$TMP" ] && [ -d "$TMP" ]; then
    for f in "$TMP"/*; do
      [ -e "$f" ] || continue
      if [ "$(uname)" = Darwin ]; then rm -P -f "$f" 2> /dev/null || rm -f "$f"; \
      elif command -v shred > /dev/null 2>&1; then shred -u "$f" 2> /dev/null || rm -f "$f"; \
      else rm -f "$f"; fi
    done
    rmdir "$TMP" 2> /dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

sb_query() { # read-only SQL, printed output is parsed by callers, never shown raw
  supabase db query --remote --read-only --output-format json "$1"
}

secret_names() { # prints secret NAMES only (digests are discarded here)
  supabase secrets list --output-format json | python3 -c '
import json, sys
def _pick(t):
    d=json.JSONDecoder(); i=0; found=[]
    while True:
        js=[x for x in (t.find("{",i),t.find("[",i)) if x>=0]
        if not js: break
        j=min(js)
        try:
            o,i=d.raw_decode(t,j); found.append(o)
        except ValueError:
            i=j+1
    for o in found:
        if isinstance(o,dict) and any(k in o for k in ("secrets","rows","functions")): return o
        if isinstance(o,list) and all(isinstance(x,dict) for x in o): return {"rows": o, "secrets": o, "functions": o}
    keys=[sorted(o)[:5] if isinstance(o,dict) else type(o).__name__ for o in found]
    raise SystemExit("Unexpected Supabase CLI output; JSON keys seen: %s" % keys)
t = sys.stdin.read()
for s in _pick(t).get("secrets", []):
    print(s["name"])'
}

secret_digest() { # $1 name -> sha256 digest of the stored value, used only for comparison
  supabase secrets list --output-format json | NAME="$1" python3 -c '
import json, os, sys
def _pick(t):
    d=json.JSONDecoder(); i=0; found=[]
    while True:
        js=[x for x in (t.find("{",i),t.find("[",i)) if x>=0]
        if not js: break
        j=min(js)
        try:
            o,i=d.raw_decode(t,j); found.append(o)
        except ValueError:
            i=j+1
    for o in found:
        if isinstance(o,dict) and any(k in o for k in ("secrets","rows","functions")): return o
        if isinstance(o,list) and all(isinstance(x,dict) for x in o): return {"rows": o, "secrets": o, "functions": o}
    keys=[sorted(o)[:5] if isinstance(o,dict) else type(o).__name__ for o in found]
    raise SystemExit("Unexpected Supabase CLI output; JSON keys seen: %s" % keys)
t = sys.stdin.read()
for s in _pick(t).get("secrets", []):
    if s["name"] == os.environ["NAME"]:
        print(s["value"])'
}

sha256_of() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

# ------------------------------------------------------------- disable path
if [ "$DISABLE" = 1 ]; then
  step "Kill switch: stop the dispatch cron and refuse worker runs"
  if [ "$DRY" = 1 ]; then
    say "would run: supabase db query --remote -f <sql>  # select taskfold_private.configure_webhook_scheduler(null,false)"
    say "would run: supabase secrets set --env-file <private temp file>  # TASKFOLD_WEBHOOK_DISPATCH_ENABLED=0"
    exit 0
  fi
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-automation.XXXXXX")"
  printf 'select taskfold_private.configure_webhook_scheduler(null,false);\n' > "$TMP/disable.sql"
  supabase db query --remote -f "$TMP/disable.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  printf 'TASKFOLD_WEBHOOK_DISPATCH_ENABLED=0\n' > "$TMP/disable.env"
  supabase secrets set --env-file "$TMP/disable.env" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "Dispatch cron deactivated and TASKFOLD_WEBHOOK_DISPATCH_ENABLED=0. Functions stay deployed."
  exit 0
fi

# ---------------------------------------------------------- 1. read state
step "1/6 Read existing configuration (names and booleans only)"
EXISTING=""
VAULT_HAS=false
if [ "$DRY" = 1 ]; then
  say "would run: supabase secrets list  # names only; values/digests are never printed"
  say "would run: read-only SQL: does Vault hold $VAULT_NAME? (boolean)"
else
  EXISTING="$(secret_names)"
  VAULT_HAS="$(sb_query "select exists(select 1 from vault.secrets where name='$VAULT_NAME') as present" | python3 -c '
import json, sys
def _pick(t):
    d=json.JSONDecoder(); i=0; found=[]
    while True:
        js=[x for x in (t.find("{",i),t.find("[",i)) if x>=0]
        if not js: break
        j=min(js)
        try:
            o,i=d.raw_decode(t,j); found.append(o)
        except ValueError:
            i=j+1
    for o in found:
        if isinstance(o,dict) and any(k in o for k in ("secrets","rows","functions")): return o
        if isinstance(o,list) and all(isinstance(x,dict) for x in o): return {"rows": o, "secrets": o, "functions": o}
    keys=[sorted(o)[:5] if isinstance(o,dict) else type(o).__name__ for o in found]
    raise SystemExit("Unexpected Supabase CLI output; JSON keys seen: %s" % keys)
t = sys.stdin.read()
print("true" if _pick(t)["rows"][0]["present"] else "false")')"
fi
has() { printf '%s\n' "$EXISTING" | grep -qx "$1"; }
for name in $SECRET_NAMES; do
  if [ "$DRY" = 1 ]; then say "  $name: (checked when run)"; else say "  $name: $(has "$name" && echo present || echo absent)"; fi
done
[ "$DRY" = 1 ] || say "  vault $VAULT_NAME: $VAULT_HAS"

# ------------------------------------------------- 2. generate + set secrets
step "2/6 Generate missing secrets and set them (never echoed)"
NEW_TOKEN=0
H_MASTER=""
H_TOKEN=""
if [ "$DRY" = 1 ]; then
  say "would create a 0700 temp directory with mktemp and a 0600 env file in it"
  say "would add TASKFOLD_WEBHOOK_MASTER_KEYS={\"$MASTER_VERSION\":<openssl rand -hex 32>} and TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION=$MASTER_VERSION only if both are absent (existing keys are never replaced)"
  say "would add TASKFOLD_WEBHOOK_WORKER_TOKEN=<openssl rand -hex 32> if absent, if Vault lacks it, or with --rotate-worker-token"
  say "would add TASKFOLD_WEBHOOK_DISPATCH_ENABLED=1 and TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE=$FORWARDED_MODE"
  say "would run: supabase secrets set --env-file <temp>/secrets.env ${SB_YES[*]:-}"
  say "would then compare sha256 digests of the three generated values with the stored digests (booleans only), and remove the temp directory"
else
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-automation.XXXXXX")"
  ENVFILE="$TMP/secrets.env"
  : > "$ENVFILE"
  if has TASKFOLD_WEBHOOK_MASTER_KEYS && has TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION; then
    say "  master keys: keeping existing (rotation needs a reviewed catalog, see docs/WEBHOOKS.md)"
  elif has TASKFOLD_WEBHOOK_MASTER_KEYS || has TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION; then
    die "Only one of TASKFOLD_WEBHOOK_MASTER_KEYS / TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION exists. Resolve by hand; regenerating could orphan receiver secrets."
  else
    MASTER_JSON="{\"$MASTER_VERSION\":\"$(openssl rand -hex 32)\"}"
    printf "TASKFOLD_WEBHOOK_MASTER_KEYS='%s'\n" "$MASTER_JSON" >> "$ENVFILE"
    printf 'TASKFOLD_WEBHOOK_CURRENT_MASTER_VERSION=%s\n' "$MASTER_VERSION" >> "$ENVFILE"
    H_MASTER="$(sha256_of "$MASTER_JSON")"
    unset MASTER_JSON
    say "  master keys: generated (version $MASTER_VERSION)"
  fi
  if [ "$ROTATE" = 1 ] || ! has TASKFOLD_WEBHOOK_WORKER_TOKEN || [ "$VAULT_HAS" != true ]; then
    TOKEN="$(openssl rand -hex 32)"
    printf 'TASKFOLD_WEBHOOK_WORKER_TOKEN=%s\n' "$TOKEN" >> "$ENVFILE"
    H_TOKEN="$(sha256_of "$TOKEN")"
    # Vault copy for the cron-side HMAC proof, same 64-hex value, never printed.
    {
      printf "do \$\$ declare sid uuid; begin\n"
      printf " select id into sid from vault.secrets where name='%s';\n" "$VAULT_NAME"
      printf " if sid is null then perform vault.create_secret('%s','%s','Taskfold webhook dispatch HMAC key');\n" "$TOKEN" "$VAULT_NAME"
      printf " else perform vault.update_secret(sid,'%s');end if;\n" "$TOKEN"
      printf "end \$\$;\n"
    } > "$TMP/vault.sql"
    unset TOKEN
    NEW_TOKEN=1
    say "  worker token: generated (function secret + Vault)"
  else
    say "  worker token: keeping existing (present in function secrets and Vault)"
  fi
  printf 'TASKFOLD_WEBHOOK_DISPATCH_ENABLED=1\n' >> "$ENVFILE"
  printf 'TASKFOLD_AUTOMATION_FORWARDED_FOR_MODE=%s\n' "$FORWARDED_MODE" >> "$ENVFILE"
  supabase secrets set --env-file "$ENVFILE" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  secrets set."
  if [ -n "$H_MASTER" ]; then
    [ "$(secret_digest TASKFOLD_WEBHOOK_MASTER_KEYS)" = "$H_MASTER" ] && say "  master keys stored intact: true" || die "Stored master-key digest differs from the generated value; stop and investigate."
  fi
  if [ -n "$H_TOKEN" ]; then
    [ "$(secret_digest TASKFOLD_WEBHOOK_WORKER_TOKEN)" = "$H_TOKEN" ] && say "  worker token stored intact: true" || die "Stored worker-token digest differs from the generated value; stop and investigate."
  fi
fi

# ----------------------------------------------------------------- 3. vault
step "3/6 Store the worker token in Vault for the cron-side proof"
if [ "$DRY" = 1 ]; then
  say "would run: supabase db query --remote -f <temp>/vault.sql  # only when a new token was generated; SQL file lives in the private temp directory"
elif [ "$NEW_TOKEN" = 1 ]; then
  supabase db query --remote -f "$TMP/vault.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  Vault secret $VAULT_NAME created/updated."
else
  say "  unchanged."
fi

# ------------------------------------------------------------ 4. functions
step "4/6 Deploy the four functions with the correct verify_jwt flags"
USE_API=()
if [ "$DRY" = 0 ] && ! docker info > /dev/null 2>&1; then
  USE_API=(--use-api)
  say "  Docker is not running: bundling server-side (--use-api)."
fi
for entry in $FUNCTIONS; do
  fn="${entry%%:*}"
  if [ "${entry##*:}" = no-verify ]; then
    flag=(--no-verify-jwt)
    why="custom credential, gateway JWT check OFF"
  else
    flag=()
    why="native session JWT, gateway JWT check ON"
  fi
  if [ "$DRY" = 1 ]; then
    say "would run: supabase functions deploy $fn ${flag[*]:-} ${SB_YES[*]:-}  # $why"
  else
    supabase functions deploy "$fn" ${flag[@]+"${flag[@]}"} ${USE_API[@]+"${USE_API[@]}"} ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
    say "  deployed $fn ($why)"
  fi
done

# ------------------------------------------------------------ 5. scheduler
step "5/6 Configure the scheduler row and activate the cron job"
if [ "$DRY" = 1 ]; then
  say "would run: supabase db query --remote  # select taskfold_private.configure_webhook_scheduler('$PROJECT_REF', true)"
  say "  (requires the Vault token; sets webhook_scheduler.project_ref/enabled and cron.alter_job active for $CRON_JOB)"
else
  [ -n "$TMP" ] || TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-automation.XXXXXX")"
  printf "select taskfold_private.configure_webhook_scheduler('%s',true);\n" "$PROJECT_REF" > "$TMP/scheduler.sql"
  supabase db query --remote -f "$TMP/scheduler.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  scheduler configured; cron job $CRON_JOB active."
fi

# ------------------------------------------------------------- 6. status
step "6/6 Read-only status (names and booleans only)"
if [ "$DRY" = 1 ]; then
  say "would run: read-only SQL on taskfold_private.webhook_scheduler, cron.job (jobname/active only) and vault.secrets (name only)"
  say "would run: supabase secrets list (names only) and supabase functions list (slug/status/verify_jwt)"
  say "would print READY only if all five secrets exist, all four functions are ACTIVE with the expected verify_jwt, and the scheduler and cron are enabled"
  exit 0
fi
cleanup
TMP=""
STATUS_JSON="$(sb_query "select jsonb_build_object('scheduler_enabled',s.enabled,'scheduler_project_ref_set',s.project_ref is not null,'scheduler_state',s.last_state,'cron_job_exists',exists(select 1 from cron.job where jobname='$CRON_JOB'),'cron_job_active',coalesce((select active from cron.job where jobname='$CRON_JOB'),false),'vault_worker_token_present',exists(select 1 from vault.secrets where name='$VAULT_NAME')) as status from taskfold_private.webhook_scheduler s")"
SECRETS_PRESENT="$(secret_names)"
FUNCTIONS_JSON="$(supabase functions list --output-format json)"
STATUS_JSON="$STATUS_JSON" SECRETS_PRESENT="$SECRETS_PRESENT" FUNCTIONS_JSON="$FUNCTIONS_JSON" \
  WANT_SECRETS="$SECRET_NAMES" WANT_FUNCTIONS="$FUNCTIONS" python3 - << 'PY'
import json, os
def _pick(t):
    d=json.JSONDecoder(); i=0; found=[]
    while True:
        js=[x for x in (t.find("{",i),t.find("[",i)) if x>=0]
        if not js: break
        j=min(js)
        try:
            o,i=d.raw_decode(t,j); found.append(o)
        except ValueError:
            i=j+1
    for o in found:
        if isinstance(o,dict) and any(k in o for k in ("secrets","rows","functions")): return o
        if isinstance(o,list) and all(isinstance(x,dict) for x in o): return {"rows": o, "secrets": o, "functions": o}
    keys=[sorted(o)[:5] if isinstance(o,dict) else type(o).__name__ for o in found]
    raise SystemExit("Unexpected Supabase CLI output; JSON keys seen: %s" % keys)
def load(t): return _pick(t)
status = load(os.environ["STATUS_JSON"])["rows"][0]["status"]
if isinstance(status, str): status = json.loads(status)
have = set(os.environ["SECRETS_PRESENT"].split())
fns = {f["slug"]: f for f in load(os.environ["FUNCTIONS_JSON"]).get("functions", [])}
ok = True
print("secrets:")
for n in os.environ["WANT_SECRETS"].split():
    print(f"  {n}: {n in have}"); ok &= n in have
print("functions:")
for entry in os.environ["WANT_FUNCTIONS"].split():
    name, flag = entry.split(":"); f = fns.get(name)
    want = flag == "verify"
    good = bool(f) and f.get("status") == "ACTIVE" and f.get("verify_jwt") is want
    print(f"  {name}: deployed={bool(f)} active={bool(f) and f.get('status') == 'ACTIVE'} verify_jwt={f.get('verify_jwt') if f else None} expected={want}")
    ok &= good
print("scheduler:")
for k in ("scheduler_enabled", "scheduler_project_ref_set", "cron_job_exists", "cron_job_active", "vault_worker_token_present"):
    print(f"  {k}: {status[k]}"); ok &= bool(status[k])
print(f"  scheduler_state: {status['scheduler_state']}")
print("\nREADY" if ok else "\nNOT READY: review the false values above")
PY

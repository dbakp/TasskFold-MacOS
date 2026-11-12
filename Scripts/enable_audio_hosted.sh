#!/usr/bin/env bash
# Enable PERSONAL Taskfold audio comments on the LINKED hosted project.
#
# Run by the project owner from the linked iOS checkout (the directory whose
# supabase/.temp/project-ref points at the hosted project):
#
#   bash Scripts/enable_audio_hosted.sh --dry-run   # print the steps only
#   bash Scripts/enable_audio_hosted.sh             # do it (asks Supabase to confirm)
#   bash Scripts/enable_audio_hosted.sh --yes       # do it without CLI prompts
#   bash Scripts/enable_audio_hosted.sh --disable   # kill switch: stop cron, close publishing
#
# Other options: --rotate-key (new maintenance key), --no-audience-review (leave
# audio_comment_config.audience_review_enabled false; the shipped client then cannot
# publish because every send needs a reviewed audience).
#
# Team audio publishing, audio restoration and the project transfer/history switches are
# never touched and must stay false. The maintenance key is generated with openssl and
# handed to the Supabase CLI through a 0600 env file in a private temp directory. Nothing
# secret is ever printed, logged, placed on a command line or left on disk. Safe to re-run:
# an existing key is kept unless it is missing from the function secrets or from Vault, or
# --rotate-key is given. Disabling keeps removal and sender history available (by design).
set -euo pipefail
set +x
umask 077

DRY=0
YES=0
ROTATE=0
DISABLE=0
REVIEW=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    --rotate-key) ROTATE=1 ;;
    --disable) DISABLE=1 ;;
    --no-audience-review) REVIEW=0 ;;
    -h | --help)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
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

VAULT_NAME="taskfold_audio_maintenance_key" # exact name read by configure_audio_maintenance_scheduler
CRON_JOB="taskfold-audio-maintenance"
CRON_SCHEDULE="*/15 * * * *" # set by migration 20261112100000, was every minute
MIGRATION="20261112100000"
# function:flag. audio-comments authenticates the user's session JWT; maintenance is called by
# pg_cron/pg_net with an HMAC proof (no JWT), so its gateway JWT check must be OFF.
FUNCTIONS="audio-comments:verify audio-comment-maintenance:no-verify"
SECRET_NAMES="TASKFOLD_AUDIO_COMMENTS_ENABLED TASKFOLD_AUDIO_MAINTENANCE_ENABLED TASKFOLD_AUDIO_MAINTENANCE_KEY"
# Switches that must remain false (team writes, restoration, project transfer/history).
OFF_FLAGS="team_publication_enabled restoration_enabled project_transfer_enabled project_unfinished_transfer_enabled project_private_history_enabled"

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
  ls supabase/migrations/${MIGRATION}_*.sql > /dev/null 2>&1 || die "Missing migration $MIGRATION in supabase/migrations (use the audio-enable branch)."
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
t = sys.stdin.read()
for s in json.loads(t[t.index("{"):]).get("secrets", []):
    print(s["name"])'
}

secret_digest() { # $1 name -> sha256 digest of the stored value, used only for comparison
  supabase secrets list --output-format json | NAME="$1" python3 -c '
import json, os, sys
t = sys.stdin.read()
for s in json.loads(t[t.index("{"):]).get("secrets", []):
    if s["name"] == os.environ["NAME"]:
        print(s["value"])'
}

sha256_of() { printf '%s' "$1" | openssl dgst -sha256 -r | cut -d' ' -f1; }

# ------------------------------------------------------------- disable path
if [ "$DISABLE" = 1 ]; then
  step "Kill switch: stop the maintenance cron, close publishing and refuse new sends"
  if [ "$DRY" = 1 ]; then
    say "would run: supabase db query --remote -f <sql>  # configure_audio_maintenance_scheduler(null,false); audio_comment_config.enabled=false"
    say "would run: supabase secrets set --env-file <private temp file>  # TASKFOLD_AUDIO_COMMENTS_ENABLED=false, TASKFOLD_AUDIO_MAINTENANCE_ENABLED=false"
    exit 0
  fi
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-audio.XXXXXX")"
  {
    printf "select taskfold_private.configure_audio_maintenance_scheduler(null,false);\n"
    printf "update taskfold_private.audio_comment_config set enabled=false where singleton;\n"
  } > "$TMP/disable.sql"
  supabase db query --remote -f "$TMP/disable.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  printf 'TASKFOLD_AUDIO_COMMENTS_ENABLED=false\nTASKFOLD_AUDIO_MAINTENANCE_ENABLED=false\n' > "$TMP/disable.env"
  supabase secrets set --env-file "$TMP/disable.env" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "Maintenance cron deactivated, audio_comment_config.enabled=false and both function switches false."
  say "Functions stay deployed. Owners can still remove recordings and read their send history."
  exit 0
fi

# ---------------------------------------------------------- 1. read state
step "1/7 Read existing configuration (names and booleans only)"
EXISTING=""
VAULT_HAS=false
if [ "$DRY" = 1 ]; then
  say "would run: supabase secrets list  # names only; values/digests are never printed"
  say "would run: read-only SQL: does Vault hold $VAULT_NAME? (boolean)"
else
  EXISTING="$(secret_names)"
  VAULT_HAS="$(sb_query "select exists(select 1 from vault.secrets where name='$VAULT_NAME') as present" | python3 -c '
import json, sys
t = sys.stdin.read()
print("true" if json.loads(t[t.index("{"):])["rows"][0]["present"] else "false")')"
fi
has() { printf '%s\n' "$EXISTING" | grep -qx "$1"; }
for name in $SECRET_NAMES; do
  if [ "$DRY" = 1 ]; then say "  $name: (checked when run)"; else say "  $name: $(has "$name" && echo present || echo absent)"; fi
done
[ "$DRY" = 1 ] || say "  vault $VAULT_NAME: $VAULT_HAS"

# ------------------------------------------------------ 2. pending migrations
step "2/7 Push pending migrations (dry run first; includes $MIGRATION: cron every 15 minutes, stale upload fence)"
if [ "$DRY" = 1 ]; then
  say "would run: supabase db push --remote --dry-run --include-all  # lists pending migration files only"
  say "would run: supabase db push --remote --include-all ${SB_YES[*]:-}  # each migration file is wrapped in begin/commit"
else
  PENDING="$(supabase db push --remote --dry-run --include-all 2>&1)" || { printf '%s\n' "$PENDING" >&2; die "Migration dry run failed; nothing was pushed."; }
  LIST="$(printf '%s\n' "$PENDING" | grep -oE '[0-9]{14}_[A-Za-z0-9_]+(\.sql)?' | sort -u || true)"
  if [ -n "$LIST" ]; then
    printf '  pending: %s\n' $LIST
    supabase db push --remote --include-all ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
    say "  migrations pushed."
  else
    say "  no pending migrations."
  fi
fi

# ------------------------------------------------- 3. generate + set secrets
step "3/7 Generate the maintenance key and set the function secrets (never echoed)"
NEW_KEY=0
H_KEY=""
if [ "$DRY" = 1 ]; then
  say "would create a 0700 temp directory with mktemp and a 0600 env file in it"
  say "would add TASKFOLD_AUDIO_MAINTENANCE_KEY=<openssl rand -hex 32> if absent, if Vault lacks it, or with --rotate-key"
  say "would add TASKFOLD_AUDIO_COMMENTS_ENABLED=true and TASKFOLD_AUDIO_MAINTENANCE_ENABLED=true"
  say "would run: supabase secrets set --env-file <temp>/secrets.env ${SB_YES[*]:-}"
  say "would then compare the sha256 digest of the generated key with the stored digest (boolean only), and remove the temp directory"
else
  TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-audio.XXXXXX")"
  ENVFILE="$TMP/secrets.env"
  : > "$ENVFILE"
  if [ "$ROTATE" = 1 ] || ! has TASKFOLD_AUDIO_MAINTENANCE_KEY || [ "$VAULT_HAS" != true ]; then
    KEY="$(openssl rand -hex 32)" # exactly 64 lowercase hex characters, the form the scheduler and function require
    printf 'TASKFOLD_AUDIO_MAINTENANCE_KEY=%s\n' "$KEY" >> "$ENVFILE"
    H_KEY="$(sha256_of "$KEY")"
    # Vault copy for the cron-side HMAC proof, same value, never printed.
    {
      printf "do \$\$ declare sid uuid; begin\n"
      printf " select id into sid from vault.secrets where name='%s';\n" "$VAULT_NAME"
      printf " if sid is null then perform vault.create_secret('%s','%s','Taskfold audio maintenance HMAC key');\n" "$KEY" "$VAULT_NAME"
      printf " else perform vault.update_secret(sid,'%s');end if;\n" "$KEY"
      printf "end \$\$;\n"
    } > "$TMP/vault.sql"
    unset KEY
    NEW_KEY=1
    say "  maintenance key: generated (function secret + Vault)"
  else
    say "  maintenance key: keeping existing (present in function secrets and Vault)"
  fi
  printf 'TASKFOLD_AUDIO_COMMENTS_ENABLED=true\n' >> "$ENVFILE"
  printf 'TASKFOLD_AUDIO_MAINTENANCE_ENABLED=true\n' >> "$ENVFILE"
  supabase secrets set --env-file "$ENVFILE" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  secrets set."
  if [ -n "$H_KEY" ]; then
    [ "$(secret_digest TASKFOLD_AUDIO_MAINTENANCE_KEY)" = "$H_KEY" ] && say "  maintenance key stored intact: true" || die "Stored key digest differs from the generated value; stop and investigate."
  fi
fi

# ----------------------------------------------------------------- 4. vault
step "4/7 Store the maintenance key in Vault for the cron-side proof"
if [ "$DRY" = 1 ]; then
  say "would run: supabase db query --remote -f <temp>/vault.sql  # only when a new key was generated; the SQL file lives in the private temp directory"
elif [ "$NEW_KEY" = 1 ]; then
  supabase db query --remote -f "$TMP/vault.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  Vault secret $VAULT_NAME created/updated."
else
  say "  unchanged."
fi

# ------------------------------------------------------------ 5. functions
step "5/7 Deploy the two functions with the correct verify_jwt flags"
USE_API=()
if [ "$DRY" = 0 ] && ! docker info > /dev/null 2>&1; then
  USE_API=(--use-api)
  say "  Docker is not running: bundling server-side (--use-api)."
fi
for entry in $FUNCTIONS; do
  fn="${entry%%:*}"
  if [ "${entry##*:}" = no-verify ]; then
    flag=(--no-verify-jwt)
    why="scheduled HMAC proof, gateway JWT check OFF"
  else
    flag=()
    why="user session JWT, gateway JWT check ON"
  fi
  if [ "$DRY" = 1 ]; then
    say "would run: supabase functions deploy $fn ${flag[*]:-} ${SB_YES[*]:-}  # $why"
  else
    supabase functions deploy "$fn" ${flag[@]+"${flag[@]}"} ${USE_API[@]+"${USE_API[@]}"} ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
    say "  deployed $fn ($why)"
  fi
done

# ------------------------------------------- 6. scheduler, cron and the switch
step "6/7 Configure the scheduler row, activate the cron job and turn the personal switch on"
if [ "$DRY" = 1 ]; then
  say "would run: supabase db query --remote -f <temp>/enable.sql, one SQL file:"
  say "  select taskfold_private.configure_audio_maintenance_scheduler('$PROJECT_REF', true);  -- needs the Vault key; sets project_ref/enabled and cron.alter_job active for $CRON_JOB"
  say "  update taskfold_private.audio_comment_config set enabled=true$([ "$REVIEW" = 1 ] && echo ', audience_review_enabled=true' || true) where singleton;"
  say "  (team_publication_enabled, restoration_enabled and the project transfer/history switches are not touched)"
else
  [ -n "$TMP" ] || TMP="$(mktemp -d "${TMPDIR:-/tmp}/taskfold-audio.XXXXXX")"
  {
    printf "select taskfold_private.configure_audio_maintenance_scheduler('%s',true);\n" "$PROJECT_REF"
    if [ "$REVIEW" = 1 ]; then
      printf "update taskfold_private.audio_comment_config set enabled=true,audience_review_enabled=true where singleton;\n"
    else
      printf "update taskfold_private.audio_comment_config set enabled=true where singleton;\n"
    fi
  } > "$TMP/enable.sql"
  supabase db query --remote -f "$TMP/enable.sql" ${SB_YES[@]+"${SB_YES[@]}"} > /dev/null
  say "  scheduler configured; cron job $CRON_JOB active; audio_comment_config.enabled=true$([ "$REVIEW" = 1 ] && echo ', audience_review_enabled=true' || true)."
fi

# ------------------------------------------------------------- 7. status
step "7/7 Read-only status (names and booleans only)"
if [ "$DRY" = 1 ]; then
  say "would run: read-only SQL on audio_comment_config (booleans), taskfold_private.audio_maintenance_scheduler, cron.job (jobname/schedule/active only) and vault.secrets (name only)"
  say "would run: supabase secrets list (names only) and supabase functions list (slug/status/verify_jwt)"
  say "would print READY only if all three secrets exist, both functions are ACTIVE with the expected verify_jwt, the scheduler and cron are enabled on '$CRON_SCHEDULE',"
  say "  the personal switch is on and every team/restoration/transfer switch is still false; otherwise NOT READY"
  exit 0
fi
cleanup
TMP=""
OFF_SQL=""
for f in $OFF_FLAGS; do OFF_SQL="$OFF_SQL,'$f',c.$f"; done
STATUS_JSON="$(sb_query "select jsonb_build_object('scheduler_enabled',s.enabled,'scheduler_project_ref_set',s.project_ref is not null,'scheduler_state',s.last_state,'cron_job_exists',exists(select 1 from cron.job where jobname='$CRON_JOB'),'cron_job_active',coalesce((select active from cron.job where jobname='$CRON_JOB'),false),'cron_schedule',(select schedule from cron.job where jobname='$CRON_JOB'),'vault_key_present',exists(select 1 from vault.secrets where name='$VAULT_NAME'),'config_enabled',c.enabled,'config_audience_review_enabled',c.audience_review_enabled$OFF_SQL) as status from taskfold_private.audio_maintenance_scheduler s,taskfold_private.audio_comment_config c")"
SECRETS_PRESENT="$(secret_names)"
FUNCTIONS_JSON="$(supabase functions list --output-format json)"
STATUS_JSON="$STATUS_JSON" SECRETS_PRESENT="$SECRETS_PRESENT" FUNCTIONS_JSON="$FUNCTIONS_JSON" \
  WANT_SECRETS="$SECRET_NAMES" WANT_FUNCTIONS="$FUNCTIONS" OFF_FLAGS="$OFF_FLAGS" WANT_SCHEDULE="$CRON_SCHEDULE" WANT_REVIEW="$REVIEW" python3 - << 'PY'
import json, os
def load(t): return json.loads(t[t.index("{"):])
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
for k in ("scheduler_enabled", "scheduler_project_ref_set", "cron_job_exists", "cron_job_active", "vault_key_present"):
    print(f"  {k}: {status[k]}"); ok &= bool(status[k])
print(f"  scheduler_state: {status['scheduler_state']}")
sched_ok = status["cron_schedule"] == os.environ["WANT_SCHEDULE"]
print(f"  cron_every_15_minutes: {sched_ok}"); ok &= sched_ok
print("switches:")
print(f"  enabled (personal audio): {status['config_enabled']}"); ok &= bool(status["config_enabled"])
review = bool(status["config_audience_review_enabled"])
print(f"  audience_review_enabled (needed to publish): {review}")
if os.environ["WANT_REVIEW"] == "1": ok &= review
for name in os.environ["OFF_FLAGS"].split():
    print(f"  {name}: {status[name]} (must stay false)"); ok &= status[name] is False
print("\nREADY" if ok else "\nNOT READY: review the false values above")
PY

#!/bin/zsh
# Credential-free provider/queue transport fixtures; no database or push-provider requests.
set -euo pipefail
cd "$(dirname "$0")/.."
taskfold_deno="${TASKFOLD_DENO_BIN:-$(command -v deno || true)}"
if [[ -z "$taskfold_deno" && -x "$HOME/.deno/bin/deno" ]]; then
  taskfold_deno="$HOME/.deno/bin/deno"
fi
if [[ -z "$taskfold_deno" ]]; then
  print -u2 'Deno is required. Set TASKFOLD_DENO_BIN to its executable.'
  exit 1
fi
"$taskfold_deno" test --no-config supabase/functions/check-due-tasks/handler_test.ts supabase/functions/dispatch-reminders/delivery_test.ts
"$taskfold_deno" check --no-config supabase/functions/check-due-tasks/index.ts supabase/functions/dispatch-reminders/index.ts
"$taskfold_deno" lint --no-config supabase/functions/dispatch-reminders
"$taskfold_deno" fmt --check --no-config supabase/functions/dispatch-reminders

# Operator preparation — source candidate, not a rollout instruction

No hosted action in this file has been performed. Accept this on an isolated
Supabase test project with synthetic data before enabling it for normal work.
Both repositories own the same migration identities; apply a shared backend's
migration once through its history, not independently twice for each app binary.

1. Review/apply the preceding audio migrations and these two additions:
   `20261028153218_audio_comment_upload_recovery.sql` and
   `20261028153219_audio_comment_maintenance_scheduler.sql`. The target needs the
   existing Storage schema/RLS and `pg_cron`, `pg_net`, Vault and pgcrypto dependencies.
   The migration creates the minute cron job **inactive**. Confirm its owner and
   command; no function URL or credential belongs in the cron command.
2. Prepare a dedicated random 32-byte key represented as 64 lowercase hex
   characters. Put it in Vault as `taskfold_audio_maintenance_key` and in the Edge
   environment as `TASKFOLD_AUDIO_MAINTENANCE_KEY`. Keep the value out of source,
   command history/logs and native app configuration. The function also needs its
   usual server-only Supabase URL/service credential environment.
3. For this maintenance function only, the deployment command needs
   `--no-verify-jwt`, because scheduled HMAC proofs are not JWTs. Its handler now
   authenticates the project-bound signature and one-use SQL nonce itself. The
   normal `audio-comments` user function keeps platform JWT verification enabled.
   CLI 2.109.0 `supabase functions deploy --help` confirmed this flag:

   ```sh
   supabase functions deploy audio-comment-maintenance --project-ref "$TASKFOLD_TEST_PROJECT_REF" --no-verify-jwt
   ```

4. On the isolated project, configure the worker environment enable flag
   `TASKFOLD_AUDIO_MAINTENANCE_ENABLED=true`, then invoke the owner-only SQL
   `taskfold_private.configure_audio_maintenance_scheduler(project_ref, true)` with
   that project's exact 20-letter reference. The function verifies one valid Vault
   key and activates only its named job. Publication/native audio flags remain off.
5. Observe a genuine minute tick: Vault lookup, committed pg_net delivery, HMAC and
   one-use admission, bounded probe/recovery/delete/absence verification and quota
   state. Check the private scheduler's transport health and response counts. Test
   cold/replayed/delayed requests, missing/corrupt late files, worker interruption,
   account removal/shared custody and actual provider deletion queues/versions.
   The local fixtures do not accept these provider behaviors.
6. Disable using owner-only
   `taskfold_private.configure_audio_maintenance_scheduler(null, false)` and the
   Edge enable flag. Disable clears unconsumed nonces and deactivates the cron job;
   an invocation already admitted may finish its bounded sweep. For rotation,
   disable first, rotate the Vault and Edge key together, then configure/enable
   again. Do not clear upload fences merely to recover quota.

Uncertain uploads with absent/corrupt bytes need provider terminal-request evidence
or another accepted recovery flow before their quota can safely be released. This
runbook does not waive that requirement or the remaining native publication work.

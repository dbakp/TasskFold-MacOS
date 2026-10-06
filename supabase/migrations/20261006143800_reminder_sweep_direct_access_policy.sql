-- Explicit deny policy complements revoked client grants on the private scheduler state.
create policy reminder_sweep_no_client_access on taskfold_private.reminder_worker_cursor
for all to anon,authenticated using (false) with check (false);

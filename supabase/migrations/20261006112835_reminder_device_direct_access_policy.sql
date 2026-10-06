create policy no_direct_client_device_access on taskfold_private.reminder_devices for all to anon, authenticated using (false) with check (false);

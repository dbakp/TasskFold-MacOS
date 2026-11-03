-- Schedule cron job to check for due tasks every minute
SELECT cron.schedule(
  'check-due-tasks-every-minute',
  '* * * * *',
  $$
  SELECT net.http_post(
    url := 'https://zqxflydiyfjeedqvyova.supabase.co/functions/v1/check-due-tasks',
    headers := '{"Content-Type": "application/json", "Authorization": "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpxeGZseWRpeWZqZWVkcXZ5b3ZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjM0ODM2NDksImV4cCI6MjA3OTA1OTY0OX0.OjroyFdSajfuzUvO8N7wA1VntLd_dfnPnPDG1M06FKQ"}'::jsonb,
    body := '{}'::jsonb
  ) AS request_id;
  $$
);
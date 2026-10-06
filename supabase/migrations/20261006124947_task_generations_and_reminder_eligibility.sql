-- Each genuinely new/restored task gets a durable identity beyond its reusable row ID.
-- NULL identifies only rows that existed before this migration; their r3 alerts remain valid.
alter table public.tasks add column task_generation uuid;
create table taskfold_private.task_generations (
 user_id uuid not null references auth.users(id) on delete cascade,
 task_id uuid not null,
 generation uuid not null,
 eligible_at timestamptz not null,
 deleted_at timestamptz,
 primary key(task_id,generation)
);
alter table taskfold_private.task_generations enable row level security;
create policy no_direct_client_generation_access on taskfold_private.task_generations
 for all to anon,authenticated using(false) with check(false);
revoke all on taskfold_private.task_generations from public,anon,authenticated;
grant select,insert,update,delete on taskfold_private.task_generations to service_role;
create index task_generations_user on taskfold_private.task_generations(user_id);
-- The nil UUID is a private key for an existing legacy row, never a new public generation.
insert into taskfold_private.task_generations(user_id,task_id,generation,eligible_at)
 select user_id,id,'00000000-0000-0000-0000-000000000000',clock_timestamp() from public.tasks;

create function taskfold_private.guard_task_generation()
returns trigger language plpgsql security definer set search_path='' as $$
declare live public.tasks;
begin
 if tg_op='UPDATE' then
  if new.task_generation is null then new.task_generation:=old.task_generation; end if;
  if new.task_generation is distinct from old.task_generation then
   raise exception 'TASKFOLD_CONFLICT: Task identity changed. Review the synced task';
  end if;
  return new;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(new.id::text,78137));
 if new.task_generation is null then new.task_generation:=gen_random_uuid(); end if;
 if new.task_generation='00000000-0000-0000-0000-000000000000' then raise exception 'Invalid task identity'; end if;
 if exists(select 1 from taskfold_private.task_generations where task_id=new.id and generation=new.task_generation) then
  select * into live from public.tasks where id=new.id;
  -- An exact create-only retry may target a still-live generation. A deleted generation never returns.
  if not found or live.user_id is distinct from new.user_id or live.task_generation is distinct from new.task_generation then
   raise exception 'TASKFOLD_CONFLICT: This creation belongs to an earlier task. Review before restoring';
  end if;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.guard_task_generation() from public,anon,authenticated;
create trigger taskfold_guard_generation before insert or update on public.tasks
 for each row execute function taskfold_private.guard_task_generation();

create function taskfold_private.record_task_generation()
returns trigger language plpgsql security definer set search_path='' as $$
declare g uuid;
begin
 if tg_op='DELETE' then
  update taskfold_private.task_generations set deleted_at=clock_timestamp()
   where task_id=old.id and generation=coalesce(old.task_generation,'00000000-0000-0000-0000-000000000000');
  return old;
 end if;
 g:=coalesce(new.task_generation,'00000000-0000-0000-0000-000000000000');
 if tg_op='INSERT' then
  insert into taskfold_private.task_generations(user_id,task_id,generation,eligible_at)
   values(new.user_id,new.id,g,clock_timestamp());
 elsif row(new.completed,new.completed_at,new.due_date,new.due_time,new.time_zone,new.scheduled_at,new.reminder_specs)
   is distinct from row(old.completed,old.completed_at,old.due_date,old.due_time,old.time_zone,old.scheduled_at,old.reminder_specs) then
  update taskfold_private.task_generations set eligible_at=clock_timestamp()
   where task_id=new.id and generation=g;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.record_task_generation() from public,anon,authenticated;
create trigger taskfold_record_generation after insert or update or delete on public.tasks
 for each row execute function taskfold_private.record_task_generation();

-- The read-only remote activation epoch is continuous through same-account token refreshes.
-- Re-enabling, switching account, or changing the device time zone starts a new catch-up window.
alter table taskfold_private.reminder_devices add column enabled_since timestamptz;
update taskfold_private.reminder_devices set enabled_since=clock_timestamp()
 where binding->>'enabled'='true' and binding->>'permission' in ('authorized','provisional');
create function taskfold_private.reminder_activation_epoch()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if coalesce(new.binding->>'enabled','false')<>'true' or coalesce(new.binding->>'permission','') not in ('authorized','provisional') then
  new.enabled_since:=null;
 elsif tg_op='INSERT' then new.enabled_since:=clock_timestamp();
 elsif old.enabled_since is null or new.user_id is distinct from old.user_id
   or new.binding->>'time_zone' is distinct from old.binding->>'time_zone' then new.enabled_since:=clock_timestamp();
 else new.enabled_since:=old.enabled_since;
 end if;
 return new;
end $$;
revoke all on function taskfold_private.reminder_activation_epoch() from public,anon,authenticated;
-- Run after the owner/session retirement normalizer, which can clear the binding.
create trigger zz_reminder_activation_epoch before insert or update on taskfold_private.reminder_devices
 for each row execute function taskfold_private.reminder_activation_epoch();

-- Accepted jobs survive task deletion for the existing eight-day receipt retention window.
-- Missing tasks fail current-event validation; no content or APNs token is retained in receipts.
alter table taskfold_private.reminder_jobs drop constraint reminder_jobs_task_id_fkey;
alter table taskfold_private.reminder_jobs drop constraint reminder_jobs_signature_check;
alter table taskfold_private.reminder_jobs add constraint reminder_jobs_signature_check check(signature ~ '^r[34]:[0-9a-f]{64}$');

CREATE OR REPLACE FUNCTION public.taskfold_patch_task(_id uuid, _base jsonb, _changes jsonb)
 RETURNS tasks
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare t public.tasks; merged jsonb; k text; base_value jsonb; desired_value jsonb; remote_value jsonb; allowed text[] := array['title','description','completed','priority','due_date','due_time','project_id','section_id','labels','subtasks','reminders','attachments','comments','completed_at','recurrence_pattern','is_recurring','recurrence_parent_id','recurrence_end_date','notification_sent_at','assigned_to','deadline_date','duration_minutes','time_zone','reminder_specs','source_metadata','scheduled_at'];
begin
 if auth.uid() is null then raise exception 'Sign in to edit tasks'; end if;
 select * into t from public.tasks where id = _id for update;
 if not found then raise exception 'This task is no longer available or you no longer have access. Your edit is saved locally.'; end if;
 if _changes is null or _base is null or jsonb_typeof(_changes) <> 'object' or jsonb_typeof(_base) <> 'object' then raise exception 'Invalid edit'; end if;
 if t.task_generation is distinct from (_base->>'task_generation')::uuid then
  raise exception 'TASKFOLD_CONFLICT: This edit belongs to an earlier task. Review the synced version';
 end if;
 merged := to_jsonb(t);
 -- Completion revisions detect an intervening complete/reopen cycle even when
 -- the visible values returned to their baseline. Old clients remain compatible;
 -- new native queues require the revision and send it only in the baseline.
 if _changes ?| array['completed','completed_at'] and _base ? 'completion_version' then
  if jsonb_typeof(_base->'completion_version') <> 'number'
     or (_base->>'completion_version')::numeric <> trunc((_base->>'completion_version')::numeric)
     or (_base->>'completion_version')::numeric < 0 then
   raise exception 'TASKFOLD_CONFLICT: Review this completion before replacing synced state';
  end if;
  if t.completion_version <> (_base->>'completion_version')::bigint then
   -- Only the immediately following revision with identical desired completion
   -- values is a lost-response retry. A later cycle can never be mistaken for it.
   if t.completion_version <> (_base->>'completion_version')::bigint + 1
      or (_changes ? 'completed' and t.completed is distinct from (_changes->>'completed')::boolean)
      or (_changes ? 'completed_at' and t.completed_at is distinct from (_changes->>'completed_at')::timestamptz) then
    raise exception 'TASKFOLD_CONFLICT: Completion changed on another device. Review the synced task';
   end if;
  end if;
 end if;

 for k in select jsonb_object_keys(_changes) loop
   if not k = any(allowed) then raise exception 'This task field cannot be edited'; end if;
   if not _base ? k then raise exception 'An edit baseline is required'; end if;
   base_value := _base->k; desired_value := _changes->k; remote_value := merged->k;
   -- Native queues use Z, PostgREST returns +00:00. Compare instants, not JSON spelling.
   -- Real concurrent changes (including different DST folds) must still conflict.
   if k = any(array['scheduled_at','completed_at','notification_sent_at']) then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::timestamptz); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::timestamptz); end if;
   elsif k = 'due_time' then
    if jsonb_typeof(base_value) = 'string' then base_value := to_jsonb((base_value#>>'{}')::time); end if;
    if jsonb_typeof(desired_value) = 'string' then desired_value := to_jsonb((desired_value#>>'{}')::time); end if;
    if jsonb_typeof(remote_value) = 'string' then remote_value := to_jsonb((remote_value#>>'{}')::time); end if;
   end if;
   merged := jsonb_set(merged, array[k], coalesce(taskfold_private.merge_edit(base_value, desired_value, remote_value), 'null'));
 end loop;
 t := jsonb_populate_record(t, merged);
 update public.tasks set title=t.title,description=t.description,completed=t.completed,priority=t.priority,due_date=t.due_date,due_time=t.due_time,project_id=t.project_id,section_id=t.section_id,labels=t.labels,subtasks=t.subtasks,reminders=t.reminders,attachments=t.attachments,comments=t.comments,completed_at=t.completed_at,recurrence_pattern=t.recurrence_pattern,is_recurring=t.is_recurring,recurrence_parent_id=t.recurrence_parent_id,recurrence_end_date=t.recurrence_end_date,notification_sent_at=t.notification_sent_at,assigned_to=t.assigned_to,deadline_date=t.deadline_date,duration_minutes=t.duration_minutes,time_zone=t.time_zone,reminder_specs=t.reminder_specs,source_metadata=t.source_metadata,scheduled_at=t.scheduled_at where id=_id returning * into t;
 return t;
end $function$;

revoke all on function public.taskfold_patch_task(uuid,jsonb,jsonb) from public, anon;
grant execute on function public.taskfold_patch_task(uuid,jsonb,jsonb) to authenticated;


create or replace function taskfold_private.reminder_events(t jsonb, device_zone text)
returns table(spec_id uuid,fire_at timestamptz,signature text) language plpgsql stable security invoker set search_path = '' as $$
declare specs jsonb; s jsonb; seen uuid[]:='{}'; sid uuid; kind text; anchor timestamptz; absolute_at timestamptz;
 zone text; local_day date; local_clock time; planned timestamp; saved timestamptz; minutes numeric; channels text; fields text[]; preimage text; v text; cycle numeric; generation text; prefix text;
begin
 if t->>'completed'='true' then return; end if;
 generation:=lower(coalesce(t->>'task_generation',''));
 if generation<>'' and generation !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then return; end if;
 prefix:=case when generation='' then 'r3:' else 'r4:' end;
 cycle:=coalesce((t->>'completion_version')::numeric,0);
 if cycle<>trunc(cycle) or cycle not between 0 and 9007199254740991 then return; end if;
 specs:=coalesce(t->'reminder_specs','[]'::jsonb);
 if jsonb_typeof(specs)<>'array' then return; end if;
 if specs='[]'::jsonb then specs:='[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":true}]'; end if;
 for s in select value from jsonb_array_elements(specs) with ordinality where ordinality<=20 loop
  if jsonb_typeof(s)<>'object' or s->'version'<>'1'::jsonb or s->'version' is null or coalesce(s->>'id','') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$'
   or (s ? 'enabled' and jsonb_typeof(s->'enabled')<>'boolean') then continue; end if;
  if jsonb_typeof(s->'channels')<>'array' or s->'channels' is null then continue; end if;
  if jsonb_array_length(s->'channels')=0 or exists(select 1 from jsonb_array_elements(s->'channels') c where jsonb_typeof(c)<>'string' or c#>>'{}' not in ('local','push','email')) then continue; end if;
  kind:=s->>'kind'; minutes:=null; absolute_at:=null;
  if kind='relative' then
   if s->>'anchor'<>'planned' or s->>'anchor' is null or jsonb_typeof(s->'offset_minutes')<>'number' or s->'offset_minutes' is null then continue; end if;
   minutes:=(s->>'offset_minutes')::numeric;
   if minutes<>trunc(minutes) or minutes not between -10080 and 10080 then continue; end if;
  elsif kind='absolute' then
   if jsonb_typeof(s->'at')<>'string' or s->'at' is null or coalesce(s->>'at','') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$'
     or not exists(select 1 from pg_catalog.pg_timezone_names where name=s->>'time_zone') then continue; end if;
   begin absolute_at:=date_trunc('milliseconds',(s->>'at')::timestamptz); exception when others then continue; end;
  else continue; end if;
  sid:=(s->>'id')::uuid;
  if sid='00000000-0000-4000-8000-000000000001' and (kind<>'relative' or minutes<>0) then continue; end if;
  if sid=any(seen) then continue; end if;
  seen:=array_append(seen,sid);
  if s->>'enabled'='false' or not (s->'channels' ?| array['local','push']) then continue; end if;
  if kind='absolute' then fire_at:=absolute_at;
  else
   if coalesce(t->>'due_date','')='' then continue; end if;
   begin local_day:=(t->>'due_date')::date; exception when others then continue; end;
   if coalesce(t->>'due_time','')='' then local_clock:='08:00'; zone:=device_zone;
   else
    begin local_clock:=date_trunc('minute',(t->>'due_time')::interval)::time; exception when others then continue; end;
    zone:=coalesce(nullif(t->>'time_zone',''),device_zone);
   end if;
   planned:=local_day+local_clock;
   anchor:=taskfold_private.reminder_wall_time(planned,zone);
   if coalesce(t->>'time_zone','')<>'' and coalesce(t->>'due_time','')<>'' and coalesce(t->>'scheduled_at','')<>'' then
    begin saved:=date_trunc('milliseconds',(t->>'scheduled_at')::timestamptz);
     if date_trunc('minute',timezone(zone,saved))=planned then anchor:=saved; end if;
    exception when others then null; end;
   end if;
   if anchor is null then continue; end if;
   fire_at:=anchor+minutes*interval '1 minute';
  end if;
  select string_agg(c#>>'{}',',' order by c#>>'{}' collate "C") into channels from jsonb_array_elements(s->'channels') c;
  fields:=array[case when generation='' then 'taskfold.reminder.v3' else 'taskfold.reminder.v4' end,lower(t->>'id'),sid::text,kind,case when kind='relative' then 'planned' else '' end,
    case when kind='relative' then trunc(minutes)::bigint::text else '' end,
    case when kind='absolute' then round(extract(epoch from absolute_at)*1000)::bigint::text else '' end,
    case when kind='absolute' then s->>'time_zone' else '' end,channels,'1',round(extract(epoch from fire_at)*1000)::bigint::text,cycle::bigint::text];
  if generation<>'' then fields:=array_append(fields,generation); end if;
  preimage:=''; foreach v in array fields loop preimage:=preimage||octet_length(v)::text||':'||v; end loop;
  signature:=prefix||encode(extensions.digest(preimage,'sha256'),'hex'); spec_id:=sid; return next;
 end loop;
end $$;
revoke all on function taskfold_private.reminder_events(jsonb,text) from public,anon,authenticated;


create or replace function taskfold_private.reconcile_reminder_jobs(_device uuid)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare d taskfold_private.reminder_devices; n int; cutoff timestamptz:=clock_timestamp();
begin
 perform pg_advisory_xact_lock(hashtextextended(_device::text,78136));
 select * into d from taskfold_private.reminder_devices where id=_device for update;
 if not found then return jsonb_build_object('queued',0); end if;
 update taskfold_private.reminder_jobs j set state='cancelled',outcome='obsolete',lease_token=null,lease_until=null,updated_at=cutoff
  where device_id=_device and state in ('pending','leased') and not taskfold_private.reminder_job_current(j);
 if d.expires_at<=cutoff or not taskfold_private.reminder_session_live(d.session_id,d.user_id)
   or coalesce(d.binding->>'enabled','false')<>'true' or d.binding->>'permission' not in ('authorized','provisional') then return jsonb_build_object('queued',0); end if;
 insert into taskfold_private.reminder_jobs(id,device_id,user_id,task_id,spec_id,signature,fire_at,device_revision,next_attempt)
 select encode(extensions.digest(d.user_id::text||'|'||d.id::text||'|'||t.id::text||'|'||e.spec_id::text||'|'||e.signature,'sha256'),'hex'),
  d.id,d.user_id,t.id,e.spec_id,e.signature,e.fire_at,d.revision,e.fire_at
 from public.tasks t join taskfold_private.task_generations g on g.task_id=t.id and g.user_id=t.user_id
  and g.generation=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000')
 cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
 where t.user_id=d.user_id and not t.completed and (t.due_date is not null or t.reminder_specs<>'[]'::jsonb)
  and (t.project_id is null or public.has_project_access(d.user_id,t.project_id)) and e.fire_at>=g.eligible_at and e.fire_at>=d.enabled_since and e.fire_at between cutoff-interval '1 hour' and cutoff+interval '7 days'
 on conflict(id) do update set device_revision=excluded.device_revision,state='pending',outcome=null,lease_token=null,lease_until=null,next_attempt=excluded.fire_at,updated_at=cutoff
  where reminder_jobs.state='cancelled' and reminder_jobs.fire_at>cutoff;
 get diagnostics n=row_count;
 return jsonb_build_object('queued',n);
end $$;


create or replace function taskfold_private.reminder_job_current(j taskfold_private.reminder_jobs)
returns boolean language sql stable security invoker set search_path = '' as $$
 select exists(select 1 from taskfold_private.reminder_devices d
  join public.tasks t on t.id=j.task_id and t.user_id=d.user_id
  join taskfold_private.task_generations g on g.task_id=t.id and g.user_id=t.user_id
   and g.generation=coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000')
  cross join lateral taskfold_private.reminder_events(to_jsonb(t),d.binding->>'time_zone') e
  where d.id=j.device_id and d.user_id=j.user_id and d.revision=j.device_revision and d.expires_at>now()
   and taskfold_private.reminder_session_live(d.session_id,d.user_id) and d.binding->>'enabled'='true' and d.binding->>'permission' in ('authorized','provisional')
   and (t.project_id is null or public.has_project_access(d.user_id,t.project_id))
   and e.fire_at>=g.eligible_at and e.fire_at>=d.enabled_since
   and e.spec_id=j.spec_id and e.signature=j.signature and e.fire_at=j.fire_at)
$$;


-- Removing the task must cancel a leased job immediately, while retaining terminal receipts.
drop trigger taskfold_cancel_task_jobs on public.tasks;
create trigger taskfold_cancel_task_jobs after update or delete on public.tasks
 for each row execute function taskfold_private.cancel_obsolete_reminder_jobs();

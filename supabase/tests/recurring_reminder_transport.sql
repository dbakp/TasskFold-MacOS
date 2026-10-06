-- Isolated version-2 native calendar-reminder transport. Every fixture rolls back.
-- No scheduler activation, device registration, provider dispatch or schema mutation.
begin;
insert into auth.users(id,email,raw_user_meta_data) values
 ('f0621000-0000-4000-8000-000000000001','taskfold-calendar-reminder-owner@example.invalid','{}'),
 ('f0621000-0000-4000-8000-000000000002','taskfold-calendar-reminder-outsider@example.invalid','{}');
select set_config('request.jwt.claim.sub','f0621000-0000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare t public.tasks; original jsonb; changed jsonb; begin
 original := '[{"version":2,"id":"f0621000-0000-4000-8000-000000000011","kind":"recurring","enabled":true,"channels":["local"],"start_day":"2026-10-10","time":"09:00","time_zone":"Europe/Copenhagen","recurrence":{"type":"weekly","interval":1,"daysOfWeek":[6],"count":5,"future_rule":"preserve"},"future_setting":{"accent":"plum"}},{"version":99,"id":"f0621000-0000-4000-8000-000000000012","future":"preserve"}]'::jsonb;
 insert into public.tasks(id,user_id,title,reminder_specs)
 values('f0621000-0000-4000-8000-000000000010',auth.uid(),'Independent calendar reminder fixture',original) returning * into t;
 if t.reminder_specs <> original or t.due_date is not null or t.due_time is not null then raise exception 'Insert lost calendar settings or invented a plan'; end if;
 changed := jsonb_set(original,'{0,time}','"10:30"');
 t := public.taskfold_patch_task(t.id,to_jsonb(t),jsonb_build_object('reminder_specs',changed));
 if t.reminder_specs <> changed then raise exception 'First native edit changed unknown metadata'; end if;
 -- Another native reader may edit an unrelated field using its earlier baseline.
 t := public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'description',null),'{"description":"Independent second-client note"}');
 if t.reminder_specs <> changed then raise exception 'Second client erased the calendar schedule'; end if;
 t := public.taskfold_patch_task(t.id,to_jsonb(t),'{"due_date":"2026-11-01","due_time":"15:00"}');
 if t.reminder_specs <> changed then raise exception 'Rescheduling the task moved the independent reminder'; end if;
 begin
  perform public.taskfold_patch_task(t.id,jsonb_build_object('task_generation',t.task_generation,'reminder_specs',original),jsonb_build_object('reminder_specs',jsonb_set(original,'{0,time}','"11:00"')));
  raise exception 'Stale reminder edit overwrote a newer rule';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise; end if; end;
end $$;
select set_config('request.jwt.claim.sub','f0621000-0000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.tasks where id='f0621000-0000-4000-8000-000000000010') then raise exception 'Outsider read calendar schedule'; end if;
 begin
  perform public.taskfold_patch_task('f0621000-0000-4000-8000-000000000010','{}','{"reminder_specs":[]}');
  raise exception 'Outsider erased calendar schedule';
 exception when others then if sqlerrm not like 'This task is no longer available%' then raise; end if; end;
end $$;
reset role;
do $$ declare t jsonb; begin
 select to_jsonb(x) into t from public.tasks x where id='f0621000-0000-4000-8000-000000000010';
 if t->'reminder_specs'->0->>'time'<>'10:30' or t->>'description'<>'Independent second-client note' then raise exception 'Conflict or outsider modified calendar settings'; end if;
 -- Version 2 is local-only. The disabled remote worker's v1 projector skips it,
 -- retaining it in task JSON without a false implicit planned-time fallback.
 if exists(select 1 from taskfold_private.reminder_events(t,'Europe/Copenhagen')) then raise exception 'Remote projector scheduled a local-only future capability'; end if;
end $$;
rollback;
select 'Calendar reminder JSON preserved across native guarded edits, independent planning, conflicts and RLS; legacy single-event projector safely skips v2; all fixtures rolled back' as result;

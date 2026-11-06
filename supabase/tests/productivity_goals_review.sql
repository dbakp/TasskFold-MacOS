begin;
insert into auth.users(id,email) values
 ('f1731000-0000-4000-8000-000000000001','insights-goal-owner@example.invalid'),
 ('f1731000-0000-4000-8000-000000000002','insights-goal-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','f1731000-0000-4000-8000-000000000001',true);
do $$ declare a jsonb := '{"version":1,"daily_target":5,"weekly_target":20,"active_weekdays":[2,3,4,5,6],"week_start":2,"time_zone":"Europe/Copenhagen","metadata":{"preserve":true}}';b jsonb;saved jsonb;bad jsonb;begin
 saved=public.taskfold_set_productivity_goals(null,a);
 if saved->>'user_id'<>'f1731000-0000-4000-8000-000000000001' or saved->>'id'<>'insights' or saved->'productivity_goals' is distinct from a then raise exception 'Initial save failed';end if;
 perform public.taskfold_set_productivity_goals(null,a);
 b=jsonb_set(a,'{daily_target}','6');saved=public.taskfold_set_productivity_goals(a,b);
 begin
  perform public.taskfold_set_productivity_goals(a,jsonb_set(a,'{weekly_target}','25'));raise exception 'Stale goal silently replaced newer setting';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise;end if;end;
 update public.view_preferences set sort_by='title' where id='insights';
 a=jsonb_set(b,'{weekly_target}','25');saved=public.taskfold_set_productivity_goals(b,a);
 if saved->'productivity_goals' is distinct from a or saved->>'sort_by'<>'title' or saved->'productivity_goals'->'metadata' is distinct from '{"preserve":true}'::jsonb then raise exception 'Reviewed save lost independent settings or metadata';end if;
 for bad in select x from (values
 (jsonb_set(a,'{daily_target}','-1')),(jsonb_set(a,'{weekly_target}','1.5')),(jsonb_set(a,'{week_start}','8')),
 (jsonb_set(a,'{active_weekdays}','[2,2]')),(jsonb_set(a,'{active_weekdays}','[]')),(jsonb_set(a,'{active_weekdays}','[1e100]')),
 (jsonb_set(a,'{active_weekdays}','{}')),(jsonb_set(a,'{time_zone}','"unavailable/zone"')),(jsonb_set(a,'{version}','2'))) sample(x) loop
  if taskfold_private.valid_productivity_goals(bad) then raise exception 'Invalid goal accepted';end if;
 end loop;
 begin
  update public.view_preferences set productivity_goals=jsonb_set(a,'{daily_target}','-1') where id='insights';raise exception 'Invalid direct update accepted';
 exception when check_violation then null;end;
 begin
  insert into public.view_preferences(user_id,id,productivity_goals) values(auth.uid(),'wrong-goal-scope',a);raise exception 'Wrong record scope accepted';
 exception when check_violation then null;end;
 saved=public.taskfold_set_productivity_goals(a,null);
 if saved->'productivity_goals' is distinct from 'null'::jsonb or saved->>'sort_by'<>'title' then raise exception 'Clear altered other preferences';end if;
 a=jsonb_set(jsonb_set(a,'{daily_target}','0'),'{active_weekdays}','[]');perform public.taskfold_set_productivity_goals(null,a);
end $$;
select set_config('request.jwt.claim.sub','f1731000-0000-4000-8000-000000000002',true);
do $$ declare saved jsonb;begin
 if exists(select 1 from public.view_preferences where user_id='f1731000-0000-4000-8000-000000000001') then raise exception 'Outsider read';end if;
 update public.view_preferences set productivity_goals=null where user_id='f1731000-0000-4000-8000-000000000001';
 if found then raise exception 'Outsider write';end if;
 saved=public.taskfold_set_productivity_goals(null,'{"version":1,"daily_target":1,"weekly_target":2,"active_weekdays":[2],"week_start":1,"time_zone":"UTC"}');
 if saved->>'user_id'<>'f1731000-0000-4000-8000-000000000002' then raise exception 'Setter wrote another owner';end if;
end $$;
reset role;
do $$ begin
 if has_function_privilege('anon','public.taskfold_set_productivity_goals(jsonb,jsonb)','execute') then raise exception 'Anonymous execution allowed';end if;
 if (select prosecdef from pg_proc where oid='public.taskfold_set_productivity_goals(jsonb,jsonb)'::regprocedure) then raise exception 'Setter bypasses RLS';end if;
end $$;
select jsonb_build_object('goals_role_fixture','passed','owner_and_outsider',true,'guarded_retry',true,'rollback_only',true) as result;
rollback;

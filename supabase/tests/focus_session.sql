-- Disposable owner/outsider fixtures; every change is rolled back.
begin;
insert into auth.users(id) values ('eea29d92-7f62-4d2e-aeb9-e9bda2d133cc'),('2536a430-a1b3-4a7d-9e2e-02fe63cfb67c');
insert into public.tasks(id,user_id,title,completed) values
('ea178ab0-3d43-4f46-a4cf-f8ed2e125832','eea29d92-7f62-4d2e-aeb9-e9bda2d133cc','Focus fixture',false),
('9cdd4537-7b89-4fef-a965-572e88cb81b7','eea29d92-7f62-4d2e-aeb9-e9bda2d133cc','Completed Focus fixture',true);
set local role authenticated;
set local request.jwt.claim.sub = 'eea29d92-7f62-4d2e-aeb9-e9bda2d133cc';
set local request.jwt.claims = '{"sub":"eea29d92-7f62-4d2e-aeb9-e9bda2d133cc","role":"authenticated"}';
do $$
declare s jsonb := '{"session_id":"686c69e2-d3d4-42d6-a9b1-e28e6e3c3bf3","task_id":"ea178ab0-3d43-4f46-a4cf-f8ed2e125832","duration_seconds":1500,"elapsed_ms":0,"started_at_ms":1791273600000,"changed_at_ms":1791273600000,"running_since_ms":1791273600000,"status":"running"}';
  r public.focus_sessions; retry public.focus_sessions; base jsonb; old_base jsonb; changed jsonb;
begin
  if not taskfold_private.valid_focus_state(s) then raise exception 'Valid state rejected'; end if;
  if taskfold_private.valid_focus_state(s || '{"elapsed_ms":1500001}') or taskfold_private.valid_focus_state(s || '{"extra":true}')
     or taskfold_private.valid_focus_state(s || '{"duration_seconds":61}') or taskfold_private.valid_focus_state(s || '{"running_since_ms":null}')
     or taskfold_private.valid_focus_state(s || '{"changed_at_ms":0}') or taskfold_private.valid_focus_state(s || '{"elapsed_ms":"0"}') then raise exception 'Malformed state accepted'; end if;
  r := public.taskfold_set_focus_session('{"revision":0,"action_id":null}','e52c840e-c5b2-4d09-923a-773af82f46d5',s);
  if r.revision <> 1 or r.state <> s then raise exception 'First start failed'; end if;
  retry := public.taskfold_set_focus_session('{"revision":0,"action_id":null}','e52c840e-c5b2-4d09-923a-773af82f46d5',s);
  if retry.revision <> 1 then raise exception 'Retry advanced revision'; end if;
  begin
    perform public.taskfold_set_focus_session('{"revision":0,"action_id":null}','e52c840e-c5b2-4d09-923a-773af82f46d5',s || '{"duration_seconds":1800}');
    raise exception 'Same action replaced another payload';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  old_base := jsonb_build_object('revision',r.revision,'action_id',r.action_id);
  changed := s || '{"status":"paused","elapsed_ms":30125,"changed_at_ms":1791273630125,"running_since_ms":null}';
  r := public.taskfold_set_focus_session(old_base,'a6f121aa-931a-4d6c-b5d8-b8d481391db7',changed);
  if r.revision <> 2 or r.state->>'elapsed_ms' <> '30125' then raise exception 'Pause lost elapsed'; end if;
  begin
    update public.focus_sessions set state=null where id='current';
    raise exception 'Blind REST update accepted';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  base := jsonb_build_object('revision',r.revision,'action_id',r.action_id);
  changed := changed || '{"status":"running","changed_at_ms":1791277200000,"running_since_ms":1791277200000}';
  r := public.taskfold_set_focus_session(base,'d8a8b457-1aa6-4883-9454-6c6a3d8c1476',changed);
  begin
    perform public.taskfold_set_focus_session(old_base,'23bd518c-5d08-4227-a006-1bb02fa8f650',s || '{"status":"paused","running_since_ms":null}');
    raise exception 'Stale device replaced a newer cycle';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  base := jsonb_build_object('revision',r.revision,'action_id',r.action_id);
  r := public.taskfold_set_focus_session(base,'f147558c-6c30-4e8c-a9f9-b48c265b53bf',null);
  if r.revision <> 4 or r.state is not null then raise exception 'Clear reset the counter'; end if;
  begin
    delete from public.focus_sessions where id='current';
    raise exception 'Client deleted revision tombstone';
  exception when insufficient_privilege then null; end;
  base := jsonb_build_object('revision',r.revision,'action_id',r.action_id);
  changed := s || '{"session_id":"a053caaf-10af-4357-a15b-63c8b2f779ae","task_id":"9cdd4537-7b89-4fef-a965-572e88cb81b7","status":"paused","running_since_ms":null}';
  r := public.taskfold_set_focus_session(base,'85aff5ca-241f-4e3e-9749-7f7feb396b44',changed);
  if r.revision <> 5 then raise exception 'Paused completed-task restore failed'; end if;
  base := jsonb_build_object('revision',r.revision,'action_id',r.action_id);
  begin
    perform public.taskfold_set_focus_session(base,'a45ad4f6-73b8-4d03-8d17-635025f92dd1',changed || '{"status":"running","running_since_ms":1791273600000}');
    raise exception 'Completed task resumed';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  begin
    perform public.taskfold_set_focus_session(base,'f80150ba-f0bd-4666-88a1-bc333a6bfce6',changed || '{"status":"running","task_id":"ea178ab0-3d43-4f46-a4cf-f8ed2e125832","running_since_ms":1791273600000}');
    raise exception 'Resume switched task without a new session';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  if not exists(select 1 from public.tasks where id='ea178ab0-3d43-4f46-a4cf-f8ed2e125832' and not completed) then raise exception 'Timer modified task completion'; end if;
  delete from public.tasks where id='9cdd4537-7b89-4fef-a965-572e88cb81b7';
  begin
    perform public.taskfold_set_focus_session(base,'f95a9f02-cc5d-40bb-9c91-b15b2c685db3',changed || '{"status":"running","running_since_ms":1791273600000}');
    raise exception 'Removed task resumed';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
end $$;
set local request.jwt.claim.sub = '2536a430-a1b3-4a7d-9e2e-02fe63cfb67c';
set local request.jwt.claims = '{"sub":"2536a430-a1b3-4a7d-9e2e-02fe63cfb67c","role":"authenticated"}';
do $$
declare r public.focus_sessions;
begin
  if exists(select 1 from public.focus_sessions) then raise exception 'Foreign session visible'; end if;
  begin
    insert into public.focus_sessions(user_id,id) values('eea29d92-7f62-4d2e-aeb9-e9bda2d133cc','current');
    raise exception 'Foreign insert accepted';
  exception when insufficient_privilege then null; end;
  begin
    perform public.taskfold_set_focus_session('{"revision":0,"action_id":null}','54a6fc2b-d0df-46b6-9d9a-1313a4b95189','{"session_id":"f8e39f70-bc0d-48fa-b8d1-a38647623b38","task_id":"ea178ab0-3d43-4f46-a4cf-f8ed2e125832","duration_seconds":1500,"elapsed_ms":0,"started_at_ms":1791273600000,"changed_at_ms":1791273600000,"running_since_ms":1791273600000,"status":"running"}');
    raise exception 'Foreign task bound to session';
  exception when others then if sqlerrm not like 'TASKFOLD_FOCUS_CONFLICT:%' then raise; end if; end;
  if exists(select 1 from public.focus_sessions) then raise exception 'Failed start left a slot'; end if;
  r := public.taskfold_set_focus_session('{"revision":0,"action_id":null}','6514a66e-a674-4f3e-b2a6-119b32cfe3e1',null);
  if r.user_id <> '2536a430-a1b3-4a7d-9e2e-02fe63cfb67c' or r.revision <> 1 then raise exception 'RPC did not scope owner'; end if;
  update public.focus_sessions set revision=revision+1,action_id='77047166-15c7-4bdb-ae27-7ff228313c52' where user_id='eea29d92-7f62-4d2e-aeb9-e9bda2d133cc';
end $$;
set local request.jwt.claim.sub = 'eea29d92-7f62-4d2e-aeb9-e9bda2d133cc';
set local request.jwt.claims = '{"sub":"eea29d92-7f62-4d2e-aeb9-e9bda2d133cc","role":"authenticated"}';
do $$ begin
  if (select count(*) from public.focus_sessions) <> 1 or (select revision from public.focus_sessions where id='current') <> 5 then raise exception 'Outsider changed owner session'; end if;
  if has_table_privilege('anon','public.focus_sessions','SELECT') or has_function_privilege('anon','public.taskfold_set_focus_session(jsonb,uuid,jsonb)','EXECUTE') then raise exception 'Anonymous access granted'; end if;
end $$;
select 'Focus owner isolation, strict clocks, retry, guarded revisions, stale cycles and paused restore passed; rolled back' as result;
rollback;

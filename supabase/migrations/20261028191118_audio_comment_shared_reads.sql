-- Separate media viewing from the unchanged publication/removal authority.
create function taskfold_private.audio_read_scope(a uuid,t uuid,g uuid,p uuid) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare task public.tasks;team uuid;begin
 select * into task from public.tasks where id=t and task_generation=g and project_id is not distinct from p for share;
 if not found or coalesce(to_jsonb(task)->'is_heading','false'::jsonb) not in('false'::jsonb,'null'::jsonb) then return false;end if;
 if not taskfold_private.is_team_content_task(t) then return taskfold_private.audio_scope(a,t,g,p,false);end if;
 if p is null or not coalesce((select native_reads_enabled from taskfold_private.team_project_config where singleton),false) then return false;end if;
 select team_id into team from taskfold_private.team_content_projects where project_id=p for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.teams where id=team and state<>'deleted' for share;if not found then return false;end if;
 perform 1 from taskfold_private.team_members where team_id=team and user_id=a for share;if not found then return false;end if;
 perform 1 from taskfold_private.team_project_grants where project_id=p and user_id=a for share;
 perform 1 from taskfold_private.team_content_tasks where task_id=t and generation=g and project_id=p and team_id=team for share;if not found then return false;end if;
 return coalesce(taskfold_private.team_project_role(a,p) in('manager','editor','viewer'),false);
end$$;
revoke all on function taskfold_private.audio_read_scope(uuid,uuid,uuid,uuid) from public,anon,authenticated,service_role;
create function taskfold_private.audio_read_comment(a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare id uuid;original taskfold_private.audio_comment_publications;current_row taskfold_private.audio_comment_publications;begin
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) then return jsonb_build_object('status','disabled');end if;
 perform taskfold_private.audio_fields(b,array['comment_id']);id=taskfold_private.audio_uuid(b,'comment_id');
 select * into original from taskfold_private.audio_comment_publications where comment_id=id;
 if not found then return jsonb_build_object('status','unavailable');end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||original.task_id::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_read_scope(a,original.task_id,original.task_generation,original.project_id),false) then return jsonb_build_object('status','unavailable');end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-operation:'||original.operation_id::text,20261028));
 select * into current_row from taskfold_private.audio_comment_publications where operation_id=original.operation_id and comment_id=id and task_id=original.task_id and task_generation=original.task_generation and project_id is not distinct from original.project_id and state='published' for share;
 if not found then return jsonb_build_object('status','unavailable');end if;
 return taskfold_private.audio_receipt(current_row,a);
end$$;
revoke all on function taskfold_private.audio_read_comment(uuid,uuid,jsonb) from public,anon,authenticated,service_role;
alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_before_shared_reads;
revoke all on function taskfold_private.audio_comment_before_shared_reads(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' as $$begin
 if action='read' then return taskfold_private.audio_read_comment(a,s,b);end if;
 return taskfold_private.audio_comment_before_shared_reads(action,a,s,b);
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;

create or replace function taskfold_private.audio_comment_page(a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare target jsonb;cursor_value jsonb;t uuid;g uuid;p uuid;stamp timestamptz;id uuid;rows jsonb;next_value jsonb;begin
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) or not taskfold_private.audio_bucket_ready() then return jsonb_build_object('status','disabled');end if;
 perform taskfold_private.audio_fields(b,array['target','after']);target=b->'target';perform taskfold_private.audio_target(target);
 t=taskfold_private.audio_uuid(target,'task_id');g=taskfold_private.audio_uuid(target,'task_generation');p=taskfold_private.audio_uuid(target,'project_id',true);
 cursor_value=b->'after';
 if cursor_value<>'null'::jsonb then
  perform taskfold_private.audio_fields(cursor_value,array['published_at','comment_id']);id=taskfold_private.audio_uuid(cursor_value,'comment_id');
  if jsonb_typeof(cursor_value->'published_at') is distinct from 'string' or length(cursor_value->>'published_at')>40
   or (cursor_value->>'published_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$' then raise exception using errcode='22023',message='Review this recording position';end if;
  stamp=(cursor_value->>'published_at')::timestamptz;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_read_scope(a,t,g,p),false) then return jsonb_build_object('status','unavailable');end if;
 -- Existing published-only (task,generation,published_at,comment_id) index serves
 -- the seek and order. One lookahead row determines whether a next page exists.
 select coalesce(jsonb_agg(taskfold_private.audio_receipt(q,a) order by q.published_at,q.comment_id),'[]'::jsonb) into rows from
  (select * from taskfold_private.audio_comment_publications where task_id=t and task_generation=g and project_id is not distinct from p and state='published'
   and (stamp is null or (published_at,comment_id)>(stamp,id)) order by published_at,comment_id limit 21) q;
 next_value='null'::jsonb;
 if jsonb_array_length(rows)>20 then
  next_value=jsonb_build_object('published_at',rows->19->'published_at','comment_id',rows->19->'comment_id');rows=rows-20;
 end if;
 return jsonb_build_object('protocol',1,'account',a,'items',rows,'next',next_value);
end$$;

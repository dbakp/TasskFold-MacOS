-- Read-only capabilities for explicit native completion review. Actual writes
-- still recheck authority, configuration, generations and full baselines.
create or replace function taskfold_private.review_team_completion(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<review>>
declare a uuid:=auth.uid();team uuid;p uuid;id uuid;generation uuid;q uuid;series uuid;series_gen uuid;series_p uuid;planned uuid;
 tr taskfold_private.teams;prior taskfold_private.team_task_edits;c taskfold_private.team_task_completions;
 fingerprint text;source jsonb;parent jsonb;successor jsonb;receipt jsonb;result jsonb;role text;cancelled boolean:=false;
begin
 perform taskfold_private.team_actor();
 if action is null or action not in('complete','undo') or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>128000
  or not b ?& array['team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id']
  or exists(select 1 from jsonb_object_keys(b) e where e not in('team_id','project_id','task_id','task_generation','request_id','record','completed_at','input_zone','next_generation','planned_next_id','series_id','series_generation','series_project_id','undoes','redo_of')) then raise exception using errcode='22023',message='Invalid saved completion';end if;
 team=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');id=taskfold_private.team_uuid(b,'task_id');generation=taskfold_private.team_uuid(b,'task_generation');q=taskfold_private.team_uuid(b,'request_id');
 series=taskfold_private.team_uuid(b,'series_id');series_gen=taskfold_private.team_uuid(b,'series_generation');series_p=taskfold_private.team_uuid(b,'series_project_id');
 perform taskfold_private.team_uuid(b,'next_generation');
 if b->'planned_next_id'<>'null'::jsonb then planned=taskfold_private.team_uuid(b,'planned_next_id');end if;
 if action='undo' then perform taskfold_private.team_uuid(b,'undoes');if b ? 'redo_of' then raise exception using errcode='22023',message='Invalid saved Undo';end if;
 else if b ? 'undoes' then raise exception using errcode='22023',message='Invalid saved completion';end if;if b ? 'redo_of' then perform taskfold_private.team_uuid(b,'redo_of');end if;end if;
 if jsonb_typeof(b->'record') is distinct from 'object' or b->'record'->'id' is distinct from to_jsonb(id)
  or b->'record'->'project_id' is distinct from to_jsonb(p) or b->'record'->'task_generation' is distinct from to_jsonb(generation) then raise exception using errcode='22023',message='Include the original task identity';end if;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 -- All role/grant mutations serialize on this team row. Recheck live identity
 -- after the wait, before looking up receipts or returning any task content.
 perform taskfold_private.team_actor();
 role=taskfold_private.team_project_role(a,p);
 if role is null then raise exception using errcode='42501',message='Project access is required';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team reading is not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found or tr.state<>'active' then raise exception using errcode='PT503',message='Team access is paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform 1 from public.projects where projects.id=p for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,action,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='This saved action needs review';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  select * into c from taskfold_private.team_task_completions where team_id=team and request_id=q;
  if prior.actor_id<>a or prior.fingerprint<>fingerprint or prior.task_id<>id or prior.generation<>generation then raise exception using errcode='PT409',message='This saved action needs review';end if;
  if c.request_id is null then
   select exists(select 1 from taskfold_private.team_task_completion_cancellations x where x.team_id=team and x.request_id=q and x.action=review_team_completion.action) into cancelled;
   if not cancelled then raise exception using errcode='PT409',message='This saved action needs review';end if;
  elsif c.action<>action then raise exception using errcode='PT409',message='This saved action needs review';end if;
 end if;
 -- One statement snapshot for all returned rows. No cross-project task or later
 -- replacement generation is returned under the old identity. The series parent
 -- has its own current role check; losing it cannot expose its old contents.
 select (select to_jsonb(t) from public.tasks t where t.id=review.id and t.task_generation=review.generation and t.project_id=p
   and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=team and x.project_id=p)),
  (select to_jsonb(t) from public.tasks t where t.id=series and t.task_generation=series_gen and t.project_id=series_p
   and taskfold_private.team_project_role(a,series_p) is not null
   and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=team and x.project_id=series_p)),
  (select to_jsonb(t) from public.tasks t where t.id=coalesce(c.successor_id,planned) and t.project_id=p
   and (c.request_id is null or t.task_generation=c.successor_generation)
   and exists(select 1 from taskfold_private.team_content_tasks x where x.task_id=t.id and x.generation=t.task_generation and x.team_id=team and x.project_id=p))
 into source,parent,successor;
 if c.request_id is not null then
  -- Reuse the established strict receipt format, overriding its row reads with
  -- the single statement snapshot above for a coherent review.
  receipt=taskfold_private.team_completion_reply(c,true)||jsonb_build_object('task',source,'successor',successor);
 end if;
 result=jsonb_build_object('review_protocol',1,'account',a,'team_id',team,'project_id',p,'task_id',id,'task_generation',generation,'request_id',q,
  'operation',action,'series_id',series,'series_generation',series_gen,'series_project_id',series_p,'planned_next_id',planned,
  'state',case when cancelled then 'cancelled' when c.request_id is null then 'unrecorded' else 'recorded' end,'project_role',role,
  'task',source,'series',parent,'successor',successor,'receipt',receipt,
  'can_edit_current',source is not null and coalesce(role in('manager','editor')
   and (select native_task_edits_enabled from taskfold_private.team_project_config where singleton)
   and exists(select 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived),false),
  'can_edit_series',parent is not null and coalesce(taskfold_private.team_project_role(a,series_p) in('manager','editor'),false));
 if octet_length(result::text)>1000000 then raise exception using errcode='54000',message='The review is too large. Your saved work is unchanged';end if;
 return result;
end$$;


-- Explicit, same-project copies of attested, retired provisional drafts. Flags
-- remain closed. No direct-write, storage or legacy task policy is widened.
create table taskfold_private.team_draft_copies (
 team_id uuid not null,request_id uuid not null,original_request_id uuid not null,cancelled boolean not null default false,
 primary key(team_id,request_id),
 foreign key(team_id,request_id) references taskfold_private.team_task_edits(team_id,request_id) on delete cascade
);
alter table taskfold_private.team_draft_copies enable row level security;
revoke all on taskfold_private.team_draft_copies from public,anon,authenticated,service_role;

-- Preserve only certified readonly content. Mutable authored details are checked
-- as new content; old completion tokens/timestamps never become copy history.
create function taskfold_private.team_draft_copy_tree(rows jsonb,certified jsonb,p uuid,a uuid,q uuid,at_time timestamptz,assignments boolean,reminders boolean,depth int default 0)
returns jsonb language plpgsql volatile security invoker set search_path='' as $$
declare n jsonb;old jsonb;result jsonb:='[]';fields jsonb;person uuid;
 mutable constant text[]:=array['id','title','description','completed','completed_at','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminders','reminder_specs','subtasks','taskfold_completion_v1'];
begin
 if jsonb_typeof(rows) is distinct from 'array' or (depth>=24 and jsonb_array_length(rows)>0) then raise exception using errcode='22023',message='Use a supported checklist';end if;
 for n in select * from jsonb_array_elements(rows) loop
  old=coalesce(certified->(n->>'id'),'{}');
  if old='{}' then
   if (jsonb_strip_nulls(n)-mutable-array['comments','attachments','source_metadata'])<>'{}'::jsonb
    or coalesce(n->'comments','[]') not in('[]'::jsonb,'null'::jsonb)
    or coalesce(n->'attachments','[]') not in('[]'::jsonb,'null'::jsonb)
    or coalesce(n->'source_metadata','{}') not in('{}'::jsonb,'null'::jsonb) then
    raise exception using errcode='22023',message='New checklist items cannot import file access or history';end if;
  elsif (jsonb_strip_nulls(n)-mutable) is distinct from (jsonb_strip_nulls(old)-mutable) then
   raise exception using errcode='22023',message='Keep certified checklist files and extension fields unchanged';
  end if;
  if not assignments then n=n||'{"assigned_to":null}';end if;
  if not reminders then n=n||jsonb_build_object('reminders','[]'::jsonb,'reminder_specs','[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":false}]'::jsonb);end if;
  select coalesce(jsonb_object_agg(e.k,e.v),'{}') into fields from jsonb_each(n) e(k,v)
   where e.k=any(array['title','description','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','labels','reminders','reminder_specs']);
  perform taskfold_private.automation_validate_fields(fields,null);
  if not n ? 'title' or (n ? 'completed' and jsonb_typeof(n->'completed')<>'boolean') then raise exception using errcode='22023',message='Give checklist items a title and valid state';end if;
  if coalesce(n->>'assigned_to','')<>'' then
   person=(n->>'assigned_to')::uuid;perform taskfold_private.team_task_member(person,p,a);
   if not exists(select 1 from auth.users where users.id=person and (banned_until is null or banned_until<=clock_timestamp())) then raise exception using errcode='42501',message='Choose a current project editor';end if;
  end if;
  n=n||jsonb_build_object('completed',coalesce(n->'completed','false'),'completed_at',case when n->'completed'='true'::jsonb then to_jsonb(at_time) else 'null'::jsonb end,
   'taskfold_completion_v1',jsonb_build_object('epoch',taskfold_private.team_checklist_epoch(q,n->>'id'),'version',0),
   'subtasks',taskfold_private.team_draft_copy_tree(coalesce(n->'subtasks','[]'),certified,p,a,q,at_time,assignments,reminders,depth+1));
  result=result||jsonb_build_array(n);
 end loop;return result;
end$$;

create function taskfold_private.copy_team_draft(b jsonb,commit_copy boolean,cancel_copy boolean default false) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<draft_copy>>
declare a uuid:=auth.uid();team uuid;p uuid;q uuid;original_q uuid;id uuid;g uuid;old_id uuid;old_g uuid;u uuid;
 original jsonb;payload jsonb;r jsonb;prototype jsonb;nodes jsonb;recipients uuid[];locks uuid[];tr taskfold_private.teams;
 expected public.tasks;saved public.tasks;desired public.tasks;current_task public.tasks;prior taskfold_private.team_task_edits;
 fingerprint text;result jsonb;replay boolean:=false;recorded boolean:=false;cancelled boolean:=false;assignments boolean;reminders boolean;at_time timestamptz:=clock_timestamp();
 defaults constant jsonb:='{"completed":false,"completion_version":0,"priority":4,"labels":[],"subtasks":[],"reminders":[],"attachments":[],"comments":[],"is_recurring":false,"reminder_specs":[],"source_metadata":{}}';
 mutable constant text[]:=array['title','description','completed','completed_at','completion_version','created_at','notification_sent_at','priority','due_date','due_time','deadline_date','duration_minutes','time_zone','scheduled_at','assigned_to','section_id','labels','reminders','reminder_specs','subtasks','is_recurring','recurrence_pattern','recurrence_end_date'];
begin
 perform taskfold_private.team_actor();
 if commit_copy is null or cancel_copy is null or (commit_copy and cancel_copy) or b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>900000
  or not b ?& array['original','record','request_id','task_id','task_generation','copy_assignments','copy_reminders']
  or exists(select 1 from jsonb_object_keys(b) e where e not in('original','record','request_id','task_id','task_generation','copy_assignments','copy_reminders'))
  or jsonb_typeof(b->'original') is distinct from 'object' or jsonb_typeof(b->'record') is distinct from 'object'
  or jsonb_typeof(b->'record'->'completed') is distinct from 'boolean'
  or jsonb_typeof(b->'copy_assignments') is distinct from 'boolean' or jsonb_typeof(b->'copy_reminders') is distinct from 'boolean' then
  raise exception using errcode='22023',message='Review this saved draft and its copy choices';end if;
 original=b->'original';payload=b->'record';assignments=(b->>'copy_assignments')::boolean;reminders=(b->>'copy_reminders')::boolean;
 team=taskfold_private.team_uuid(original,'team_id');p=taskfold_private.team_uuid(original,'project_id');original_q=taskfold_private.team_uuid(original,'request_id');
 old_id=taskfold_private.team_uuid(original,'planned_next_id');old_g=taskfold_private.team_uuid(original,'next_generation');
 q=taskfold_private.team_uuid(b,'request_id');id=taskfold_private.team_uuid(b,'task_id');g=taskfold_private.team_uuid(b,'task_generation');
 if q=original_q or id=old_id or id=taskfold_private.team_uuid(original,'task_id') or g=old_g
  or exists(select 1 from jsonb_object_keys(payload) e where not exists(select 1 from pg_attribute att where att.attrelid='public.tasks'::regclass and att.attnum>0 and not att.attisdropped and att.attname=e)) then
  raise exception using errcode='22023',message='Use fresh task and action identities';end if;
 saved=jsonb_populate_record(null::public.tasks,defaults||payload);
 if saved.id is distinct from old_id or saved.task_generation is distinct from old_g or saved.project_id is distinct from p or saved.user_id is distinct from a then
  raise exception using errcode='22023',message='Keep the draft in its original account and project';end if;
 -- Auth rows precede team locks in every guarded task command. Even preview
 -- holds opted-in recipients against removal/bans until validation completes.
 nodes=taskfold_private.automation_tree_index(coalesce(saved.subtasks,'[]'));
 if assignments and not cancel_copy then
  select array_agg(distinct x order by x) into recipients from(select saved.assigned_to x union all select (e.value->>'assigned_to')::uuid from jsonb_each(nodes) e where coalesce(e.value->>'assigned_to','')<>'') z where x is not null;
  perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 end if;
 select * into tr from taskfold_private.teams where teams.id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform taskfold_private.team_actor();
 if coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') and not(cancel_copy and taskfold_private.team_project_role(a,p)='viewer') then raise exception using errcode='42501',message='Editing access is required';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and (cancel_copy or native_task_edits_enabled) for share;
 if not found then raise exception using errcode='PT503',message='Team task actions are not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found or tr.state<>'active' then raise exception using errcode='PT503',message='Team task actions are paused';end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 perform 1 from public.projects where projects.id=p and (cancel_copy or (not is_archived and not ancestor_archived)) for share;
 if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 select array_agg(x order by x) into locks from unnest(array[q,original_q]) x;
 foreach u in array locks loop perform pg_advisory_xact_lock(hashtextextended(team::text||':'||u::text,79241));end loop;
 -- Attests the entire original baseline using its actor-bound recorded HMAC.
 -- A cancelled/unrecorded body cannot certify arbitrary files or opaque data.
 r=taskfold_private.review_team_completion('complete',original);
 if r->>'state'<>'recorded' then raise exception using errcode='PT409',message='This draft has no certified completion';end if;
 select array_agg(x order by x) into locks from unnest(array[id,old_id]) x;
 foreach u in array locks loop perform pg_advisory_xact_lock(hashtextextended(u::text,78137));end loop;
 if not exists(select 1 from taskfold_private.task_generations tg join taskfold_private.team_content_tasks c using(task_id,generation)
  where tg.task_id=old_id and tg.generation=old_g and tg.deleted_at is not null and c.team_id=team and c.project_id=p)
  or exists(select 1 from public.tasks t where t.id=old_id and t.task_generation=old_g) then
  raise exception using errcode='PT409',message='Save this provisional draft before copying it';end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,'team_draft_copy_v1',b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q) then raise exception using errcode='PT409',message='This action identity is already used';end if;
 select * into prior from taskfold_private.team_task_edits where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.fingerprint<>fingerprint or prior.operation<>'create' or prior.task_id<>id or prior.generation<>g
   or not exists(select 1 from taskfold_private.team_draft_copies c where c.team_id=team and c.request_id=q and c.original_request_id=original_q) then
   raise exception using errcode='PT409',message='This action identity is already used';end if;
  replay=true;
  select c.cancelled into cancelled from taskfold_private.team_draft_copies c where c.team_id=team and c.request_id=q;
  recorded=not cancelled;
  if not cancelled then
   select * into current_task from public.tasks t where t.id=draft_copy.id and t.task_generation=g and t.project_id=p
    and exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=t.id and c.generation=t.task_generation and c.team_id=team and c.project_id=p) for update;
  end if;
 elsif cancel_copy then
  -- Reserve the exact actor/HMAC-bound nonce before releasing a failed request.
  -- A late original RPC now sees cancellation and cannot create its task.
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'create');
  insert into taskfold_private.team_draft_copies(team_id,request_id,original_request_id,cancelled) values(team,q,original_q,true);
  cancelled=true;
 else
  if exists(select 1 from public.tasks where tasks.id=draft_copy.id) or exists(select 1 from taskfold_private.task_generations where task_id=id)
   or exists(select 1 from taskfold_private.team_content_tasks where task_id=id) then raise exception using errcode='PT409',message='This copy needs a fresh task identity';end if;
  expected=jsonb_populate_record(null::public.tasks,defaults||(original->'record'));
  prototype=taskfold_private.automation_successor(to_jsonb(expected),a,(original->>'completed_at')::timestamptz,original->>'input_zone',original_q,old_g);
  if prototype is null or prototype->'id' is distinct from to_jsonb(old_id) then raise exception using errcode='PT409',message='Review the draft’s original repeat rule';end if;
  expected=jsonb_populate_record(null::public.tasks,defaults||prototype);
  if (to_jsonb(saved)-mutable) is distinct from (to_jsonb(expected)-mutable) then raise exception using errcode='22023',message='Keep certified files, extension fields and the original task identity unchanged';end if;
  desired=saved;
  if not assignments then desired.assigned_to=null;end if;
  if not reminders then desired.reminders='{}'::text[];desired.reminder_specs='[{"version":1,"id":"00000000-0000-4000-8000-000000000001","kind":"relative","anchor":"planned","offset_minutes":0,"channels":["local"],"enabled":false}]'::jsonb;end if;
  perform taskfold_private.automation_validate_fields(to_jsonb(desired)-array['id','user_id','completed','attachments','comments','created_at','completed_at','recurrence_parent_id','notification_sent_at','source_metadata','task_generation','completion_version'],null);
  if desired.completed is null then raise exception using errcode='22023',message='Use a valid task state';end if;
  nodes=taskfold_private.automation_tree_index(coalesce(expected.subtasks,'[]'));
  desired.subtasks=taskfold_private.team_draft_copy_tree(coalesce(desired.subtasks,'[]'),nodes,p,a,q,at_time,assignments,reminders);
  if desired.assigned_to is not null then
   perform taskfold_private.team_task_member(desired.assigned_to,p,a);
   if not exists(select 1 from auth.users where users.id=desired.assigned_to and (banned_until is null or banned_until<=clock_timestamp())) then raise exception using errcode='42501',message='Choose a current project editor';end if;
  end if;
  if desired.section_id is not null then
   perform 1 from public.sections where sections.id=desired.section_id and sections.project_id=p for key share;
   if not found then raise exception using errcode='PT409',message='This section is unavailable';end if;
  end if;
  if desired.is_recurring and (desired.due_date is null or not taskfold_private.automation_recurrence_valid(desired.recurrence_pattern)) then raise exception using errcode='22023',message='Review the draft’s repeat rule';end if;
  desired.id=id;desired.task_generation=g;desired.user_id=a;desired.recurrence_parent_id=null;desired.completion_version=0;
  desired.scheduled_at=case when desired.time_zone is null then null else taskfold_private.automation_wall_start(to_jsonb(desired),desired.time_zone) end;
  desired.created_at=at_time;desired.completed_at=case when desired.completed then at_time else null end;desired.notification_sent_at=null;desired.comments='[]';
  desired.source_metadata=(coalesce(desired.source_metadata,'{}')-'taskfold_recurrence_v1')||jsonb_build_object('taskfold_draft_copy_v1',jsonb_build_object('original_request',original_q,'provisional_id',old_id,'provisional_generation',old_g,'request_id',q));
  if octet_length(to_jsonb(desired)::text)>800000 then raise exception using errcode='54000',message='This draft copy is too large';end if;
  if commit_copy then
   insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation) values(txid_current(),team,p,id,g,a,'create');
   insert into public.tasks select (desired).* returning * into current_task;
   delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
   insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'create');
   insert into taskfold_private.team_draft_copies(team_id,request_id,original_request_id) values(team,q,original_q);recorded=true;
  else current_task=desired;end if;
 end if;
 result=jsonb_build_object('draft_copy_protocol',1,'account',a,'team_id',team,'project_id',p,'original_request_id',original_q,'request_id',q,'task_id',id,'task_generation',g,
  'copy_assignments',assignments,'copy_reminders',reminders,'cancelled',cancelled,'recorded',recorded,'replayed',replay,'unavailable',current_task.id is null,'task',case when current_task.id is null then null else to_jsonb(current_task) end);
 if octet_length(result::text)>900000 then raise exception using errcode='54000',message='This draft copy review is too large';end if;
 return result;
end$$;
create function public.taskfold_copy_team_draft(_body jsonb,_commit boolean default false,_cancel boolean default false) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.copy_team_draft(_body,_commit,_cancel)$$;
revoke all on function taskfold_private.team_draft_copy_tree(jsonb,jsonb,uuid,uuid,uuid,timestamptz,boolean,boolean,int),taskfold_private.copy_team_draft(jsonb,boolean,boolean),public.taskfold_copy_team_draft(jsonb,boolean,boolean) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.copy_team_draft(jsonb,boolean,boolean),public.taskfold_copy_team_draft(jsonb,boolean,boolean) to authenticated;

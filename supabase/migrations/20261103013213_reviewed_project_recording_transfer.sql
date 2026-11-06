-- Undeployed reviewed personal-project adoption of existing published audio.
-- Normal use stays separately disabled. Immutable publication/object identities
-- stay intact; only the current audience/custody is registered in this commit.
alter table taskfold_private.audio_comment_config add column project_transfer_enabled boolean not null default false;
alter table taskfold_private.team_project_adoption_scope
 add column recording_policy text check(recording_policy is null or recording_policy='published_recordings_v1'),
 add column recording_hash text check(recording_hash is null or recording_hash~'^[0-9a-f]{64}$'),
 add column recording_count integer not null default 0 check(recording_count between 0 and 10000);
alter table taskfold_private.project_adoption_receipts
 add column recording_policy text check(recording_policy is null or recording_policy='published_recordings_v1'),
 add column recording_count integer not null default 0,
 add constraint project_recording_receipt_shape check((recording_policy is null and recording_count=0) or (recording_policy is not null and recording_policy='published_recordings_v1' and recording_count between 1 and 10000));

create function taskfold_private.project_recording_transfer_supported(i jsonb) returns boolean
language sql stable security invoker set search_path='' as $$
 select coalesce((select project_transfer_enabled from taskfold_private.audio_comment_config where singleton),false)
  and i->'protocol'='1'::jsonb and (i->>'published')::integer>0 and (i->>'pending')::integer=0
  and (i->>'retained')::integer=0 and (i->>'unavailable')::integer=0
$$;

create function taskfold_private.lock_project_adoption_audio(ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$begin
 if not exists(select 1 from taskfold_private.audio_comment_publications r left join public.tasks t on t.id=r.task_id
  where r.state in('pending','published','retired') and (r.project_id=any(ids) or t.project_id=any(ids))) then return;end if;
 begin
  -- Publication admission takes task SHARE before writing its ledger. Upgrade
  -- existing project-review locks without waiting on any writer in the reverse
  -- team/task/ledger order; a later admission rechecks the new realm.
  perform 1 from public.tasks where project_id=any(ids) order by id for update nowait;
  perform 1 from taskfold_private.audio_comment_config where singleton for share nowait;
  perform 1 from storage.buckets where id='taskfold-audio-v1' for share nowait;
  perform 1 from taskfold_private.audio_comment_publications r where r.state in('pending','published','retired')
   and (r.project_id=any(ids) or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=any(ids))) order by operation_id for update nowait;
  perform 1 from taskfold_private.audio_comment_custody c where c.project_id=any(ids)
   or exists(select 1 from taskfold_private.audio_comment_publications r where r.operation_id=c.operation_id and r.project_id=any(ids)) order by operation_id for update nowait;
  perform 1 from storage.objects o where o.bucket_id='taskfold-audio-v1' and exists(select 1 from taskfold_private.audio_comment_publications r
   where r.object_name=o.name and r.state in('pending','published','retired') and (r.project_id=any(ids) or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=any(ids)))) order by o.id for share nowait;
 exception when lock_not_available then raise exception using errcode='PT409',message='A recording change is finishing. Refresh this transfer review';end;
end$$;

create function taskfold_private.authorize_project_adoption_audio(team uuid,ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;n integer;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);n:=(i->>'published')::integer;
 if not taskfold_private.project_recording_transfer_supported(i) or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids) and s.recording_policy is null) then
  raise exception using errcode='PT409',message='Review available recordings before transferring these projects';end if;
 update taskfold_private.team_project_adoption_scope s set recording_policy='published_recordings_v1',recording_hash=i->>'inventory_hash',recording_count=n
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids);
end$$;

create function taskfold_private.finish_project_adoption_audio(team uuid,ids uuid[],expected integer) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;n integer;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);
 if expected not between 1 and 10000 or not taskfold_private.project_recording_transfer_supported(i) or (i->>'published')::integer<>expected
  or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
   and s.team_id=team and s.project_id=any(ids) and s.recording_policy='published_recordings_v1' and s.recording_hash=i->>'inventory_hash' and s.recording_count=expected) then
  raise exception using errcode='PT409',message='The reviewed recording inventory changed';end if;
 insert into taskfold_private.audio_comment_custody(operation_id,object_id,team_id,task_id,task_generation,project_id)
 select r.operation_id,o.id,team,t.id,t.task_generation,t.project_id from taskfold_private.audio_comment_publications r
 join public.tasks t on t.id=r.task_id and t.task_generation=r.task_generation and t.project_id=r.project_id
 join taskfold_private.team_content_tasks c on c.task_id=t.id and c.generation=t.task_generation and c.project_id=t.project_id and c.team_id=team
 join storage.objects o on o.bucket_id='taskfold-audio-v1' and o.name=r.object_name where r.state='published' and t.project_id=any(ids) order by r.operation_id;
 get diagnostics n=row_count;
 if n<>expected then raise exception using errcode='PT409',message='The recording transfer could not be confirmed';end if;
end$$;
revoke all on function taskfold_private.project_recording_transfer_supported(jsonb),taskfold_private.lock_project_adoption_audio(uuid[]),taskfold_private.authorize_project_adoption_audio(uuid,uuid[]),taskfold_private.finish_project_adoption_audio(uuid,uuid[],integer) from public,anon,authenticated,service_role;

-- Select the realm after obtaining the root lock: a publication that waited for
-- project adoption must not resume through its obsolete personal-role branch.
create or replace function taskfold_private.audio_scope(a uuid,t uuid,g uuid,p uuid,writable boolean) returns boolean
language plpgsql volatile security definer set search_path='' as $$declare task public.tasks;project public.projects;begin
 select * into task from public.tasks where id=t and task_generation=g and project_id is not distinct from p for share;
 if not found or coalesce(to_jsonb(task)->'is_heading','false'::jsonb) not in('false'::jsonb,'null'::jsonb) then return false;end if;
 if not taskfold_private.is_team_content_task(t) then
  if p is null then return coalesce(task.user_id=a,false);end if;
  select * into project from public.projects where id=p for share;
  if not found or (writable and (project.is_archived or project.ancestor_archived)) or not coalesce(public.has_project_access(a,p),false) then return false;end if;
  if project.user_id=a then return true;end if;
  perform 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted' for share;return found;
 end if;
 if writable then perform 1 from taskfold_private.audio_comment_config where singleton and team_publication_enabled for share;if not found then return false;end if;end if;
 return taskfold_private.audio_team_scope(a,t,g,p,writable);
end$$;
revoke all on function taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;

-- Exact, version-checked additions preserve all existing access/hierarchy/history checks.
do $$declare d text;anchor text;begin
d:=pg_get_functiondef('taskfold_private.project_adoption_contents(uuid[])'::regprocedure);anchor:='return jsonb_build_object(''recording_custody'',rows-array[''inventory_hash'',''review_bytes''],''hashes'',';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_contents(uuid[])';end if;
execute replace(d,anchor,'return jsonb_build_object(''recording_transfer'',jsonb_build_object(''protocol'',1,''supported'',taskfold_private.project_recording_transfer_supported(rows)),''recording_custody'',rows-array[''inventory_hash'',''review_bytes''],''hashes'',');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:='||case when b ? ''connection_policy'' then array[''connection_policy''] else ''{}''::text[] end';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,'||case when b ? ''connection_policy'' then array[''connection_policy''] else ''{}''::text[] end||case when b ? ''recording_policy'' then array[''recording_policy''] else ''{}''::text[] end');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:='||case when b ? ''connection_policy'' then array[''connection_policy''] else ''{}''::text[] end';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,'||case when b ? ''connection_policy'' then array[''connection_policy''] else ''{}''::text[] end||case when b ? ''recording_policy'' then array[''recording_policy''] else ''{}''::text[] end');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:=' perform taskfold_private.try_project_adoption_fences(ids);';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,' perform taskfold_private.try_project_adoption_fences(ids); perform taskfold_private.lock_project_adoption_audio(ids);');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:=' if (contents->''recording_custody''->>''published'')::integer+(contents->''recording_custody''->>''pending'')::integer+(contents->''recording_custody''->>''retained'')::integer>0 then
 result:=result||jsonb_build_object(''commit_supported'',false,''connection_pause_supported'',false);end if;';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,' if (contents->''recording_custody''->>''published'')::integer+(contents->''recording_custody''->>''pending'')::integer+(contents->''recording_custody''->>''retained'')::integer>0 and not (contents->''recording_transfer''->>''supported'')::boolean then
 result:=result||jsonb_build_object(''commit_supported'',false,''connection_pause_supported'',false);end if;
 if b ? ''recording_policy'' then
 if operation<>''review'' or b->''recording_policy'' is distinct from ''"published_recordings_v1"''::jsonb then raise exception using errcode=''22023'',message=''Choose a supported recording transfer policy'';end if;
 if not (contents->''recording_transfer''->>''supported'')::boolean then raise exception using errcode=''PT409'',message=''Finish recording changes before reviewing this transfer'';end if;end if;');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:='jsonb_build_array(1,a,snapshot,decisions,expires)';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,'(case when b ? ''recording_policy'' then jsonb_build_array(3,a,snapshot,decisions,b->''recording_policy'',expires) else jsonb_build_array(1,a,snapshot,decisions,expires) end)');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:='jsonb_build_array(2,a,snapshot,decisions,policy,effects,expires)';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,'(case when b ? ''recording_policy'' then jsonb_build_array(4,a,snapshot,decisions,policy,effects,b->''recording_policy'',expires) else jsonb_build_array(2,a,snapshot,decisions,policy,effects,expires) end)');
d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:='''connection_policy'',policy,''connection_effects'',effects);';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_review(text,jsonb)';end if;
execute replace(d,anchor,'''connection_policy'',policy,''connection_effects'',effects)||case when b ? ''recording_policy'' then jsonb_build_object(''recording_policy'',b->''recording_policy'',''recording_count'',(contents->''recording_custody''->>''published'')::integer) else ''{}''::jsonb end;');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:='jsonb_build_array(1,a,preview->>''inspection_token'',decisions,b->>''expires_at'')';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,'(case when b ? ''recording_policy'' then jsonb_build_array(3,a,preview->>''inspection_token'',decisions,b->''recording_policy'',b->>''expires_at'') else jsonb_build_array(1,a,preview->>''inspection_token'',decisions,b->>''expires_at'') end)');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:='jsonb_build_array(2,a,preview->>''inspection_token'',decisions,''pause'',preview->''connection_effects'',b->>''expires_at'')';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,'(case when b ? ''recording_policy'' then jsonb_build_array(4,a,preview->>''inspection_token'',decisions,''pause'',preview->''connection_effects'',b->''recording_policy'',b->>''expires_at'') else jsonb_build_array(2,a,preview->>''inspection_token'',decisions,''pause'',preview->''connection_effects'',b->>''expires_at'') end)');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:=' if (preview->''contents''->''recording_custody''->>''published'')::integer+(preview->''contents''->''recording_custody''->>''pending'')::integer+(preview->''contents''->''recording_custody''->>''retained'')::integer>0 then
 raise exception using errcode=''PT409'',message=''Review recording custody before transferring these projects'';end if;';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,' if (preview->''contents''->''recording_custody''->>''published'')::integer+(preview->''contents''->''recording_custody''->>''pending'')::integer+(preview->''contents''->''recording_custody''->>''retained'')::integer>0 then
 if b->''recording_policy'' is distinct from ''"published_recordings_v1"''::jsonb or not (preview->''contents''->''recording_transfer''->>''supported'')::boolean then raise exception using errcode=''PT409'',message=''Review recording access before transferring these projects'';end if;
 elsif b ? ''recording_policy'' then raise exception using errcode=''22023'',message=''This selection has no recordings to transfer'';end if;');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:=' perform taskfold_private.register_reviewed_history_custody(team,ids);';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,' if b ? ''recording_policy'' then perform taskfold_private.authorize_project_adoption_audio(team,ids);end if;
 perform taskfold_private.register_reviewed_history_custody(team,ids);');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:=' perform taskfold_private.team_actor();
 insert into taskfold_private.project_adoption_receipts';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,' if b ? ''recording_policy'' then perform taskfold_private.finish_project_adoption_audio(team,ids,(preview->''contents''->''recording_custody''->>''published'')::integer);end if;
 perform taskfold_private.team_actor();
 insert into taskfold_private.project_adoption_receipts');
d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);anchor:=' delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.project_adoption_commit(jsonb)';end if;
execute replace(d,anchor,' if b ? ''recording_policy'' then update taskfold_private.project_adoption_receipts set recording_policy=b->>''recording_policy'',recording_count=(preview->''contents''->''recording_custody''->>''published'')::integer where team_id=team and request_id=q returning * into prior;end if;
 delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);');
d:=pg_get_functiondef('taskfold_private.guard_audio_project_realm()'::regprocedure);anchor:=' if tg_op=''DELETE'' and not exists(select 1 from public.projects where id=p) then return old;end if;';
if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current recording transfer dependency required: taskfold_private.guard_audio_project_realm()';end if;
execute replace(d,anchor,' if tg_op=''DELETE'' and not exists(select 1 from public.projects where id=p) then return old;end if;
 if tg_op=''INSERT'' and exists(select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=new.team_id and s.project_id=new.project_id and s.recording_policy=''published_recordings_v1'' and s.recording_hash is not null and s.recording_count>0) then return new;end if;');
end$$;

create or replace function taskfold_private.project_adoption_receipt_reply(r taskfold_private.project_adoption_receipts,replayed boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('project_adoption_protocol',1,'account',r.actor_id,'team_id',r.team_id,'request_id',r.request_id,
  'project_ids',r.project_ids,'roots',r.root_ids,'parent_id',r.parent_id,'folder_id',r.folder_id,'visibility',r.visibility,
  'assignments_cleared',r.assignments_cleared,'invitations_closed',r.invitations_closed,'applied',true,'replayed',replayed,'automatic_undo',false)
 ||case when r.connection_policy is null then '{}'::jsonb else jsonb_build_object('connection_policy',r.connection_policy,'connection_effects',r.connection_effects) end
 ||case when r.recording_policy is null then '{}'::jsonb else jsonb_build_object('recording_policy',r.recording_policy,'recording_count',r.recording_count) end
$$;
revoke all on function taskfold_private.project_adoption_receipt_reply(taskfold_private.project_adoption_receipts,boolean) from public,anon,authenticated,service_role;

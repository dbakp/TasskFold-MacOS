-- Undeployed: independently reviewed handling of unfinished sends during
-- personal-project adoption. Published media moves; unfinished publication is
-- closed using the existing sender-history/cleanup semantics, never adopted.
alter table taskfold_private.audio_comment_config add column project_unfinished_transfer_enabled boolean not null default false;
alter table taskfold_private.team_project_adoption_scope
 drop constraint team_project_adoption_scope_recording_policy_check,
 add constraint team_project_adoption_scope_recording_policy_check check(recording_policy is null or recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1')),
 add column unfinished_recording_count integer not null default 0 check(unfinished_recording_count between 0 and 10000);
alter table taskfold_private.project_adoption_receipts
 drop constraint project_adoption_receipts_recording_policy_check,
 drop constraint project_recording_receipt_shape,
 add constraint project_adoption_receipts_recording_policy_check check(recording_policy is null or recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1')),
 add column unfinished_recording_count integer not null default 0 check(unfinished_recording_count between 0 and 10000),
 add constraint project_recording_receipt_shape check(
  (recording_policy is null and recording_count=0 and unfinished_recording_count=0)
  or (recording_policy='published_recordings_v1' and recording_count between 1 and 10000 and unfinished_recording_count=0)
  or (recording_policy='move_published_stop_unfinished_v1' and recording_count between 0 and 10000 and unfinished_recording_count between 1 and 10000 and recording_count+unfinished_recording_count<=10000));

create function taskfold_private.project_unfinished_recording_transfer_supported(i jsonb) returns boolean
language sql stable security invoker set search_path='' as $$
 select coalesce((select project_transfer_enabled and project_unfinished_transfer_enabled and audience_review_enabled from taskfold_private.audio_comment_config where singleton),false)
  and taskfold_private.audio_bucket_ready() and i->'protocol'='1'::jsonb
  and (i->>'pending')::integer>0 and (i->>'retained')::integer=0 and (i->>'unavailable')::integer=0
$$;
create function taskfold_private.project_recording_policy_supported(policy text,i jsonb) returns boolean
language sql stable security invoker set search_path='' as $$
 select case policy when 'published_recordings_v1' then taskfold_private.project_recording_transfer_supported(i)
  when 'move_published_stop_unfinished_v1' then taskfold_private.project_unfinished_recording_transfer_supported(i) else false end
$$;

create or replace function taskfold_private.authorize_project_adoption_audio(team uuid,ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;policy text;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);
 policy:=case when (i->>'pending')::integer>0 then 'move_published_stop_unfinished_v1' else 'published_recordings_v1' end;
 if not taskfold_private.project_recording_policy_supported(policy,i) or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids) and s.recording_policy is null) then
  raise exception using errcode='PT409',message='Review recording access and unfinished sends before moving these projects';end if;
 update taskfold_private.team_project_adoption_scope s set recording_policy=policy,recording_hash=i->>'inventory_hash',
  recording_count=(i->>'published')::integer,unfinished_recording_count=(i->>'pending')::integer
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids);
end$$;

create or replace function taskfold_private.finish_project_adoption_audio(team uuid,ids uuid[],expected integer) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;policy text;n integer;unfinished integer;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);unfinished:=(i->>'pending')::integer;
 policy:=case when unfinished>0 then 'move_published_stop_unfinished_v1' else 'published_recordings_v1' end;
 if expected not between 0 and 10000 or not taskfold_private.project_recording_policy_supported(policy,i) or (i->>'published')::integer<>expected
  or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
   and s.team_id=team and s.project_id=any(ids) and s.recording_policy=policy and s.recording_hash=i->>'inventory_hash'
   and s.recording_count=expected and s.unfinished_recording_count=unfinished) then
  raise exception using errcode='PT409',message='The reviewed recording inventory changed';end if;
 insert into taskfold_private.audio_comment_custody(operation_id,object_id,team_id,task_id,task_generation,project_id)
 select r.operation_id,o.id,team,t.id,t.task_generation,t.project_id from taskfold_private.audio_comment_publications r
 join public.tasks t on t.id=r.task_id and t.task_generation=r.task_generation and t.project_id=r.project_id
 join taskfold_private.team_content_tasks c on c.task_id=t.id and c.generation=t.task_generation and c.project_id=t.project_id and c.team_id=team
 join storage.objects o on o.bucket_id='taskfold-audio-v1' and o.name=r.object_name where r.state='published' and t.project_id=any(ids) order by r.operation_id;
 get diagnostics n=row_count;
 if n<>expected then raise exception using errcode='PT409',message='The recording transfer could not be confirmed';end if;
 if unfinished>0 then
  -- The review already locks these rows and task/provider context NOWAIT. Do
  -- not acquire account advisory locks here in the reverse sender lock order.
  -- This is the existing explicit-Close state, including its upload/cleanup
  -- fences. Original identity/hash and every author's local files stay intact.
  update taskfold_private.audio_comment_publications r set state='retired',caption=null,audio_descriptor=null,
   cleanup_after=coalesce(cleanup_after,clock_timestamp()+interval '5 minutes')
   where r.state='pending' and (r.project_id=any(ids) or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=any(ids)));
  get diagnostics n=row_count;
  if n<>unfinished then raise exception using errcode='PT409',message='The unfinished sends could not be stopped';end if;
 end if;
end$$;
revoke all on function taskfold_private.project_unfinished_recording_transfer_supported(jsonb),taskfold_private.project_recording_policy_supported(text,jsonb),taskfold_private.authorize_project_adoption_audio(uuid,uuid[]),taskfold_private.finish_project_adoption_audio(uuid,uuid[],integer) from public,anon,authenticated,service_role;

-- Preserve old wire shapes for published-only clients/receipts. A separate
-- capability and policy bind the new stop count into the signed inspection.
do $patch$declare d text;entry record;begin
 for entry in select * from (values
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$||case when b ? 'recording_policy' then array['recording_policy'] else '{}'::text[] end$old$,
 $new$||case when b ? 'recording_policy' then array['recording_policy'] else '{}'::text[] end||case when b ? 'recording_count' then array['recording_count'] else '{}'::text[] end||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end$new$),
 ('taskfold_private.project_adoption_commit(jsonb)',
 $old$||case when b ? 'recording_policy' then array['recording_policy'] else '{}'::text[] end$old$,
 $new$||case when b ? 'recording_policy' then array['recording_policy'] else '{}'::text[] end||case when b ? 'recording_count' then array['recording_count'] else '{}'::text[] end||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$ if operation='inspect' then return result;end if;$old$,
 $new$ if b->>'recording_policy'='move_published_stop_unfinished_v1' then
 if jsonb_typeof(b->'recording_count') is distinct from 'number' or jsonb_typeof(b->'unfinished_recording_count') is distinct from 'number' then raise exception using errcode='22023',message='Review both recording counts before moving these projects';end if;
 if b->'recording_count' is distinct from contents->'recording_custody'->'published' or b->'unfinished_recording_count' is distinct from contents->'recording_custody'->'pending' then raise exception using errcode='PT409',message='The reviewed recording counts changed';end if;
 elsif b ? 'recording_count' or b ? 'unfinished_recording_count' then raise exception using errcode='22023',message='Choose an unfinished recording policy for these counts';end if;
 if operation='inspect' then return result;end if;$new$),
 ('taskfold_private.audio_comment_command(text,uuid,uuid,jsonb)',
 $old$  return taskfold_private.audio_comment_before_audience_review(case when action='reserve_approved' then 'reserve' when action='finalize_approved' then 'finalize' else action end,a,s,case when action='reserve_approved' then intent when action='finalize_approved' then b-'approval' else b end);$old$,
 $new$  -- Terminal sender history grants no current task/media access. A move can
  -- stop an upload while also retiring its author's personal access.
  if x.state in('retired','purged') then
   if x.author_id is distinct from a then return jsonb_build_object('status','unavailable');end if;
   if x.request_hash is distinct from extensions.digest(convert_to(intent::text,'UTF8'),'sha256') then return jsonb_build_object('status','conflict');end if;
   return jsonb_build_object('status','retired','operation_id',op);
  end if;
  return taskfold_private.audio_comment_before_audience_review(case when action='reserve_approved' then 'reserve' when action='finalize_approved' then 'finalize' else action end,a,s,case when action='reserve_approved' then intent when action='finalize_approved' then b-'approval' else b end);$new$),
 ('taskfold_private.project_adoption_contents(uuid[])',
 $old$jsonb_build_object('protocol',1,'supported',taskfold_private.project_recording_transfer_supported(rows)),'recording_custody'$old$,
 $new$jsonb_build_object('protocol',1,'supported',taskfold_private.project_recording_transfer_supported(rows)),'recording_unfinished_transfer',jsonb_build_object('protocol',1,'supported',taskfold_private.project_unfinished_recording_transfer_supported(rows)),'recording_custody'$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$and not (contents->'recording_transfer'->>'supported')::boolean then$old$,
 $new$and not ((contents->'recording_transfer'->>'supported')::boolean or (contents->'recording_unfinished_transfer'->>'supported')::boolean) then$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$if operation<>'review' or b->'recording_policy' is distinct from '"published_recordings_v1"'::jsonb then$old$,
 $new$if operation<>'review' or b->>'recording_policy' not in('published_recordings_v1','move_published_stop_unfinished_v1') or jsonb_typeof(b->'recording_policy') is distinct from 'string' then$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$if not (contents->'recording_transfer'->>'supported')::boolean then$old$,
 $new$if not taskfold_private.project_recording_policy_supported(b->>'recording_policy',contents->'recording_custody') then$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$jsonb_build_object('recording_policy',b->'recording_policy','recording_count',(contents->'recording_custody'->>'published')::integer)$old$,
 $new$jsonb_build_object('recording_policy',b->'recording_policy','recording_count',(contents->'recording_custody'->>'published')::integer)||case when b->>'recording_policy'='move_published_stop_unfinished_v1' then jsonb_build_object('unfinished_recording_count',(contents->'recording_custody'->>'pending')::integer) else '{}'::jsonb end$new$),
 ('taskfold_private.project_adoption_commit(jsonb)',
 $old$if b->'recording_policy' is distinct from '"published_recordings_v1"'::jsonb or not (preview->'contents'->'recording_transfer'->>'supported')::boolean then$old$,
 $new$if not taskfold_private.project_recording_policy_supported(b->>'recording_policy',preview->'contents'->'recording_custody') then$new$),
 ('taskfold_private.project_adoption_commit(jsonb)',
 $old$recording_count=(preview->'contents'->'recording_custody'->>'published')::integer where team_id=team$old$,
 $new$recording_count=(preview->'contents'->'recording_custody'->>'published')::integer,unfinished_recording_count=case when b->>'recording_policy'='move_published_stop_unfinished_v1' then (preview->'contents'->'recording_custody'->>'pending')::integer else 0 end where team_id=team$new$),
 ('taskfold_private.guard_audio_project_realm()',
 $old$s.recording_policy='published_recordings_v1' and s.recording_hash is not null and s.recording_count>0$old$,
 $new$s.recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1') and s.recording_hash is not null and s.recording_count+s.unfinished_recording_count>0$new$)
 ) as edits(signature,old_text,new_text)
 loop
  d:=pg_get_functiondef(entry.signature::regprocedure);
  if cardinality(string_to_array(d,entry.old_text))<>2 then raise exception 'Current unfinished recording transfer dependency required: %',entry.signature;end if;
  execute replace(d,entry.old_text,entry.new_text);
 end loop;
end$patch$;

create or replace function taskfold_private.project_adoption_receipt_reply(r taskfold_private.project_adoption_receipts,replayed boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('project_adoption_protocol',1,'account',r.actor_id,'team_id',r.team_id,'request_id',r.request_id,
  'project_ids',r.project_ids,'roots',r.root_ids,'parent_id',r.parent_id,'folder_id',r.folder_id,'visibility',r.visibility,
  'assignments_cleared',r.assignments_cleared,'invitations_closed',r.invitations_closed,'applied',true,'replayed',replayed,'automatic_undo',false)
 ||case when r.connection_policy is null then '{}'::jsonb else jsonb_build_object('connection_policy',r.connection_policy,'connection_effects',r.connection_effects) end
 ||case when r.recording_policy is null then '{}'::jsonb else jsonb_build_object('recording_policy',r.recording_policy,'recording_count',r.recording_count) end
 ||case when r.recording_policy='move_published_stop_unfinished_v1' then jsonb_build_object('unfinished_recording_count',r.unfinished_recording_count) else '{}'::jsonb end
$$;
revoke all on function taskfold_private.project_adoption_receipt_reply(taskfold_private.project_adoption_receipts,boolean) from public,anon,authenticated,service_role;

-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Undeployed: reviewed personal-to-team adoption keeps removed operations
-- permanently closed and private. Normal-use gates remain disabled.
alter table taskfold_private.audio_comment_config add column project_private_history_enabled boolean not null default false;
create table taskfold_private.audio_project_private_history (
 operation_id uuid primary key references taskfold_private.audio_comment_publications(operation_id) on delete cascade,
 created_at timestamptz not null default clock_timestamp()
);
alter table taskfold_private.audio_project_private_history enable row level security;
revoke all on taskfold_private.audio_project_private_history from public,anon,authenticated,service_role;
create function taskfold_private.guard_private_audio_history() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if new.state in('pending','published') and (old.state='purged' or exists(select 1 from taskfold_private.audio_project_private_history h where h.operation_id=old.operation_id)) then
  raise exception using errcode='PT409',message='This recording stays removed. Review a new publication to share a saved copy';end if;
 return new;
end$$;
create trigger guard_private_audio_history before update on taskfold_private.audio_comment_publications for each row execute function taskfold_private.guard_private_audio_history();
revoke all on function taskfold_private.guard_private_audio_history() from public,anon,authenticated,service_role;

alter table taskfold_private.team_project_adoption_scope
 drop constraint team_project_adoption_scope_recording_policy_check,
 add constraint team_project_adoption_scope_recording_policy_check check(recording_policy is null or recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1')),
 add column retained_recording_count integer not null default 0 check(retained_recording_count between 0 and 10000);
alter table taskfold_private.project_adoption_receipts
 drop constraint project_adoption_receipts_recording_policy_check,
 drop constraint project_recording_receipt_shape,
 add constraint project_adoption_receipts_recording_policy_check check(recording_policy is null or recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1')),
 add column retained_recording_count integer not null default 0 check(retained_recording_count between 0 and 10000),
 add constraint project_recording_receipt_shape check(
  (recording_policy is null and recording_count=0 and unfinished_recording_count=0 and retained_recording_count=0)
  or (recording_policy='published_recordings_v1' and recording_count between 1 and 10000 and unfinished_recording_count=0 and retained_recording_count=0)
  or (recording_policy='move_published_stop_unfinished_v1' and recording_count between 0 and 10000 and unfinished_recording_count between 1 and 10000 and recording_count+unfinished_recording_count<=10000 and retained_recording_count=0)
  or (recording_policy='move_recordings_keep_removed_private_v1' and recording_count between 0 and 10000 and unfinished_recording_count between 0 and 10000 and retained_recording_count between 1 and 10000 and recording_count+unfinished_recording_count+retained_recording_count<=10000));

-- Undeployed foundation for reviewed whole-project recording custody. This
-- binds actual ledger/provider metadata into the existing signed inspection.
-- Transfer remains refused until the explicit custody commit is implemented.
create or replace function taskfold_private.project_adoption_audio_inventory(ids uuid[]) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare item record;inventory bytea:=extensions.digest('','sha256');payload text;n integer:=0;published integer:=0;pending integer:=0;retained integer:=0;unavailable integer:=0;bytes bigint:=0;
begin
 if ids is null or array_ndims(ids)<>1 or cardinality(ids) not between 1 and 1000 or array_position(ids,null) is not null
  or cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then
  raise exception using errcode='22023',message='Choose a bounded project selection';end if;
 for item in
  select r.operation_id,r.state,to_jsonb(r) publication,to_jsonb(c) custody,to_jsonb(o) provider,to_jsonb(h) private_history,
   (c.operation_id is not null or (r.state<>'retired' and
    (t.id is null or t.task_generation is distinct from r.task_generation or t.project_id is distinct from r.project_id
     or (r.state='published' and (o.id is null or not taskfold_private.audio_bucket_ready()
      or coalesce(to_jsonb(o)->>'owner_id',to_jsonb(o)->>'owner') is not null
      or o.metadata->'size' is distinct from to_jsonb(r.byte_count)
      or o.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb))))) invalid
  from taskfold_private.audio_comment_publications r
  left join public.tasks t on t.id=r.task_id
  left join taskfold_private.audio_comment_custody c on c.operation_id=r.operation_id
  left join storage.objects o on o.bucket_id='taskfold-audio-v1' and o.name=r.object_name
  left join taskfold_private.audio_project_private_history h on h.operation_id=r.operation_id
  where r.state in('pending','published','retired') and (r.project_id=any(ids) or t.project_id=any(ids) or c.project_id=any(ids))
  order by r.operation_id limit 10001
 loop
  n:=n+1;payload:=jsonb_build_array(item.publication,item.custody,item.provider,item.private_history)::text;bytes:=bytes+octet_length(payload);
  if n>10000 or bytes>8388608 then raise exception using errcode='54000',message='These projects have too many recordings to review together';end if;
  if item.state='published' then published:=published+1;elsif item.state='pending' then pending:=pending+1;else retained:=retained+1;end if;
  if item.invalid then unavailable:=unavailable+1;end if;
  inventory:=extensions.digest(inventory||extensions.digest(convert_to(payload,'UTF8'),'sha256'),'sha256');
 end loop;
 return jsonb_build_object('protocol',1,'published',published,'pending',pending,'retained',retained,'unavailable',unavailable,
  'review_bytes',bytes,'inventory_hash',encode(inventory,'hex'));
end$$;

create function taskfold_private.project_private_history_transfer_supported(i jsonb) returns boolean
language sql stable security invoker set search_path='' as $$
 select coalesce((select project_transfer_enabled and project_private_history_enabled and audience_review_enabled
  and ((i->>'pending')::integer=0 or project_unfinished_transfer_enabled) from taskfold_private.audio_comment_config where singleton),false)
  and taskfold_private.audio_bucket_ready() and i->'protocol'='1'::jsonb and (i->>'retained')::integer>0 and (i->>'unavailable')::integer=0
$$;
create or replace function taskfold_private.project_recording_policy_supported(policy text,i jsonb) returns boolean
language sql stable security invoker set search_path='' as $$
 select case policy when 'published_recordings_v1' then taskfold_private.project_recording_transfer_supported(i)
  when 'move_published_stop_unfinished_v1' then taskfold_private.project_unfinished_recording_transfer_supported(i)
  when 'move_recordings_keep_removed_private_v1' then taskfold_private.project_private_history_transfer_supported(i) else false end
$$;
create or replace function taskfold_private.authorize_project_adoption_audio(team uuid,ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;policy text;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);
 policy:=case when (i->>'retained')::integer>0 then 'move_recordings_keep_removed_private_v1' when (i->>'pending')::integer>0 then 'move_published_stop_unfinished_v1' else 'published_recordings_v1' end;
 if not taskfold_private.project_recording_policy_supported(policy,i) or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids) and s.recording_policy is null) then
  raise exception using errcode='PT409',message='Review recording access and unfinished sends before moving these projects';end if;
 update taskfold_private.team_project_adoption_scope s set recording_policy=policy,recording_hash=i->>'inventory_hash',
  recording_count=(i->>'published')::integer,unfinished_recording_count=(i->>'pending')::integer,retained_recording_count=(i->>'retained')::integer
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids);
end$$;

create or replace function taskfold_private.finish_project_adoption_audio(team uuid,ids uuid[],expected integer) returns void
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;policy text;n integer;unfinished integer;begin
 i:=taskfold_private.project_adoption_audio_inventory(ids);unfinished:=(i->>'pending')::integer;
 policy:=case when (i->>'retained')::integer>0 then 'move_recordings_keep_removed_private_v1' when unfinished>0 then 'move_published_stop_unfinished_v1' else 'published_recordings_v1' end;
 if expected not between 0 and 10000 or not taskfold_private.project_recording_policy_supported(policy,i) or (i->>'published')::integer<>expected
  or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid()
   and s.team_id=team and s.project_id=any(ids) and s.recording_policy=policy and s.recording_hash=i->>'inventory_hash'
   and s.recording_count=expected and s.unfinished_recording_count=unfinished and s.retained_recording_count=(i->>'retained')::integer) then
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
 -- Closed history never acquires team custody. Also fence newly stopped
 -- sends: their original publication identities cannot be reopened later.
 insert into taskfold_private.audio_project_private_history(operation_id)
 select r.operation_id from taskfold_private.audio_comment_publications r
 where r.state='retired' and (r.project_id=any(ids) or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=any(ids)))
 order by r.operation_id on conflict(operation_id) do nothing;
 if (select count(*) from taskfold_private.audio_comment_publications r join taskfold_private.audio_project_private_history h using(operation_id)
  where r.state='retired' and (r.project_id=any(ids) or exists(select 1 from public.tasks t where t.id=r.task_id and t.project_id=any(ids))))<>unfinished+(i->>'retained')::integer then
  raise exception using errcode='PT409',message='Removed recording history could not be kept private';end if;
end$$;
revoke all on function taskfold_private.project_adoption_audio_inventory(uuid[]),taskfold_private.project_private_history_transfer_supported(jsonb),taskfold_private.project_recording_policy_supported(text,jsonb),taskfold_private.authorize_project_adoption_audio(uuid,uuid[]),taskfold_private.finish_project_adoption_audio(uuid,uuid[],integer) from public,anon,authenticated,service_role;

-- Apply exact, version-checked edits to the existing signed coordinator.
do $patch$declare d text;entry record;begin
 for entry in select * from (values
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end$old$,
 $new$||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end||case when b ? 'retained_recording_count' then array['retained_recording_count'] else '{}'::text[] end$new$),
 ('taskfold_private.project_adoption_commit(jsonb)',
 $old$||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end$old$,
 $new$||case when b ? 'unfinished_recording_count' then array['unfinished_recording_count'] else '{}'::text[] end||case when b ? 'retained_recording_count' then array['retained_recording_count'] else '{}'::text[] end$new$),
 ('taskfold_private.project_adoption_contents(uuid[])',
 $old$'recording_unfinished_transfer',jsonb_build_object('protocol',1,'supported',taskfold_private.project_unfinished_recording_transfer_supported(rows))$old$,
 $new$'recording_private_history_transfer',jsonb_build_object('protocol',1,'supported',taskfold_private.project_private_history_transfer_supported(rows)),'recording_unfinished_transfer',jsonb_build_object('protocol',1,'supported',taskfold_private.project_unfinished_recording_transfer_supported(rows))$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$if b->>'recording_policy'='move_published_stop_unfinished_v1' then$old$,
 $new$if b->>'recording_policy' in('move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1') then$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$elsif b ? 'recording_count' or b ? 'unfinished_recording_count' then$old$,
 $new$elsif b ? 'recording_count' or b ? 'unfinished_recording_count' or b ? 'retained_recording_count' then$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$ if operation='inspect' then return result;end if;$old$,
 $new$ if b->>'recording_policy'='move_recordings_keep_removed_private_v1' then
 if jsonb_typeof(b->'retained_recording_count') is distinct from 'number' then raise exception using errcode='22023',message='Review the removed recording count';end if;
 if b->'retained_recording_count' is distinct from contents->'recording_custody'->'retained' then raise exception using errcode='PT409',message='The removed recording count changed';end if;
 elsif b ? 'retained_recording_count' then raise exception using errcode='22023',message='Choose a removed recording policy for this count';end if;
 if operation='inspect' then return result;end if;$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$or (contents->'recording_unfinished_transfer'->>'supported')::boolean)$old$,
 $new$or (contents->'recording_unfinished_transfer'->>'supported')::boolean or (contents->'recording_private_history_transfer'->>'supported')::boolean)$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$not in('published_recordings_v1','move_published_stop_unfinished_v1')$old$,
 $new$not in('published_recordings_v1','move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1')$new$),
 ('taskfold_private.project_adoption_review(text,jsonb)',
 $old$case when b->>'recording_policy'='move_published_stop_unfinished_v1' then jsonb_build_object('unfinished_recording_count',(contents->'recording_custody'->>'pending')::integer) else '{}'::jsonb end$old$,
 $new$case when b->>'recording_policy' in('move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1') then jsonb_build_object('unfinished_recording_count',(contents->'recording_custody'->>'pending')::integer) else '{}'::jsonb end||case when b->>'recording_policy'='move_recordings_keep_removed_private_v1' then jsonb_build_object('retained_recording_count',(contents->'recording_custody'->>'retained')::integer) else '{}'::jsonb end$new$),
 ('taskfold_private.project_adoption_commit(jsonb)',
 $old$unfinished_recording_count=case when b->>'recording_policy'='move_published_stop_unfinished_v1' then (preview->'contents'->'recording_custody'->>'pending')::integer else 0 end$old$,
 $new$unfinished_recording_count=case when b->>'recording_policy' in('move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1') then (preview->'contents'->'recording_custody'->>'pending')::integer else 0 end,retained_recording_count=case when b->>'recording_policy'='move_recordings_keep_removed_private_v1' then (preview->'contents'->'recording_custody'->>'retained')::integer else 0 end$new$),
 ('taskfold_private.guard_audio_project_realm()',
 $old$s.recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1') and s.recording_hash is not null and s.recording_count+s.unfinished_recording_count>0$old$,
 $new$s.recording_policy in('published_recordings_v1','move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1') and s.recording_hash is not null and s.recording_count+s.unfinished_recording_count+s.retained_recording_count>0$new$)
 ) as edits(signature,old_text,new_text) loop
  d:=pg_get_functiondef(entry.signature::regprocedure);
  if cardinality(string_to_array(d,entry.old_text))<>2 then raise exception 'Current private recording history dependency required: %',entry.signature;end if;
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
 ||case when r.recording_policy in('move_published_stop_unfinished_v1','move_recordings_keep_removed_private_v1') then jsonb_build_object('unfinished_recording_count',r.unfinished_recording_count) else '{}'::jsonb end
 ||case when r.recording_policy='move_recordings_keep_removed_private_v1' then jsonb_build_object('retained_recording_count',r.retained_recording_count) else '{}'::jsonb end
$$;
revoke all on function taskfold_private.project_adoption_receipt_reply(taskfold_private.project_adoption_receipts,boolean) from public,anon,authenticated,service_role;

commit;

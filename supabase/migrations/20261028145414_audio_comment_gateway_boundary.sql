-- Source candidate only. Does not enable publication or deploy the gateway.
-- A compatible private bucket may be reused; an unexpected bucket is never
-- silently reconfigured, broadened or emptied.
do $$begin
 if not exists(select 1 from pg_class where oid='storage.objects'::regclass and relrowsecurity)
 or not exists(select 1 from pg_class where oid='storage.buckets'::regclass and relrowsecurity) then
  raise exception using errcode='23514',message='Review Storage row security before audio setup';end if;
 if exists(select 1 from storage.buckets b where id='taskfold-audio-v1' and
  (b.name is distinct from 'taskfold-audio-v1' or b.public is distinct from false or b.file_size_limit is distinct from 8000000::bigint
   or b.allowed_mime_types is distinct from array['audio/mp4']::text[]
   or coalesce(to_jsonb(b)->>'owner_id',to_jsonb(b)->>'owner') is not null)) then
  raise exception using errcode='23514',message='Existing audio bucket needs explicit review';end if;
end$$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('taskfold-audio-v1','taskfold-audio-v1',false,8000000,array['audio/mp4']) on conflict(id) do nothing;
create policy taskfold_audio_objects_service_only on storage.objects as restrictive for all to anon,authenticated
 using(bucket_id<>'taskfold-audio-v1') with check(bucket_id<>'taskfold-audio-v1');
create policy taskfold_audio_bucket_service_only on storage.buckets as restrictive for all to anon,authenticated
 using(id<>'taskfold-audio-v1') with check(id<>'taskfold-audio-v1');

create table taskfold_private.audio_request_budgets (
 actor_id uuid not null references auth.users(id) on delete cascade,
 kind text not null check(kind in('publish','download','metadata')),
 window_start timestamptz not null,
 requests integer not null check(requests between 0 and 60),
 primary key(actor_id,kind)
);
alter table taskfold_private.audio_request_budgets enable row level security;
revoke all on taskfold_private.audio_request_budgets from public,anon,authenticated,service_role;
create function taskfold_private.audio_bucket_ready() returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from storage.buckets b where b.id='taskfold-audio-v1' and b.name='taskfold-audio-v1' and not b.public
  and b.file_size_limit=8000000 and b.allowed_mime_types=array['audio/mp4']::text[]
  and coalesce(to_jsonb(b)->>'owner_id',to_jsonb(b)->>'owner') is null)
$$;
-- The explicit clock is private and ungranted. The public service admission
-- always supplies the server clock; callers cannot choose/reset their window.
create function taskfold_private.audio_admit_at(a uuid,s uuid,action text,observed_at timestamptz) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare request_kind text;maximum integer;slot timestamptz;row taskfold_private.audio_request_budgets;retry integer;begin
 if action is null or action not in('publish','download','list','remove') or observed_at is null then raise exception using errcode='22023',message='Unsupported audio admission';end if;
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable','allowed',false);end if;
 if action<>'remove' and (not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) or not taskfold_private.audio_bucket_ready()) then return jsonb_build_object('status','disabled','allowed',false);end if;
 request_kind=case when action in('list','remove') then 'metadata' else action end;
 maximum=case request_kind when 'publish' then 12 when 'download' then 30 else 60 end;
 slot=date_trunc('minute',observed_at);
 -- Serialize even initial inserts from concurrent cold workers.
 perform pg_advisory_xact_lock(hashtextextended('audio-budget:'||a::text||':'||request_kind,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable','allowed',false);end if;
 if action<>'remove' and (not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) or not taskfold_private.audio_bucket_ready()) then return jsonb_build_object('status','disabled','allowed',false);end if;
 insert into taskfold_private.audio_request_budgets(actor_id,kind,window_start,requests) values(a,request_kind,slot,0) on conflict(actor_id,kind) do nothing;
 select * into row from taskfold_private.audio_request_budgets where actor_id=a and audio_request_budgets.kind=request_kind for update;
 if row.window_start<>slot then update taskfold_private.audio_request_budgets set window_start=slot,requests=0 where actor_id=a and audio_request_budgets.kind=request_kind returning * into row;end if;
 if row.requests>=maximum then
  retry=greatest(1,least(60,ceil(extract(epoch from slot+interval '1 minute'-observed_at))::integer));
  return jsonb_build_object('protocol',1,'account',a,'allowed',false,'status','rate_limited','retry_after',retry);end if;
 update taskfold_private.audio_request_budgets set requests=requests+1 where actor_id=a and audio_request_budgets.kind=request_kind;
 return jsonb_build_object('protocol',1,'account',a,'allowed',true,'retry_after',0);
end$$;
revoke all on function taskfold_private.audio_bucket_ready(),taskfold_private.audio_admit_at(uuid,uuid,text,timestamptz) from public,anon,authenticated,service_role;
create function taskfold_private.audio_admit(a uuid,s uuid,action text) returns jsonb
language sql volatile security definer set search_path='' as $$select taskfold_private.audio_admit_at(a,s,action,clock_timestamp())$$;
revoke all on function taskfold_private.audio_admit(uuid,uuid,text) from public,anon,authenticated;
grant execute on function taskfold_private.audio_admit(uuid,uuid,text) to service_role;
create function public.taskfold_audio_comment_admit(_actor uuid,_session uuid,_action text) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_admit(_actor,_session,_action)$$;
-- Keep privileged logic private: this wrapper has no data access beyond the
-- private admission call and is exposed to the service role alone.
revoke all on function public.taskfold_audio_comment_admit(uuid,uuid,text) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_admit(uuid,uuid,text) to service_role;

-- Preserve the original metadata coordinator privately, but remove its old
-- service grant. All service finalization now passes the Storage-row boundary.
alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_ledger_v1;
revoke all on function taskfold_private.audio_comment_ledger_v1(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare intent jsonb;t uuid;g uuid;p uuid;object_path text;config storage.buckets;asset storage.objects;candidate storage.objects;n integer:=0;begin
 if action is distinct from 'finalize' then return taskfold_private.audio_comment_ledger_v1(action,a,s,b);end if;
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) then return jsonb_build_object('status','disabled');end if;
 perform taskfold_private.audio_fields(b,array['intent','stored_sha256','stored_bytes']);intent=b->'intent';perform taskfold_private.audio_intent(intent);
 if intent->'account' is distinct from to_jsonb(a) then return jsonb_build_object('status','unavailable');end if;
 t=taskfold_private.audio_uuid(intent->'target','task_id');g=taskfold_private.audio_uuid(intent->'target','task_generation');p=taskfold_private.audio_uuid(intent->'target','project_id',true);
 object_path='audio-comments/v1/'||t::text||'/'||g::text||'/'||(intent->>'asset_id')||'.m4a';
 -- Same account/task lock order as the metadata coordinator. No Storage network
 -- operation occurs while these transaction locks are held.
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_scope(a,t,g,p,false),false) then return jsonb_build_object('status','unavailable');end if;
 select * into config from storage.buckets where id='taskfold-audio-v1' for share;
 if not found or not taskfold_private.audio_bucket_ready() then return jsonb_build_object('status','verification_failed');end if;
 for candidate in select * from storage.objects o where o.bucket_id='taskfold-audio-v1' and o.name=object_path limit 2 for share loop
  n=n+1;asset=candidate;
 end loop;
 if n<>1 or coalesce(to_jsonb(asset)->>'owner_id',to_jsonb(asset)->>'owner') is not null
  or asset.metadata->'size' is distinct from intent->'audio'->'byte_count'
  or asset.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb then return jsonb_build_object('status','verification_failed');end if;
 -- Row metadata is an additional boundary, not byte proof. Only the gateway's
 -- independently read and hashed body may supply stored_sha256/stored_bytes.
 return taskfold_private.audio_comment_ledger_v1(action,a,s,b);
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;

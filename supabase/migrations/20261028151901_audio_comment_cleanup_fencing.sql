-- Disabled source candidate. Unknown network outcomes never expire into proof.
create table taskfold_private.audio_upload_attempts(
 ticket_id uuid primary key default gen_random_uuid(),
 operation_id uuid not null references taskfold_private.audio_comment_publications(operation_id),
 state text not null default 'open' check(state in('open','settled')),
 started_at timestamptz not null default clock_timestamp(),
 settled_at timestamptz,
 check((state='open' and settled_at is null) or (state='settled' and settled_at is not null))
);
create index audio_upload_operation on taskfold_private.audio_upload_attempts(operation_id);
create unique index audio_upload_one_open on taskfold_private.audio_upload_attempts(operation_id) where state='open';
alter table taskfold_private.audio_upload_attempts enable row level security;
revoke all on taskfold_private.audio_upload_attempts from public,anon,authenticated,service_role;
create table taskfold_private.audio_cleanup_claims(
 operation_id uuid primary key references taskfold_private.audio_comment_publications(operation_id),
 token uuid not null default gen_random_uuid(),
 expires_at timestamptz not null default clock_timestamp()+interval '2 minutes'
);
alter table taskfold_private.audio_cleanup_claims enable row level security;
revoke all on taskfold_private.audio_cleanup_claims from public,anon,authenticated,service_role;
alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_gateway_v2;
revoke all on function taskfold_private.audio_comment_gateway_v2(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare op uuid;ticket uuid;r taskfold_private.audio_comment_publications;result jsonb;begin
 if action in('cleanup','purged') then raise exception using errcode='22023',message='Use fenced audio maintenance';end if;
 if action='upload_settle' then
  -- Service-only transport observation. A caller timeout is NOT a settlement.
  perform taskfold_private.audio_fields(b,array['operation_id','ticket_id']);
  op=taskfold_private.audio_uuid(b,'operation_id');ticket=taskfold_private.audio_uuid(b,'ticket_id');
  perform 1 from taskfold_private.audio_comment_publications where operation_id=op for update;
  update taskfold_private.audio_upload_attempts set state='settled',settled_at=coalesce(settled_at,clock_timestamp()) where operation_id=op and ticket_id=ticket;
  return jsonb_build_object('protocol',1,'settled',found);
 elsif action='upload_begin' then
  perform taskfold_private.audio_fields(b,array['operation_id']);op=taskfold_private.audio_uuid(b,'operation_id');
  if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
  -- Match the coordinator's task-before-publication lock order.
  select * into r from taskfold_private.audio_comment_publications where operation_id=op;
  if not found or not coalesce(taskfold_private.audio_scope(a,r.task_id,r.task_generation,r.project_id,true),false) then return jsonb_build_object('status','unavailable');end if;
  select * into r from taskfold_private.audio_comment_publications where operation_id=op for update;
  if not found or not coalesce(taskfold_private.audio_actor(a,s),false) or r.author_id is distinct from a or r.state<>'pending' or r.expires_at<=clock_timestamp()
   or not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false)
   or not taskfold_private.audio_bucket_ready() then return jsonb_build_object('status','unavailable');end if;
  if exists(select 1 from taskfold_private.audio_upload_attempts where operation_id=op and state='open') then return jsonb_build_object('status','upload_unresolved');end if;
  insert into taskfold_private.audio_upload_attempts(operation_id) values(op) returning ticket_id into ticket;
  return jsonb_build_object('protocol',1,'operation_id',op,'ticket_id',ticket,'state','open');
 end if;
 result=taskfold_private.audio_comment_gateway_v2(action,a,s,b);
 if action='finalize' and result->>'state'='published' then
  -- Verified readback and successful finalize reconcile the sole open upload.
  op=taskfold_private.audio_uuid(b->'intent','operation_id');
  update taskfold_private.audio_upload_attempts set state='settled',settled_at=clock_timestamp() where operation_id=op and state='open';
 end if;
 return result;
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create function taskfold_private.audio_maintenance(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare candidate jsonb;r taskfold_private.audio_comment_publications;items jsonb:='[]'::jsonb;claim taskfold_private.audio_cleanup_claims;op uuid;begin
 if action='claim' then
  perform taskfold_private.audio_fields(b,array[]::text[]);
  -- Expire pending reservations even while publication is disabled.
  perform taskfold_private.audio_comment_gateway_v2('cleanup',null,null,'{}');
  for r in select * from taskfold_private.audio_comment_publications p where state='retired' and cleanup_after<=clock_timestamp()
   and not exists(select 1 from taskfold_private.audio_upload_attempts u where u.operation_id=p.operation_id and u.state='open')
   and not exists(select 1 from taskfold_private.audio_cleanup_claims c where c.operation_id=p.operation_id and c.expires_at>clock_timestamp())
   order by cleanup_after,operation_id limit 25 for update skip locked loop
   insert into taskfold_private.audio_cleanup_claims(operation_id) values(r.operation_id) on conflict(operation_id) do update set token=gen_random_uuid(),expires_at=clock_timestamp()+interval '2 minutes' returning * into claim;
   items=items||jsonb_build_array(jsonb_build_object('operation_id',r.operation_id,'asset_id',r.asset_id,'bucket','taskfold-audio-v1','object_name',r.object_name,'token',claim.token));
  end loop;
  return jsonb_build_object('protocol',1,'items',items,'blocked_uploads',(select count(*) from taskfold_private.audio_comment_publications p where state='retired' and exists(select 1 from taskfold_private.audio_upload_attempts u where u.operation_id=p.operation_id and u.state='open')));
 elsif action='confirm' then
  perform taskfold_private.audio_fields(b,array['operation_id','asset_id','object_name','token']);op=taskfold_private.audio_uuid(b,'operation_id');
  select * into r from taskfold_private.audio_comment_publications where operation_id=op for update;
  if not found or r.state<>'retired' or r.asset_id is distinct from taskfold_private.audio_uuid(b,'asset_id') or r.object_name is distinct from b->>'object_name' then return jsonb_build_object('protocol',1,'purged',false);end if;
  select * into claim from taskfold_private.audio_cleanup_claims where operation_id=op for update;
  if not found or claim.token is distinct from taskfold_private.audio_uuid(b,'token') or claim.expires_at<=clock_timestamp()
   or exists(select 1 from taskfold_private.audio_upload_attempts where operation_id=op and state='open')
   or exists(select 1 from storage.objects where bucket_id='taskfold-audio-v1' and name=r.object_name) then return jsonb_build_object('protocol',1,'purged',false);end if;
  -- The worker must first receive Storage removal success and verify GET 404.
  -- SQL independently checks metadata absence; it never deletes Storage rows.
  candidate=taskfold_private.audio_comment_gateway_v2('purged',null,null,b-'token');
  if candidate->>'purged'='true' then delete from taskfold_private.audio_cleanup_claims where operation_id=op;end if;
  return candidate;
 end if;
 raise exception using errcode='22023',message='Unsupported audio maintenance';
end$$;
revoke all on function taskfold_private.audio_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_maintenance(text,jsonb) to service_role;
create function public.taskfold_audio_comment_maintenance(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_maintenance(_action,_body)$$;
revoke all on function public.taskfold_audio_comment_maintenance(text,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_maintenance(text,jsonb) to service_role;

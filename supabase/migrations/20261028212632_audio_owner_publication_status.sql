-- Sender-only operation history and explicit cancellation. No task/media read
-- permission is granted, and an absent reservation is not terminal by itself.
create table taskfold_private.audio_closed_operations (
 actor_id uuid not null references auth.users(id) on delete cascade,
 operation_id uuid not null,
 request_hash bytea not null check(octet_length(request_hash)=32),
 created_at timestamptz not null default clock_timestamp(),
 primary key(actor_id,operation_id)
);
alter table taskfold_private.audio_closed_operations enable row level security;
revoke all on taskfold_private.audio_closed_operations from public,anon,authenticated,service_role;

create function taskfold_private.audio_owner_publication(a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare intent jsonb;op uuid;t uuid;fingerprint bytea;marker bytea;r taskfold_private.audio_comment_publications;closing boolean;begin
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 perform taskfold_private.audio_fields(b,array['intent','close']);intent=b->'intent';perform taskfold_private.audio_intent(intent);
 if intent->'account' is distinct from to_jsonb(a) or jsonb_typeof(b->'close') is distinct from 'boolean' then return jsonb_build_object('status','unavailable');end if;
 closing=(b->>'close')::boolean;op=taskfold_private.audio_uuid(intent,'operation_id');t=taskfold_private.audio_uuid(intent->'target','task_id');
 fingerprint=extensions.digest(convert_to(intent::text,'UTF8'),'sha256');
 -- Same account -> task -> operation order as reserve/finalize, including the
 -- absent-operation race. Status/cancellation never starts a Storage request.
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-operation:'||op::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 select request_hash into marker from taskfold_private.audio_closed_operations where actor_id=a and operation_id=op for share;
 if found then
  if marker<>fingerprint then return jsonb_build_object('status','conflict');end if;
  return jsonb_build_object('protocol',1,'intent',intent,'state','closed');
 end if;
 select * into r from taskfold_private.audio_comment_publications where operation_id=op for update;
 if found then
  -- This returns only the sender's immutable intent/history, never a current
  -- task title, membership, other author's comment or Storage location/body.
  if r.author_id is distinct from a then return jsonb_build_object('status','unavailable');end if;
  if r.request_hash<>fingerprint then return jsonb_build_object('status','conflict');end if;
  if r.state='published' then return taskfold_private.audio_receipt(r,a);end if;
  if r.state='pending' and not closing and r.expires_at>clock_timestamp() then
   return jsonb_build_object('protocol',1,'intent',intent,'state','unconfirmed');
  end if;
  if r.state='pending' then
   update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,
    cleanup_after=coalesce(cleanup_after,clock_timestamp()+interval '5 minutes') where operation_id=op;
  end if;
  return jsonb_build_object('protocol',1,'intent',intent,'state','closed');
 end if;
 if not closing then return jsonb_build_object('protocol',1,'intent',intent,'state','unconfirmed');end if;
 -- An actor-qualified marker cannot poison another actor's operation UUID or a
 -- task's media quota. It stores no caption/media and cannot grow without bound.
 if (select count(*) from taskfold_private.audio_closed_operations where actor_id=a)>=1000 then return jsonb_build_object('status','quota');end if;
 insert into taskfold_private.audio_closed_operations(actor_id,operation_id,request_hash) values(a,op,fingerprint);
 return jsonb_build_object('protocol',1,'intent',intent,'state','closed');
end$$;
revoke all on function taskfold_private.audio_owner_publication(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_owner_publication(uuid,uuid,jsonb) to service_role;
create function public.taskfold_audio_owner_publication(_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_owner_publication(_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_owner_publication(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_owner_publication(uuid,uuid,jsonb) to service_role;

alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_before_owner_status;
revoke all on function taskfold_private.audio_comment_before_owner_status(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare intent jsonb;op uuid;t uuid;marker bytea;begin
 if action in('reserve','finalize') then
  if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
  if action='finalize' then perform taskfold_private.audio_fields(b,array['intent','stored_sha256','stored_bytes']);intent=b->'intent';else intent=b;end if;
  perform taskfold_private.audio_intent(intent);
  if intent->'account' is distinct from to_jsonb(a) then return jsonb_build_object('status','unavailable');end if;
  op=taskfold_private.audio_uuid(intent,'operation_id');t=taskfold_private.audio_uuid(intent->'target','task_id');
  perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
  perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
  -- The actor lock serializes markers with cancellation. Leave the operation
  -- lock to the existing coordinator after its normal task authorization.
  if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
  select request_hash into marker from taskfold_private.audio_closed_operations where actor_id=a and operation_id=op for share;
  if found then
   if marker<>extensions.digest(convert_to(intent::text,'UTF8'),'sha256') then return jsonb_build_object('status','conflict');end if;
   return jsonb_build_object('status','retired','operation_id',op);
  end if;
 end if;
 return taskfold_private.audio_comment_before_owner_status(action,a,s,b);
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;

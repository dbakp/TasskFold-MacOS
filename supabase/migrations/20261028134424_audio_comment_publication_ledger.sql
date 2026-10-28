-- Inactive publication coordinator. This does not provision a bucket, upload
-- media, expose a client RPC, or establish physical Storage verification.
create table taskfold_private.audio_comment_config (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false
);
insert into taskfold_private.audio_comment_config default values;
alter table taskfold_private.audio_comment_config enable row level security;
revoke all on taskfold_private.audio_comment_config from public,anon,authenticated,service_role;

create table taskfold_private.audio_comment_publications (
 operation_id uuid primary key,
 comment_id uuid not null unique,
 asset_id uuid not null unique,
 author_id uuid references auth.users(id) on delete set null,
 task_id uuid not null,
 task_generation uuid not null,
 project_id uuid,
 request_hash bytea not null check(octet_length(request_hash)=32),
 sha256 text not null check(sha256 ~ '^[0-9a-f]{64}$'),
 byte_count integer not null check(byte_count between 1 and 8000000),
 caption text,
 audio_descriptor jsonb,
 state text not null default 'pending' check(state in('pending','published','retired','purged')),
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
 published_at timestamptz,
 cleanup_after timestamptz,
 last_cleanup_at timestamptz,
 object_name text generated always as ('audio-comments/v1/'||task_id::text||'/'||task_generation::text||'/'||asset_id::text||'.m4a') stored,
 check((state in('pending','published') and caption is not null and audio_descriptor is not null and octet_length(caption)<=4000)
    or (state in('retired','purged') and caption is null and audio_descriptor is null)),
 check(state<>'published' or published_at is not null),
 check(state not in('retired','purged') or cleanup_after is not null)
);
create index audio_comment_author on taskfold_private.audio_comment_publications(author_id);
create index audio_comment_author_quota on taskfold_private.audio_comment_publications(author_id) where state<>'purged';
create index audio_comment_task_quota on taskfold_private.audio_comment_publications(task_id,state) where state<>'purged';
create index audio_comment_task_read on taskfold_private.audio_comment_publications(task_id,task_generation,published_at,comment_id) where state='published';
create index audio_comment_expiry on taskfold_private.audio_comment_publications(expires_at,operation_id) where state='pending';
create index audio_comment_project on taskfold_private.audio_comment_publications(project_id) where project_id is not null;
create index audio_comment_cleanup on taskfold_private.audio_comment_publications(cleanup_after,operation_id) where state='retired';
alter table taskfold_private.audio_comment_publications enable row level security;
revoke all on taskfold_private.audio_comment_publications from public,anon,authenticated,service_role;

create function taskfold_private.audio_fields(b jsonb,keys text[]) returns void
language plpgsql immutable security invoker set search_path='' as $$begin
 if jsonb_typeof(b) is distinct from 'object' then raise exception using errcode='22023',message='Review this recording request';end if;
 if not b ?& keys
  or exists(select 1 from jsonb_object_keys(b) k where not k=any(keys)) then
  raise exception using errcode='22023',message='Review this recording request';end if;
end$$;
create function taskfold_private.audio_uuid(b jsonb,k text,nullable boolean default false) returns uuid
language plpgsql immutable security invoker set search_path='' as $$declare id uuid;begin
 if nullable and b->k='null'::jsonb then return null;end if;
 if jsonb_typeof(b->k) is distinct from 'string' or (b->>k) !~ '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then
  raise exception using errcode='22023',message='Review this recording identity';end if;
 id=(b->>k)::uuid;if id='00000000-0000-0000-0000-000000000000'::uuid then
  raise exception using errcode='22023',message='Review this recording identity';end if;return id;
end$$;
create function taskfold_private.audio_target(b jsonb) returns void
language plpgsql immutable security invoker set search_path='' as $$begin
 perform taskfold_private.audio_fields(b,array['task_id','task_generation','project_id']);
 perform taskfold_private.audio_uuid(b,'task_id');perform taskfold_private.audio_uuid(b,'task_generation');perform taskfold_private.audio_uuid(b,'project_id',true);
end$$;
create function taskfold_private.audio_intent(b jsonb) returns void
language plpgsql immutable security invoker set search_path='' as $$declare d jsonb;begin
 perform taskfold_private.audio_fields(b,array['version','account','operation_id','comment_id','asset_id','target','caption','audio']);
 if octet_length(b::text)>32000 or b->'version' is distinct from '1'::jsonb or jsonb_typeof(b->'caption') is distinct from 'string'
  or octet_length(b->>'caption')>4000 then raise exception using errcode='22023',message='Review this recording caption';end if;
 perform taskfold_private.audio_uuid(b,'account');perform taskfold_private.audio_uuid(b,'operation_id');
 perform taskfold_private.audio_uuid(b,'comment_id');perform taskfold_private.audio_uuid(b,'asset_id');perform taskfold_private.audio_target(b->'target');
 d=b->'audio';perform taskfold_private.audio_fields(d,array['version','mime_type','byte_count','duration_ms','sha256']);
 if d->'version' is distinct from '1'::jsonb or d->'mime_type' is distinct from '"audio/mp4"'::jsonb
  or jsonb_typeof(d->'byte_count') is distinct from 'number' or (d->>'byte_count') !~ '^[0-9]{1,7}$'
  or (d->>'byte_count')::integer not between 1 and 8000000
  or jsonb_typeof(d->'duration_ms') is distinct from 'number' or (d->>'duration_ms') !~ '^[0-9]{1,6}$'
  or (d->>'duration_ms')::integer not between 1 and 120000
  or jsonb_typeof(d->'sha256') is distinct from 'string' or (d->>'sha256') !~ '^[0-9a-f]{64}$' then
  raise exception using errcode='22023',message='Review this recording format';end if;
end$$;

create function taskfold_private.audio_actor(a uuid,s uuid) returns boolean
language plpgsql volatile security definer set search_path='' as $$begin
 if a is null or s is null then return false;end if;
 perform 1 from auth.users where id=a and (banned_until is null or banned_until<=clock_timestamp()) for share;
 if not found then return false;end if;
 perform 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp()) for share;
 if not found then return false;end if;
 return not exists(select 1 from taskfold_private.account_removal_receipts where account_id=a and created_at>clock_timestamp()-interval '7 days');
end$$;
create function taskfold_private.audio_scope(a uuid,t uuid,g uuid,p uuid,writable boolean) returns boolean
language plpgsql volatile security definer set search_path='' as $$declare task public.tasks;project public.projects;begin
 select * into task from public.tasks where id=t and task_generation=g and project_id is not distinct from p for share;
 if not found or taskfold_private.is_team_content_task(t) or coalesce(to_jsonb(task)->'is_heading','false'::jsonb) not in('false'::jsonb,'null'::jsonb) then return false;end if;
 if p is null then return coalesce(task.user_id=a,false);end if;
 select * into project from public.projects where id=p for share;
 if not found or (writable and (project.is_archived or project.ancestor_archived)) or not coalesce(public.has_project_access(a,p),false) then return false;end if;
 if project.user_id=a then return true;end if;
 perform 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted' for share;
 return found;
end$$;
create function taskfold_private.audio_receipt(r taskfold_private.audio_comment_publications,a uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',a,'operation_id',r.operation_id,'comment_id',r.comment_id,'asset_id',r.asset_id,
  'author_id',r.author_id,'target',jsonb_build_object('task_id',r.task_id,'task_generation',r.task_generation,'project_id',r.project_id),
  'caption',r.caption,'audio',r.audio_descriptor,'state',r.state,'reserved_at',r.created_at,'expires_at',r.expires_at,'published_at',r.published_at,'bucket','taskfold-audio-v1','object_name',r.object_name)
$$;

create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare x taskfold_private.audio_comment_publications;intent jsonb;target jsonb;fingerprint bytea;op uuid;t uuid;g uuid;p uuid;id uuid;
 n bigint;bytes bigint;items jsonb;
begin
 if action is null or action not in('reserve','finalize','read','list','remove','cleanup','purged') then
  raise exception using errcode='22023',message='Unsupported recording action';end if;
 if action in('cleanup','purged') and (a is not null or s is not null) then
  raise exception using errcode='22023',message='Use the server recording cleanup worker';end if;
 -- Only the service-role wrapper may call this branch. These operations do not
 -- borrow a removed user's session and must remain available while publishing is off.
 if action='cleanup' then
  perform taskfold_private.audio_fields(b,array[]::text[]);
  update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes'
   where operation_id in(select operation_id from taskfold_private.audio_comment_publications where state='pending' and expires_at<=clock_timestamp() order by expires_at,operation_id limit 25 for update skip locked);
  select coalesce(jsonb_agg(jsonb_build_object('operation_id',q.operation_id,'asset_id',q.asset_id,'bucket','taskfold-audio-v1','object_name',q.object_name)),'[]') into items
   from (select * from taskfold_private.audio_comment_publications where state='retired' and cleanup_after<=clock_timestamp() order by cleanup_after,operation_id limit 25) q;
  return jsonb_build_object('protocol',1,'items',items);
 elsif action='purged' then
  perform taskfold_private.audio_fields(b,array['operation_id','asset_id','object_name']);op=taskfold_private.audio_uuid(b,'operation_id');id=taskfold_private.audio_uuid(b,'asset_id');
  update taskfold_private.audio_comment_publications set state='purged',last_cleanup_at=clock_timestamp()
   where operation_id=op and asset_id=id and object_name=b->>'object_name' and state in('retired','purged') and cleanup_after<=clock_timestamp() returning * into x;
  return jsonb_build_object('protocol',1,'purged',found);
 end if;
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if action<>'remove' and not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) then return jsonb_build_object('status','disabled');end if;
 if action in('reserve','finalize') then
  if action='finalize' then perform taskfold_private.audio_fields(b,array['intent','stored_sha256','stored_bytes']);intent=b->'intent';else intent=b;end if;
  perform taskfold_private.audio_intent(intent);
  if intent->'account' is distinct from to_jsonb(a) then return jsonb_build_object('status','unavailable');end if;
  op=taskfold_private.audio_uuid(intent,'operation_id');target=intent->'target';
 else
  if action='list' then perform taskfold_private.audio_target(b);target=b;
  else
   perform taskfold_private.audio_fields(b,array['comment_id']);id=taskfold_private.audio_uuid(b,'comment_id');
   select * into x from taskfold_private.audio_comment_publications where comment_id=id;
   if not found then return jsonb_build_object('status','unavailable');end if;
   target=jsonb_build_object('task_id',x.task_id,'task_generation',x.task_generation,'project_id',x.project_id);op=x.operation_id;
  end if;
 end if;
 t=taskfold_private.audio_uuid(target,'task_id');g=taskfold_private.audio_uuid(target,'task_generation');p=taskfold_private.audio_uuid(target,'project_id',true);
 -- Serialize account quotas before taking task locks. All same-operation retries
 -- then share one durable identity, even across concurrent service workers.
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('audio-account:'||a::text,20261028));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('audio-task:'||t::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_scope(a,t,g,p,false),false) then return jsonb_build_object('status','unavailable');end if;
 if action='list' then
  select coalesce(jsonb_agg(taskfold_private.audio_receipt(q,a)),'[]') into items from
   (select * from taskfold_private.audio_comment_publications where task_id=t and task_generation=g and project_id is not distinct from p and state='published' order by published_at,comment_id limit 20) q;
  return jsonb_build_object('protocol',1,'account',a,'items',items);
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('audio-operation:'||op::text,20261028));
 select * into x from taskfold_private.audio_comment_publications where operation_id=op for update;
 if action in('reserve','finalize') then
  fingerprint=extensions.digest(convert_to(intent::text,'UTF8'),'sha256');
  if x.operation_id is not null then
   if x.author_id is distinct from a or x.request_hash<>fingerprint then return jsonb_build_object('status','conflict');end if;
   if x.state in('retired','purged') then return jsonb_build_object('status','retired','operation_id',op);end if;
   if x.state='pending' and x.expires_at<=clock_timestamp() then
    update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes' where operation_id=op;
    return jsonb_build_object('status','expired','operation_id',op);
   end if;
  elsif action='finalize' then return jsonb_build_object('status','unavailable');
  else
   if not coalesce(taskfold_private.audio_scope(a,t,g,p,true),false) then return jsonb_build_object('status','unavailable');end if;
   -- Task lock and quota lock serialize both limits. Retired, unpurged media
   -- still consumes quota until the Storage coordinator confirms deletion.
   select count(*),coalesce(sum(byte_count),0) into n,bytes from taskfold_private.audio_comment_publications where author_id=a and state<>'purged';
   if n>=100 or bytes+(intent->'audio'->>'byte_count')::integer>250000000 then return jsonb_build_object('status','quota');end if;
   select count(*),coalesce(sum(byte_count),0) into n,bytes from taskfold_private.audio_comment_publications where task_id=t and state<>'purged';
   if n>=20 or bytes+(intent->'audio'->>'byte_count')::integer>50000000 then return jsonb_build_object('status','quota');end if;
   insert into taskfold_private.audio_comment_publications(operation_id,comment_id,asset_id,author_id,task_id,task_generation,project_id,request_hash,sha256,byte_count,caption,audio_descriptor)
    values(op,taskfold_private.audio_uuid(intent,'comment_id'),taskfold_private.audio_uuid(intent,'asset_id'),a,t,g,p,fingerprint,intent->'audio'->>'sha256',(intent->'audio'->>'byte_count')::integer,intent->>'caption',intent->'audio') returning * into x;
  end if;
  if x.state='pending' and not coalesce(taskfold_private.audio_scope(a,t,g,p,true),false) then return jsonb_build_object('status','unavailable');end if;
  if action='finalize' then
   -- Attestation is service-only. The future Storage coordinator must obtain
   -- these facts by bounded readback/hash verification, never from the app.
   if b->'stored_sha256' is distinct from to_jsonb(x.sha256) or b->'stored_bytes' is distinct from to_jsonb(x.byte_count) then return jsonb_build_object('status','verification_failed');end if;
   if x.state='pending' then update taskfold_private.audio_comment_publications set state='published',published_at=clock_timestamp() where operation_id=op returning * into x;end if;
  end if;
  return taskfold_private.audio_receipt(x,a);
 elsif action='remove' then
  if x.author_id is distinct from a and (p is null or not coalesce(public.is_project_owner(a,p),false)) then return jsonb_build_object('status','unavailable');end if;
  if x.state not in('retired','purged') then
   update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes' where operation_id=op returning * into x;
  end if;
  return jsonb_build_object('protocol',1,'account',a,'operation_id',op,'comment_id',x.comment_id,'state',x.state);
 end if;
 if x.operation_id is null or x.state is distinct from 'published' then return jsonb_build_object('status','unavailable');end if;
 return taskfold_private.audio_receipt(x,a);
end$$;

-- Explicit deletion retires media for a future Storage cleanup worker. Moves,
-- replacement generations and heading conversion must not silently retarget or
-- discard published/pending recordings; a reviewed custody operation is required.
create function taskfold_private.audio_task_custody() returns trigger
language plpgsql volatile security definer set search_path='' as $$begin
 if tg_op='UPDATE' then
  if old.project_id is not null and new.project_id is null and new.id=old.id and new.task_generation is not distinct from old.task_generation and pg_trigger_depth()>1 and not exists(select 1 from public.projects where id=old.project_id) then
   update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes' where task_id=old.id and state in('pending','published');return new;
  end if;
  if (new.id is distinct from old.id or (old.project_id is null and new.user_id is distinct from old.user_id) or new.project_id is distinct from old.project_id or new.task_generation is distinct from old.task_generation
      or (to_jsonb(new)->'is_heading'='true'::jsonb and to_jsonb(old)->'is_heading' is distinct from 'true'::jsonb))
   and exists(select 1 from taskfold_private.audio_comment_publications where task_id=old.id and state in('pending','published')) then
   raise exception using errcode='23514',message='Review recording custody before moving or replacing this task';end if;return new;
 end if;
 update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes'
  where task_id=old.id and state in('pending','published');return old;
end$$;
create trigger taskfold_audio_task_move before update on public.tasks for each row execute function taskfold_private.audio_task_custody();
create trigger taskfold_audio_task_delete after delete on public.tasks for each row execute function taskfold_private.audio_task_custody();
create function taskfold_private.audio_author_removal() returns trigger
language plpgsql volatile security definer set search_path='' as $$begin
 update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,cleanup_after=clock_timestamp()+interval '5 minutes'
  where author_id=old.id and (state='pending' or (state='published' and project_id is null));
 return old;
end$$;
create trigger taskfold_audio_author_removal before delete on auth.users for each row execute function taskfold_private.audio_author_removal();

revoke all on function taskfold_private.audio_fields(jsonb,text[]),taskfold_private.audio_uuid(jsonb,text,boolean),taskfold_private.audio_target(jsonb),taskfold_private.audio_intent(jsonb),
 taskfold_private.audio_actor(uuid,uuid),taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean),taskfold_private.audio_receipt(taskfold_private.audio_comment_publications,uuid),
 taskfold_private.audio_comment_command(text,uuid,uuid,jsonb),taskfold_private.audio_task_custody(),taskfold_private.audio_author_removal() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;

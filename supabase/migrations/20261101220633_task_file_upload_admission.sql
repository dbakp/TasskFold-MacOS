-- Local candidate. Publishing stays off until native/provider acceptance.
-- Storage metadata is read-only; bytes are written only through its API.
create table taskfold_private.task_file_upload_config (
 singleton boolean primary key default true check(singleton),enabled boolean not null default false,
 team_byte_limit bigint not null default 268435456 check(team_byte_limit between 5242880 and 1073741824)
);
insert into taskfold_private.task_file_upload_config(singleton) values(true);
create table taskfold_private.task_file_uploads (
 operation_id uuid primary key,actor_id uuid not null,team_id uuid not null,project_id uuid not null,
 task_id uuid not null,generation uuid not null,intent jsonb not null,intent_hash text not null,
 byte_count integer not null check(byte_count between 1 and 5242880),sha256 text not null,
 object_name text not null unique,state text not null check(state in('reserved','published','cancelled','expired')),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null,
 object_id uuid unique,attachment jsonb,provider_cleanup_confirmed_at timestamptz,
 check((object_id is null)=(attachment is null)),
 check((state='published')=(object_id is not null and attachment is not null)),
 check(provider_cleanup_confirmed_at is null or state in('cancelled','expired'))
);
create index task_file_uploads_quota on taskfold_private.task_file_uploads(team_id,state);
create index task_file_uploads_actor on taskfold_private.task_file_uploads(actor_id,created_at);
create table taskfold_private.task_file_admission_scope (
 transaction_id bigint not null,operation_id uuid not null,object_id uuid primary key,
 task_id uuid not null,generation uuid not null,project_id uuid not null
);
create table taskfold_private.task_file_request_budgets (
 actor_id uuid primary key references auth.users(id) on delete cascade,
 window_start timestamptz not null,requests integer not null check(requests between 1 and 121)
);
alter table taskfold_private.task_file_upload_config enable row level security;
alter table taskfold_private.task_file_uploads enable row level security;
alter table taskfold_private.task_file_admission_scope enable row level security;
alter table taskfold_private.task_file_request_budgets enable row level security;
revoke all on taskfold_private.task_file_upload_config,taskfold_private.task_file_uploads,taskfold_private.task_file_admission_scope,taskfold_private.task_file_request_budgets from public,anon,authenticated,service_role;

-- This immutable namespace has no direct client read/write or signed-URL path.
-- Download goes through the gateway and rechecks current access before return.
create policy taskfold_task_file_gateway_only on storage.objects as restrictive for all to anon,authenticated
 using(bucket_id<>'task-attachments' or name not like 'team-task-files/v1/%')
 with check(bucket_id<>'task-attachments' or name not like 'team-task-files/v1/%');

create function taskfold_private.task_file_actor(a uuid,s uuid) returns boolean
language plpgsql volatile security invoker set search_path='' as $$
begin
 if a is null or s is null then return false;end if;
 perform 1 from auth.users where id=a and email_confirmed_at is not null and coalesce(email,'')<>''
  and (banned_until is null or banned_until<=clock_timestamp()) for share;
 if not found then return false;end if;
 perform 1 from auth.sessions where id=s and user_id=a and (not_after is null or not_after>clock_timestamp()) for share;
 return found and not exists(select 1 from taskfold_private.account_removal_receipts where account_id=a and created_at>clock_timestamp()-interval '7 days');
end$$;
create function taskfold_private.task_file_access(a uuid,team uuid,p uuid,writable boolean) returns boolean
language plpgsql volatile security invoker set search_path='' as $$
declare role text;
begin
 perform 1 from taskfold_private.teams where id=team and state='active' for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and (not writable or native_task_edits_enabled) for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then return false;end if;
 perform 1 from public.projects where id=p and (not writable or (not is_archived and not ancestor_archived)) for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_members where team_id=team and user_id=a for share;
 perform 1 from taskfold_private.team_project_grants where project_id=p and user_id=a for share;
 role:=taskfold_private.team_project_role(a,p);
 return coalesce(role is not null and (not writable or role in('owner','admin','manager','editor')),false);
end$$;
create function taskfold_private.task_file_receipt(r taskfold_private.task_file_uploads) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('protocol',1,'account',r.actor_id,'operation_id',r.operation_id,
 'target',jsonb_build_object('team_id',r.team_id,'project_id',r.project_id,'task_id',r.task_id,'task_generation',r.generation),
 'state',r.state,'attachment',r.attachment)
$$;

-- A service-owned object may enter custody only during exact finalization.
-- Preserve the existing uploader checks for every other file/binding.
do $migration$
declare d text;anchor text:=' if tg_op=''UPDATE'' and new is distinct from old';begin
 d:=pg_get_functiondef('taskfold_private.guard_team_content_file()'::regprocedure);
 if strpos(d,'TASKFOLD_FILE_ADMISSION_V1')=0 then
  if strpos(d,anchor)=0 then raise exception 'Current file custody guard required';end if;
  -- Insert immediately after BEGIN, before any uploader check or move branch.
  d:=regexp_replace(d,'begin', $guard$begin
 -- TASKFOLD_FILE_ADMISSION_V1
 if tg_op='INSERT' and exists(select 1 from taskfold_private.task_file_admission_scope x
  join taskfold_private.task_file_uploads u on u.operation_id=x.operation_id and u.state='reserved'
  join storage.objects o on o.id=x.object_id and o.bucket_id='task-attachments' and o.name=u.object_name
  join storage.buckets b on b.id=o.bucket_id and not b.public
  where x.transaction_id=txid_current() and x.object_id=new.object_id and x.task_id=new.task_id
   and x.generation=new.task_generation and x.project_id=new.project_id
   and u.task_id=x.task_id and u.generation=x.generation and u.project_id=x.project_id
   and coalesce(o.owner_id,o.owner::text) is null
   and not exists(select 1 from taskfold_private.team_content_file_removals pending where pending.object_id=new.object_id)) then return new;end if;
 $guard$);
  execute d;
 end if;
end$migration$;

create function taskfold_private.task_file_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare intent jsonb;op uuid;team uuid;p uuid;t uuid;g uuid;h text;r taskfold_private.task_file_uploads;
 root public.tasks;asset storage.objects;config taskfold_private.task_file_upload_config;count integer;n integer;mime text;filename text;size integer;new_attachment jsonb;
begin
 if action is null or action not in('reserve','finalize','resolve','cancel','download') or jsonb_typeof(b) is distinct from 'object' then
  raise exception using errcode='22023',message='Invalid file operation';end if;
 if not taskfold_private.task_file_actor(a,s) then return jsonb_build_object('status','unavailable');end if;
 -- Include retries and both download authorization passes in a live per-actor
 -- budget. Untrusted callers cannot choose the clock or reset this window.
 insert into taskfold_private.task_file_request_budgets(actor_id,window_start,requests)
  values(a,date_trunc('minute',clock_timestamp()),1)
  on conflict(actor_id) do update set window_start=excluded.window_start,
   requests=case when task_file_request_budgets.window_start=excluded.window_start then least(121,task_file_request_budgets.requests+1) else 1 end
  returning requests into n;
 if n>120 then return jsonb_build_object('status','rate_limited','retry_after',greatest(1,least(60,ceil(extract(epoch from date_trunc('minute',clock_timestamp())+interval '1 minute'-clock_timestamp()))::integer)));end if;
 if action='download' then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['object_id','task_generation','task_id']::text[] then raise exception using errcode='22023',message='Invalid file request';end if;
  select * into root from public.tasks where id=(b->>'task_id')::uuid and task_generation=(b->>'task_generation')::uuid for share nowait;
  if not found then return jsonb_build_object('status','unavailable');end if;
  select u.* into r from taskfold_private.task_file_uploads u join taskfold_private.team_content_files f on f.object_id=u.object_id
   join storage.objects o on o.id=f.object_id and o.bucket_id='task-attachments' and o.name=u.object_name
   join storage.buckets bucket on bucket.id=o.bucket_id and not bucket.public
   where u.object_id=(b->>'object_id')::uuid and u.state='published' and f.task_id=root.id and f.task_generation=root.task_generation and f.project_id=root.project_id
   and coalesce(o.owner_id,o.owner::text) is null and to_jsonb(o)->'metadata'->'size'=u.intent->'byte_count' and to_jsonb(o)->'metadata'->'mimetype'=u.intent->'type'
   for share of u,f,o,bucket nowait;
  if not found or not taskfold_private.task_file_access(a,r.team_id,root.project_id,false) then return jsonb_build_object('status','unavailable');end if;
  if not (taskfold_private.task_file_references(to_jsonb(root))->'ids' ? r.object_id::text) then return jsonb_build_object('status','unavailable');end if;
  return jsonb_build_object('status','download','object_name',r.object_name,'sha256',r.sha256,'byte_count',r.byte_count,'mime',r.intent->>'type');
 end if;
 if action in('resolve','cancel') then
  if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['operation_id']::text[] then raise exception using errcode='22023',message='Invalid file request';end if;
  op:=(b->>'operation_id')::uuid;
 else
  if action='reserve' then intent:=b;
  else
   if (select array_agg(k order by k) from jsonb_object_keys(b) k) is distinct from array['intent','stored_bytes','stored_sha256']::text[] then raise exception using errcode='22023',message='Invalid file proof';end if;
   intent:=b->'intent';
  end if;
  if jsonb_typeof(intent) is distinct from 'object' or (select array_agg(k order by k) from jsonb_object_keys(intent) k) is distinct from
    array['byte_count','name','operation_id','sha256','target','type']::text[]
   or jsonb_typeof(intent->'target') is distinct from 'object' or (select array_agg(k order by k) from jsonb_object_keys(intent->'target') k) is distinct from
    array['project_id','task_generation','task_id','team_id']::text[] then raise exception using errcode='22023',message='Invalid file intent';end if;
  if exists(select 1 from jsonb_each(intent) where key<>'target' and key<>'byte_count' and jsonb_typeof(value)<>'string')
   or exists(select 1 from jsonb_each(intent->'target') where jsonb_typeof(value)<>'string')
   or jsonb_typeof(intent->'byte_count') is distinct from 'number' or (intent->>'byte_count')!~'^[0-9]{1,7}$'
   or (intent->>'sha256')!~'^[a-f0-9]{64}$' then raise exception using errcode='22023',message='Invalid file descriptor';end if;
  size:=(intent->>'byte_count')::integer;mime:=intent->>'type';filename:=intent->>'name';
  if size not between 1 and 5242880 or length(filename) not between 1 and 240 or filename ~ '[[:cntrl:]/\\]' or filename in('.','..')
   or mime not in('application/pdf','application/octet-stream','application/zip','image/png','image/jpeg','image/webp','text/plain') then raise exception using errcode='22023',message='Review this file before uploading';end if;
  op:=(intent->>'operation_id')::uuid;team:=(intent->'target'->>'team_id')::uuid;p:=(intent->'target'->>'project_id')::uuid;
  t:=(intent->'target'->>'task_id')::uuid;g:=(intent->'target'->>'task_generation')::uuid;
  if op is null or team is null or p is null or t is null or g is null then raise exception using errcode='22023',message='Missing file identity';end if;
  h:=encode(extensions.digest(convert_to(intent::text,'UTF8'),'sha256'),'hex');
 end if;
 if op is null then raise exception using errcode='22023',message='Missing operation identity';end if;
 -- Consistent operation serialization covers cold/concurrent first reservations.
 perform pg_advisory_xact_lock(hashtextextended('task-file:'||op::text,20261101));
 select * into r from taskfold_private.task_file_uploads where operation_id=op for update;
 if found then
  if r.actor_id<>a then return jsonb_build_object('status','unavailable');end if;
  if action not in('resolve','cancel') and r.intent_hash<>h then return jsonb_build_object('status','conflict');end if;
  team:=r.team_id;p:=r.project_id;t:=r.task_id;g:=r.generation;
 elsif action<>'reserve' then return jsonb_build_object('status','unavailable');end if;
 -- The original author may recover publication after a same-team project move,
 -- but only with current destination access; no stale source grant is borrowed.
 select * into root from public.tasks where id=t and task_generation=g for update nowait;
 if not found or (r.state is distinct from 'published' and root.project_id is distinct from p)
  or not taskfold_private.task_file_access(a,team,root.project_id,action in('reserve','finalize') and r.state is distinct from 'published') then
  return jsonb_build_object('status','unavailable');end if;
 if r.state='published' then return jsonb_build_object('status','published','receipt',taskfold_private.task_file_receipt(r));end if;
 if r.state in('cancelled','expired') then return jsonb_build_object('status',r.state,'receipt',taskfold_private.task_file_receipt(r));end if;
 if r.operation_id is not null and (action='cancel' or r.expires_at<=clock_timestamp()) then
  update taskfold_private.task_file_uploads set state=case when action='cancel' then 'cancelled' else 'expired' end where operation_id=op returning * into r;
  return jsonb_build_object('status',r.state,'receipt',taskfold_private.task_file_receipt(r));
 end if;
 if action='resolve' then return jsonb_build_object('status','reserved','receipt',taskfold_private.task_file_receipt(r));end if;
 select * into config from taskfold_private.task_file_upload_config where singleton and enabled for share;
 if not found then return jsonb_build_object('status','disabled');end if;
 perform 1 from storage.buckets where id='task-attachments' and not public for share;
 if not found then return jsonb_build_object('status','disabled');end if;
 if r.operation_id is null then
  -- One team lock serializes quota checks across different actors/operations.
  perform pg_advisory_xact_lock(hashtextextended('task-file-team:'||team::text,20261101));
  -- Cancellation/expiry is not proof of provider deletion: charge all allocated
  -- bytes until a future fenced cleanup worker confirms the object is removed.
  if (select coalesce(sum(byte_count),0)+size from taskfold_private.task_file_uploads where team_id=team and provider_cleanup_confirmed_at is null)>config.team_byte_limit
   or (select count(*) from taskfold_private.task_file_uploads where actor_id=a and state='reserved' and expires_at>clock_timestamp())>=5
   or (select count(*) from taskfold_private.task_file_uploads where actor_id=a and created_at>clock_timestamp()-interval '1 minute')>=12 then return jsonb_build_object('status','quota');end if;
  if coalesce(jsonb_typeof(root.attachments),'null') not in('null','array') or coalesce(jsonb_array_length(nullif(root.attachments,'null'::jsonb)),0)>=256 then raise exception using errcode='PT409',message='Review existing attachments first';end if;
  if (taskfold_private.task_file_references(to_jsonb(root))->>'legacy')::boolean then raise exception using errcode='PT409',message='Review older provider files first';end if;
  insert into taskfold_private.task_file_uploads(operation_id,actor_id,team_id,project_id,task_id,generation,intent,intent_hash,byte_count,sha256,object_name,state,expires_at)
   values(op,a,team,p,t,g,intent,h,size,intent->>'sha256','team-task-files/v1/'||op::text,'reserved',clock_timestamp()+interval '15 minutes') returning * into r;
 end if;
 if action='reserve' then return jsonb_build_object('status','reserved','object_name',r.object_name,'receipt',taskfold_private.task_file_receipt(r));end if;
 if b->'stored_sha256' is distinct from r.intent->'sha256' or b->'stored_bytes' is distinct from r.intent->'byte_count' then return jsonb_build_object('status','verification_failed');end if;
 select count(*) into n from storage.objects where bucket_id='task-attachments' and name=r.object_name;
 if n<>1 then return jsonb_build_object('status','verification_failed');end if;
 select * into asset from storage.objects where bucket_id='task-attachments' and name=r.object_name for share nowait;
 if coalesce(asset.owner_id,asset.owner::text) is not null or to_jsonb(asset)->'metadata'->'size' is distinct from r.intent->'byte_count'
  or to_jsonb(asset)->'metadata'->'mimetype' is distinct from r.intent->'type' then return jsonb_build_object('status','verification_failed');end if;
 if coalesce(jsonb_typeof(root.attachments),'null') not in('null','array') or coalesce(jsonb_array_length(nullif(root.attachments,'null'::jsonb)),0)>=256
  or exists(select 1 from jsonb_array_elements(coalesce(root.attachments,'[]')) x where x->>'id'=op::text) then raise exception using errcode='PT409',message='Review the current attachments';end if;
 insert into taskfold_private.task_file_admission_scope values(txid_current(),op,asset.id,t,g,p);
 insert into taskfold_private.team_content_files(object_id,project_id,task_id,task_generation) values(asset.id,p,t,g);
 new_attachment:=jsonb_build_object('id',op,'storage_object_id',asset.id,'name',r.intent->>'name','size',r.byte_count,'type',r.intent->>'type','sha256',r.sha256,'uploadedAt',clock_timestamp());
 update public.tasks set attachments=coalesce(nullif(attachments,'null'::jsonb),'[]')||jsonb_build_array(new_attachment) where id=t;
 update taskfold_private.task_file_uploads set state='published',object_id=asset.id,attachment=new_attachment where operation_id=op returning * into r;
 delete from taskfold_private.task_file_admission_scope where transaction_id=txid_current() and operation_id=op;
 return jsonb_build_object('status','published','receipt',taskfold_private.task_file_receipt(r));
exception when lock_not_available then raise exception using errcode='PT409',message='The task or file is busy. Retry this operation';
end$$;
revoke all on function taskfold_private.task_file_actor(uuid,uuid),taskfold_private.task_file_access(uuid,uuid,uuid,boolean),taskfold_private.task_file_receipt(taskfold_private.task_file_uploads),taskfold_private.task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.task_file_command(text,uuid,uuid,jsonb) to service_role;
create function public.taskfold_task_file_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.task_file_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_task_file_command(text,uuid,uuid,jsonb) to service_role;
notify pgrst,'reload schema';

-- Disabled private preparation. Copies do not publish files or move projects.
create table taskfold_private.project_file_preparation_config(singleton boolean primary key default true check(singleton),enabled boolean not null default false);
insert into taskfold_private.project_file_preparation_config values(true,false);
create table taskfold_private.project_file_preparations(
 id uuid primary key default gen_random_uuid(),actor_id uuid not null references auth.users(id) on delete cascade,
 request_id uuid not null,team_id uuid not null,scope jsonb not null,inspection_token text not null,fingerprint text not null,
 state text not null default 'open' check(state in('open','cancelled','committed')),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default clock_timestamp()+interval '24 hours',
 unique(actor_id,request_id)
);
create table taskfold_private.project_file_preparation_items(
 operation_id uuid primary key default gen_random_uuid(),plan_id uuid not null references taskfold_private.project_file_preparations(id) on delete cascade,
 task_id uuid not null,generation uuid not null,project_id uuid not null,source_object uuid not null,source_name text not null,label text not null,
 byte_count integer not null check(byte_count between 1 and 5242880),mime text not null,
 phase text not null default 'waiting' check(phase in('waiting','reserved','ready')),sha256 text,copy_object uuid,
 check((phase='waiting' and sha256 is null and copy_object is null) or (phase='reserved' and sha256~'^[0-9a-f]{64}$' and copy_object is null) or (phase='ready' and sha256~'^[0-9a-f]{64}$' and copy_object is not null)),
 unique(plan_id,task_id,source_object)
);
create index project_file_preparations_actor on taskfold_private.project_file_preparations(actor_id,expires_at);
create index project_file_preparation_items_plan on taskfold_private.project_file_preparation_items(plan_id,operation_id);
alter table taskfold_private.project_file_preparation_config enable row level security;
alter table taskfold_private.project_file_preparations enable row level security;
alter table taskfold_private.project_file_preparation_items enable row level security;
revoke all on taskfold_private.project_file_preparation_config,taskfold_private.project_file_preparations,taskfold_private.project_file_preparation_items from public,anon,authenticated,service_role;

create function taskfold_private.project_file_source_label(document jsonb,object_id uuid) returns text
language sql immutable security invoker set search_path='' as $$
 with recursive nodes(doc,depth) as (
  select document,0 union all
  select x.value,n.depth+1 from nodes n cross join lateral jsonb_array_elements(case when jsonb_typeof(n.doc->'subtasks')='array' then n.doc->'subtasks' else '[]'::jsonb end) x where n.depth<32
 ), entries(value) as (
  select x.value from nodes n cross join lateral jsonb_array_elements(case when jsonb_typeof(n.doc->'attachments')='array' then n.doc->'attachments' else '[]'::jsonb end) x
  union all select x.value->'attachment' from nodes n cross join lateral jsonb_array_elements(case when jsonb_typeof(n.doc->'comments')='array' then n.doc->'comments' else '[]'::jsonb end) x
 ) select coalesce((select value->>'name' from entries where lower(value->>'storage_object_id')=object_id::text
  and jsonb_typeof(value->'name')='string' and length(value->>'name') between 1 and 240 and octet_length(value->>'name')<=960 and value->>'name' !~ '[[:cntrl:]]'
  order by value::text limit 1),'Project attachment')
$$;

create function taskfold_private.project_file_preparation_reply(p taskfold_private.project_file_preparations,after_id uuid default null) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare total integer;ready integer;items jsonb;next_id uuid;begin
 select count(*)::integer,count(*) filter(where phase='ready')::integer into total,ready from taskfold_private.project_file_preparation_items where plan_id=p.id;
 select coalesce(jsonb_agg(jsonb_build_object('operation_id',operation_id,'label',label,'byte_count',byte_count,'type',mime,'state',phase) order by operation_id),'[]'),(array_agg(operation_id order by operation_id desc))[1] into items,next_id
 from(select * from taskfold_private.project_file_preparation_items where plan_id=p.id and (after_id is null or operation_id>after_id) order by operation_id limit 100) page;
 if not exists(select 1 from taskfold_private.project_file_preparation_items where plan_id=p.id and operation_id>next_id) then next_id:=null;end if;
 return jsonb_build_object('protocol',1,'plan_id',p.id,'request_id',p.request_id,'scope',p.scope,'state',case when p.state<>'open' then p.state when p.expires_at<=clock_timestamp() then 'expired' when ready=total then 'ready' else 'preparing' end,
  'total',total,'prepared',ready,'expires_at',to_char(p.expires_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),'items',items,'next',next_id,'project_transferred',false);
end$$;

create function taskfold_private.project_file_preparation_current(p taskfold_private.project_file_preparations) returns boolean
language plpgsql volatile security invoker set search_path='' as $$declare i jsonb;begin
 if p.actor_id is distinct from auth.uid() or p.state<>'open' or p.expires_at<=clock_timestamp() then return false;end if;
 i:=taskfold_private.project_adoption_review('inspect',p.scope);
 return i->>'inspection_token'=p.inspection_token;
 exception when sqlstate '42501' or sqlstate 'PT409' or sqlstate 'PT503' then return false;
end$$;

create function taskfold_private.project_file_preparation_impl(action text,a uuid,b jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare p taskfold_private.project_file_preparations;j taskfold_private.project_file_preparation_items;u taskfold_private.task_file_uploads;
 root public.tasks;object_id uuid;asset storage.objects;bucket storage.buckets;inspection jsonb;ids uuid[];r jsonb;scope jsonb;intent jsonb;fingerprint text;
 nonce uuid;ticket uuid;count integer;total_bytes bigint;used bigint;config taskfold_private.task_file_upload_config;mime text;
begin
 if action='prepare' then
  perform taskfold_private.project_adoption_fields(b,array['request_id','scope','inspection_token']);
  fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
  select * into p from taskfold_private.project_file_preparations where actor_id=a and request_id=(b->>'request_id')::uuid for update nowait;
  if found then if p.fingerprint<>fingerprint then return jsonb_build_object('status','conflict');end if;return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));end if;
  if not exists(select 1 from taskfold_private.project_file_preparation_config where singleton and enabled) then return jsonb_build_object('status','disabled');end if;
  if (select count(*) from taskfold_private.project_file_preparations where actor_id=a and state='open' and expires_at>clock_timestamp())>=4 then return jsonb_build_object('status','quota');end if;
  scope:=b->'scope';inspection:=taskfold_private.project_adoption_review('inspect',scope);
  if inspection->>'inspection_token' is distinct from b->>'inspection_token' then return jsonb_build_object('status','conflict');end if;
  r:=inspection->'contents'->'file_custody';
  if (r->>'stored')::integer not between 1 and 10000 or (r->>'legacy')::integer<>0 or (r->>'unavailable')::integer<>0 then return jsonb_build_object('status','review');end if;
  select array_agg((value->>'id')::uuid order by value->>'id') into ids from jsonb_array_elements(inspection->'projects');
  -- Inspect everything before writing a plan, including typed byte-count bounds.
  total_bytes:=0;count:=0;
  for root in select * from public.tasks where project_id=any(ids) order by id loop
   for object_id in select value::uuid from jsonb_array_elements_text(taskfold_private.project_adoption_file_references(to_jsonb(root))->'ids') order by value loop
    select * into asset from storage.objects o where o.id=object_id and o.bucket_id='task-attachments' and coalesce(o.owner_id,o.owner::text)=a::text and split_part(o.name,'/',1)=a::text
     and not exists(select 1 from taskfold_private.team_content_files f where f.object_id=o.id);
    if not found or jsonb_typeof(asset.metadata->'size') is distinct from 'number' or (asset.metadata->>'size')!~'^[0-9]{1,7}$' or (asset.metadata->>'size')::integer not between 1 and 5242880 then return jsonb_build_object('status','review');end if;
    total_bytes:=total_bytes+(asset.metadata->>'size')::integer;count:=count+1;
   end loop;
  end loop;
  select * into config from taskfold_private.task_file_upload_config where singleton and enabled for share;
  if not found then return jsonb_build_object('status','disabled');end if;
  if total_bytes>config.team_byte_limit or count<>(r->>'stored')::integer then return jsonb_build_object('status','quota');end if;
  insert into taskfold_private.project_file_preparations(actor_id,request_id,team_id,scope,inspection_token,fingerprint)
   values(a,(b->>'request_id')::uuid,(scope->>'team_id')::uuid,scope,b->>'inspection_token',fingerprint) returning * into p;
  for root in select * from public.tasks where project_id=any(ids) order by id loop
   for object_id in select value::uuid from jsonb_array_elements_text(taskfold_private.project_adoption_file_references(to_jsonb(root))->'ids') order by value loop
    select * into asset from storage.objects where id=object_id;
    mime:=asset.metadata->>'mimetype';if mime not in('application/pdf','application/octet-stream','application/zip','image/png','image/jpeg','image/webp','text/plain') or mime is null then mime:='application/octet-stream';end if;
    insert into taskfold_private.project_file_preparation_items(plan_id,task_id,generation,project_id,source_object,source_name,label,byte_count,mime)
     values(p.id,root.id,root.task_generation,root.project_id,object_id,asset.name,taskfold_private.project_file_source_label(to_jsonb(root),object_id),(asset.metadata->>'size')::integer,mime);
   end loop;
  end loop;
  return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));
 end if;
 if action not in('check','cancel','source','reserve','verify') then raise exception using errcode='22023',message='Choose a supported file preparation action';end if;
 if action in('check','cancel') then perform taskfold_private.project_adoption_fields(b,case when action='check' then array['plan_id','after'] else array['plan_id'] end);
 elsif action='source' then perform taskfold_private.project_adoption_fields(b,array['plan_id','operation_id']);
 elsif action='reserve' then perform taskfold_private.project_adoption_fields(b,array['plan_id','operation_id','sha256','byte_count']);
 else perform taskfold_private.project_adoption_fields(b,array['plan_id','operation_id']);end if;
 select * into p from taskfold_private.project_file_preparations where id=(b->>'plan_id')::uuid and actor_id=a for update nowait;
 if not found then return jsonb_build_object('status','unavailable');end if;
 if action='check' then return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p,(b->>'after')::uuid));end if;
 if action='cancel' then
  if p.state='committed' then return jsonb_build_object('status','conflict');end if;
  update taskfold_private.project_file_preparations set state='cancelled' where id=p.id returning * into p;
  -- Normal fenced maintenance retains charges until provider cleanup is proved.
  update taskfold_private.task_file_uploads set state='cancelled' where operation_id in(select operation_id from taskfold_private.project_file_preparation_items where plan_id=p.id) and state='reserved';
  return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));
 end if;
 if not exists(select 1 from taskfold_private.project_file_preparation_config where singleton and enabled) then return jsonb_build_object('status','disabled');end if;
 if not taskfold_private.project_file_preparation_current(p) then return jsonb_build_object('status','source_changed');end if;
 select * into j from taskfold_private.project_file_preparation_items where plan_id=p.id and operation_id=(b->>'operation_id')::uuid for update nowait;
 if not found then return jsonb_build_object('status','unavailable');end if;
 if j.phase='ready' then return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));end if;
 if action='source' then return jsonb_build_object('status','source','source_name',j.source_name,'byte_count',j.byte_count,'mime',j.mime);end if;
 if not pg_try_advisory_xact_lock(hashtextextended('task-file:'||j.operation_id::text,20261101)) then return jsonb_build_object('status','busy');end if;
 select * into u from taskfold_private.task_file_uploads where operation_id=j.operation_id for update nowait;
 if action='reserve' then
  select * into config from taskfold_private.task_file_upload_config where singleton and enabled for share;if not found then return jsonb_build_object('status','disabled');end if;
  if jsonb_typeof(b->'sha256') is distinct from 'string' or (b->>'sha256')!~'^[a-f0-9]{64}$' or b->'byte_count' is distinct from to_jsonb(j.byte_count) then return jsonb_build_object('status','verification_failed');end if;
  intent:=jsonb_build_object('operation_id',j.operation_id,'target',jsonb_build_object('team_id',p.team_id,'project_id',j.project_id,'task_id',j.task_id,'task_generation',j.generation),'name','Project attachment','type',j.mime,'byte_count',j.byte_count,'sha256',b->'sha256');
  fingerprint:=encode(extensions.digest(convert_to(intent::text,'UTF8'),'sha256'),'hex');
  if u.operation_id is null then
   select * into config from taskfold_private.task_file_upload_config where singleton and enabled for share;if not found then return jsonb_build_object('status','disabled');end if;
   select coalesce(sum(byte_count),0) into used from taskfold_private.task_file_uploads where team_id=p.team_id and provider_cleanup_confirmed_at is null;
   if used+j.byte_count>config.team_byte_limit then return jsonb_build_object('status','quota');end if;
   nonce:=gen_random_uuid();insert into taskfold_private.task_file_uploads(operation_id,actor_id,team_id,project_id,task_id,generation,intent,intent_hash,byte_count,sha256,object_name,state,expires_at,writer_protocol,object_nonce)
    values(j.operation_id,a,p.team_id,j.project_id,j.task_id,j.generation,intent,fingerprint,j.byte_count,b->>'sha256','team-task-files/v1/'||j.operation_id::text||'/'||nonce::text,'reserved',p.expires_at,1,nonce) returning * into u;
   update taskfold_private.project_file_preparation_items set phase='reserved',sha256=b->>'sha256' where operation_id=j.operation_id;
  elsif u.actor_id<>a or u.intent_hash<>fingerprint or u.state<>'reserved' or u.expires_at<=clock_timestamp() or u.provider_cleanup_confirmed_at is not null then return jsonb_build_object('status','conflict');end if;
  select ticket_id into ticket from taskfold_private.task_file_write_attempts where operation_id=u.operation_id and state='open';
  if found then return jsonb_build_object('status','verify','object_name',u.object_name,'sha256',u.sha256,'byte_count',u.byte_count,'mime',j.mime,'ticket_id',ticket);end if;
  if exists(select 1 from storage.objects where bucket_id='task-attachments' and name=u.object_name) then
   select ticket_id into ticket from taskfold_private.task_file_write_attempts where operation_id=u.operation_id order by started_at desc,ticket_id limit 1;
   if ticket is null then return jsonb_build_object('status','verification_failed');end if;
   return jsonb_build_object('status','verify','object_name',u.object_name,'sha256',u.sha256,'byte_count',u.byte_count,'mime',j.mime,'ticket_id',ticket);
  end if;
  insert into taskfold_private.task_file_write_attempts(operation_id) values(u.operation_id) returning ticket_id into ticket;
  return jsonb_build_object('status','upload','object_name',u.object_name,'sha256',u.sha256,'byte_count',u.byte_count,'mime',j.mime,'ticket_id',ticket);
 end if;
 if u.operation_id is null or u.actor_id<>a or u.state<>'reserved' or u.writer_protocol<>1 or u.expires_at<=clock_timestamp()
  or not exists(select 1 from taskfold_private.task_file_write_attempts where operation_id=u.operation_id and state='settled')
  or exists(select 1 from taskfold_private.task_file_write_attempts where operation_id=u.operation_id and state='open') then return jsonb_build_object('status','verification_failed');end if;
 select * into asset from storage.objects where bucket_id='task-attachments' and name=u.object_name for share nowait;
 select * into bucket from storage.buckets where id='task-attachments' and not public for share nowait;
 if asset.id is null or bucket.id is null or coalesce(asset.owner_id,asset.owner::text) is not null
  or asset.metadata->'size' is distinct from to_jsonb(u.byte_count) or asset.metadata->'mimetype' is distinct from to_jsonb(j.mime) then return jsonb_build_object('status','verification_failed');end if;
 update taskfold_private.project_file_preparation_items set phase='ready',copy_object=asset.id where operation_id=j.operation_id;
 return jsonb_build_object('status','plan','plan',taskfold_private.project_file_preparation_reply(p));
 exception when lock_not_available then return jsonb_build_object('status','busy');
end$$;

create function taskfold_private.project_file_preparation_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare claims text;sub text;result jsonb;begin
 if action is null or jsonb_typeof(b) is distinct from 'object' or octet_length(b::text)>262144 then raise exception using errcode='22023',message='Invalid file preparation';end if;
 result:=taskfold_private.task_file_admit(a,s);if result is not null then return result;end if;
 claims:=current_setting('request.jwt.claims',true);sub:=current_setting('request.jwt.claim.sub',true);
 -- Only the service-role wrapper can enter this authenticated actor context.
 perform set_config('request.jwt.claims',jsonb_build_object('sub',a,'session_id',s,'role','authenticated')::text,true);
 perform set_config('request.jwt.claim.sub',a::text,true);
 result:=taskfold_private.project_file_preparation_impl(action,a,b);
 perform set_config('request.jwt.claims',coalesce(claims,''),true);perform set_config('request.jwt.claim.sub',coalesce(sub,''),true);
 return result;
end$$;
revoke all on function taskfold_private.project_file_source_label(jsonb,uuid),taskfold_private.project_file_preparation_reply(taskfold_private.project_file_preparations,uuid),taskfold_private.project_file_preparation_current(taskfold_private.project_file_preparations),taskfold_private.project_file_preparation_impl(text,uuid,jsonb),taskfold_private.project_file_preparation_command(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.project_file_preparation_command(text,uuid,uuid,jsonb) to service_role;
create function public.taskfold_project_file_preparation(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.project_file_preparation_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_project_file_preparation(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_project_file_preparation(text,uuid,uuid,jsonb) to service_role;
notify pgrst,'reload schema';

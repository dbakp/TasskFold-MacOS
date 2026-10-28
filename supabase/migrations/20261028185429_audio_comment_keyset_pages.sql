-- Forward-only keyset pages. A cursor is a position, never authority; every page
-- rechecks the live actor/session and the exact current task/project scope.
create function taskfold_private.audio_comment_page(a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' set timezone='UTC' as $$
declare target jsonb;cursor_value jsonb;t uuid;g uuid;p uuid;stamp timestamptz;id uuid;rows jsonb;next_value jsonb;begin
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 if not coalesce((select enabled from taskfold_private.audio_comment_config where singleton),false) or not taskfold_private.audio_bucket_ready() then return jsonb_build_object('status','disabled');end if;
 perform taskfold_private.audio_fields(b,array['target','after']);target=b->'target';perform taskfold_private.audio_target(target);
 t=taskfold_private.audio_uuid(target,'task_id');g=taskfold_private.audio_uuid(target,'task_generation');p=taskfold_private.audio_uuid(target,'project_id',true);
 cursor_value=b->'after';
 if cursor_value<>'null'::jsonb then
  perform taskfold_private.audio_fields(cursor_value,array['published_at','comment_id']);id=taskfold_private.audio_uuid(cursor_value,'comment_id');
  if jsonb_typeof(cursor_value->'published_at') is distinct from 'string' or length(cursor_value->>'published_at')>40
   or (cursor_value->>'published_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|\+00:00)$' then raise exception using errcode='22023',message='Review this recording position';end if;
  stamp=(cursor_value->>'published_at')::timestamptz;
 end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||t::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false) or not coalesce(taskfold_private.audio_scope(a,t,g,p,false),false) then return jsonb_build_object('status','unavailable');end if;
 -- Existing published-only (task,generation,published_at,comment_id) index serves
 -- the seek and order. One lookahead row determines whether a next page exists.
 select coalesce(jsonb_agg(taskfold_private.audio_receipt(q,a) order by q.published_at,q.comment_id),'[]'::jsonb) into rows from
  (select * from taskfold_private.audio_comment_publications where task_id=t and task_generation=g and project_id is not distinct from p and state='published'
   and (stamp is null or (published_at,comment_id)>(stamp,id)) order by published_at,comment_id limit 21) q;
 next_value='null'::jsonb;
 if jsonb_array_length(rows)>20 then
  next_value=jsonb_build_object('published_at',rows->19->'published_at','comment_id',rows->19->'comment_id');rows=rows-20;
 end if;
 return jsonb_build_object('protocol',1,'account',a,'items',rows,'next',next_value);
end$$;
revoke all on function taskfold_private.audio_comment_page(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_page(uuid,uuid,jsonb) to service_role;
create function public.taskfold_audio_comment_page(_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_page(_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_page(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_page(uuid,uuid,jsonb) to service_role;

-- Permit paged conversations up to 100 retained recordings per task. Preserve
-- the independent 100-per-author, 250 MB author and 50 MB task byte quotas.
create or replace function taskfold_private.audio_comment_ledger_v1(action text,a uuid,s uuid,b jsonb) returns jsonb
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
   if n>=100 or bytes+(intent->'audio'->>'byte_count')::integer>50000000 then return jsonb_build_object('status','quota');end if;
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
revoke all on function taskfold_private.audio_comment_ledger_v1(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;

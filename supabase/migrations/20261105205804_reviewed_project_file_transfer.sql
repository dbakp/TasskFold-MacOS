-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Undeployed: explicit reviewed copy policy, atomic project/custody commit.
-- Original objects remain private and unchanged; SQL never mutates Storage.
-- File and project custody are one atomic graph. Keep the same parent FK,
-- checked at commit, while exact private admission installs file bindings before
-- the root-reference guard and the subsequent reviewed project insertion.
alter table taskfold_private.team_content_files alter constraint team_content_files_project_id_fkey deferrable initially deferred;
alter table taskfold_private.project_file_preparation_config add column transfer_enabled boolean not null default false;
alter table taskfold_private.project_adoption_receipts
 add column file_plan_id uuid,add column file_count integer not null default 0,add column file_bytes bigint not null default 0,
 add constraint project_file_receipt_shape check((file_plan_id is null and file_count=0 and file_bytes=0) or (file_plan_id is not null and file_count between 1 and 10000 and file_bytes between 1 and 1073741824));

create function taskfold_private.project_file_transfer_inventory(plan uuid) returns text
language sql stable security invoker set search_path='' as $$
 select encode(extensions.digest(convert_to(coalesce(jsonb_agg(jsonb_build_array(to_jsonb(j),to_jsonb(u),to_jsonb(o)-array['created_at','updated_at','last_accessed_at']) order by j.operation_id),'[]')::text,'UTF8'),'sha256'),'hex')
 from taskfold_private.project_file_preparation_items j join taskfold_private.task_file_uploads u on u.operation_id=j.operation_id
 join storage.objects o on o.id=j.copy_object where j.plan_id=plan
$$;

create function taskfold_private.review_project_file_policy(policy jsonb,scope jsonb,inspection text) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare p taskfold_private.project_file_preparations;n integer;bytes bigint;fresh jsonb;digest text;begin
 perform taskfold_private.project_adoption_fields(policy,array['protocol','plan_id','action']);
 if policy->'protocol' is distinct from '1'::jsonb or policy->'action' is distinct from '"share_copies_keep_originals"'::jsonb then
  raise exception using errcode='22023',message='Choose the reviewed private-copy file policy';end if;
 perform 1 from taskfold_private.project_file_preparation_config where singleton and enabled and transfer_enabled for share;
 if not found then raise exception using errcode='PT503',message='Project file transfers are not enabled';end if;
 select * into p from taskfold_private.project_file_preparations where id=taskfold_private.team_uuid(policy,'plan_id') and actor_id=auth.uid() for update nowait;
 if not found or p.state<>'open' or p.expires_at<=clock_timestamp() or p.scope is distinct from scope or p.inspection_token is distinct from inspection then
  raise exception using errcode='PT409',message='Prepare files for this exact project review again';end if;
 select count(*)::integer,coalesce(sum(byte_count),0) into n,bytes from taskfold_private.project_file_preparation_items where plan_id=p.id;
 if n not between 1 and 10000 or exists(select 1 from taskfold_private.project_file_preparation_items where plan_id=p.id and phase<>'ready') then
  raise exception using errcode='PT409',message='Finish preparing every file before approving this transfer';end if;
 perform 1 from taskfold_private.project_file_preparation_items where plan_id=p.id order by operation_id for update nowait;
 perform 1 from taskfold_private.task_file_uploads u join taskfold_private.project_file_preparation_items j using(operation_id) where j.plan_id=p.id order by u.operation_id for update of u nowait;
 perform 1 from storage.buckets where id='task-attachments' and not public for share nowait;
 if not found then raise exception using errcode='PT409',message='These files must remain in private storage';end if;
 perform 1 from storage.objects o where exists(select 1 from taskfold_private.project_file_preparation_items j where j.plan_id=p.id and o.id in(j.source_object,j.copy_object)) order by o.id for share nowait;
 if exists(select 1 from taskfold_private.project_file_preparation_items j left join taskfold_private.task_file_uploads u using(operation_id)
  left join storage.objects o on o.id=j.copy_object
  where j.plan_id=p.id and (u.operation_id is null or u.actor_id is distinct from p.actor_id or u.team_id is distinct from p.team_id
   or u.task_id is distinct from j.task_id or u.generation is distinct from j.generation or u.project_id is distinct from j.project_id
   or u.state<>'reserved' or u.writer_protocol<>1 or u.expires_at<=clock_timestamp() or u.provider_cleanup_confirmed_at is not null
   or u.byte_count<>j.byte_count or u.sha256 is distinct from j.sha256 or u.intent->'type' is distinct from to_jsonb(j.mime)
   or o.id is null or o.bucket_id<>'task-attachments' or o.name is distinct from u.object_name or coalesce(o.owner_id,o.owner::text) is not null
   or o.metadata->'size' is distinct from to_jsonb(j.byte_count) or o.metadata->'mimetype' is distinct from to_jsonb(j.mime)
   or exists(select 1 from taskfold_private.team_content_files f where f.object_id=j.copy_object)
   or exists(select 1 from taskfold_private.task_file_write_attempts w where w.operation_id=j.operation_id and w.state='open')
   or not exists(select 1 from taskfold_private.task_file_write_attempts w where w.operation_id=j.operation_id and w.state='settled'))) then
  raise exception using errcode='PT409',message='A prepared file changed or is no longer available';end if;
 -- Refresh after the private bucket/object fences. Inspection without a policy
 -- cannot recurse into this function and keeps all existing project safeguards.
 fresh:=taskfold_private.project_adoption_review('inspect',scope);
 if fresh->>'inspection_token' is distinct from inspection then raise exception using errcode='PT409',message='The source files or project changed; review again';end if;
 digest:=taskfold_private.project_file_transfer_inventory(p.id);
 return jsonb_build_object('protocol',1,'plan_id',p.id,'action','share_copies_keep_originals','count',n,'byte_count',bytes,'inventory_token',digest,'originals_kept_private',true);
exception when lock_not_available then raise exception using errcode='PT409',message='A file operation is finishing; review this transfer again';
end$$;

create function taskfold_private.replace_project_file_reference(value jsonb,mapping jsonb) returns jsonb
language sql immutable security invoker set search_path='' as $$
 select case when jsonb_typeof(value)='object' and mapping ? lower(value->>'storage_object_id') then
  (value-'url')||((mapping->lower(value->>'storage_object_id'))-'id')||case when jsonb_typeof(value->'name')='string' and length(value->>'name') between 1 and 240 and octet_length(value->>'name')<=960 and value->>'name' !~ '[[:cntrl:]]' then jsonb_build_object('name',value->'name') else '{}'::jsonb end||case when value ? 'id' then '{}'::jsonb else jsonb_build_object('id',mapping->lower(value->>'storage_object_id')->'id') end
 else value end
$$;
create function taskfold_private.replace_project_file_references(document jsonb,mapping jsonb,depth integer default 0) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:=document;items jsonb;begin
 if depth not between 0 and 32 or octet_length(document::text)>33554432 then raise exception using errcode='54000',message='These files need a separate transfer review';end if;
 if jsonb_typeof(document)<>'object' then return document;end if;
 if jsonb_typeof(document->'attachments')='array' then
  select coalesce(jsonb_agg(taskfold_private.replace_project_file_reference(v,mapping) order by position),'[]') into items from jsonb_array_elements(document->'attachments') with ordinality x(v,position);
  result:=jsonb_set(result,'{attachments}',items);end if;
 if jsonb_typeof(document->'comments')='array' then
  select coalesce(jsonb_agg(case when jsonb_typeof(v)='object' and v ? 'attachment' then jsonb_set(v,'{attachment}',taskfold_private.replace_project_file_reference(v->'attachment',mapping)) else v end order by position),'[]') into items from jsonb_array_elements(document->'comments') with ordinality x(v,position);
  result:=jsonb_set(result,'{comments}',items);end if;
 if jsonb_typeof(document->'subtasks')='array' then
  select coalesce(jsonb_agg(taskfold_private.replace_project_file_references(v,mapping,depth+1) order by position),'[]') into items from jsonb_array_elements(document->'subtasks') with ordinality x(v,position);
  result:=jsonb_set(result,'{subtasks}',items);end if;
 return result;
end$$;

create function taskfold_private.finish_project_adoption_files(team uuid,ids uuid[],policy jsonb,review jsonb) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare p taskfold_private.project_file_preparations;t public.tasks;j taskfold_private.project_file_preparation_items;prepared_attachment jsonb;mapping jsonb;desired jsonb;n integer:=0;begin
 select * into p from taskfold_private.project_file_preparations where id=(policy->>'plan_id')::uuid and actor_id=auth.uid() and team_id=team for update nowait;
 if not found or p.state<>'open' or p.expires_at<=clock_timestamp() or policy->'action' is distinct from '"share_copies_keep_originals"'::jsonb
  or review->>'inventory_token' is distinct from taskfold_private.project_file_transfer_inventory(p.id)
  or cardinality(ids) not between 1 and 1000 or cardinality(ids)<>(select count(*) from taskfold_private.team_project_adoption_scope s
    where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=any(ids) and s.child_custody_version=1 and not s.child_custody_ready)
  or exists(select 1 from taskfold_private.project_file_preparation_items where plan_id=p.id and (phase<>'ready' or project_id<>all(ids))) then
  raise exception using errcode='PT409',message='The reviewed file transfer cannot be confirmed';end if;
 for t in select * from public.tasks where project_id=any(ids) order by id for update loop
  mapping:='{}';
  for j in select * from taskfold_private.project_file_preparation_items where plan_id=p.id and task_id=t.id order by operation_id loop
   if j.generation is distinct from t.task_generation or j.project_id is distinct from t.project_id then raise exception using errcode='PT409',message='A file task changed';end if;
   prepared_attachment:=jsonb_build_object('id',j.operation_id,'storage_object_id',j.copy_object,'name',j.label,'size',j.byte_count,'type',j.mime,'sha256',j.sha256,'uploadedAt',clock_timestamp());
   insert into taskfold_private.task_file_admission_scope(transaction_id,operation_id,object_id,task_id,generation,project_id) values(txid_current(),j.operation_id,j.copy_object,j.task_id,j.generation,j.project_id);
   insert into taskfold_private.team_content_files(object_id,project_id,task_id,task_generation) values(j.copy_object,j.project_id,j.task_id,j.generation);
   update taskfold_private.task_file_uploads set state='published',object_id=j.copy_object,attachment=prepared_attachment where operation_id=j.operation_id and state='reserved';
   if not found then raise exception using errcode='PT409',message='A prepared file is no longer reserved';end if;
   mapping:=mapping||jsonb_build_object(j.source_object::text,prepared_attachment);n:=n+1;
  end loop;
  if mapping='{}'::jsonb then continue;end if;
  desired:=taskfold_private.replace_project_file_references(to_jsonb(t),mapping);
  desired:=jsonb_set(desired,'{subtasks}',taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired->'subtasks'));
  if exists(select 1 from jsonb_array_elements_text(taskfold_private.project_adoption_file_references(desired)->'ids') ref where not exists(
    select 1 from taskfold_private.project_file_preparation_items x where x.plan_id=p.id and x.task_id=t.id and x.copy_object=ref::uuid))
   or jsonb_array_length(taskfold_private.project_adoption_file_references(desired)->'ids')<>(select count(*) from taskfold_private.project_file_preparation_items x where x.plan_id=p.id and x.task_id=t.id) then
   raise exception using errcode='PT409',message='The file references no longer match their reviewed copies';end if;
  update public.tasks set attachments=desired->'attachments',comments=desired->'comments',subtasks=desired->'subtasks' where id=t.id;
 end loop;
 if n is distinct from (review->>'count')::integer then raise exception using errcode='PT409',message='The transferred file count changed';end if;
 delete from taskfold_private.task_file_admission_scope where transaction_id=txid_current() and operation_id in(select operation_id from taskfold_private.project_file_preparation_items where plan_id=p.id);
 update taskfold_private.project_file_preparations set state='committed' where id=p.id;
end$$;
revoke all on function taskfold_private.project_file_transfer_inventory(uuid),taskfold_private.review_project_file_policy(jsonb,jsonb,text),taskfold_private.replace_project_file_reference(jsonb,jsonb),taskfold_private.replace_project_file_references(jsonb,jsonb,integer),taskfold_private.finish_project_adoption_files(uuid,uuid[],jsonb,jsonb) from public,anon,authenticated,service_role;

-- Preserve the normal 5 MiB inline-file budget when a stored copy shares the
-- same task. Keep reference/node limits unchanged and preflight them before
-- spending quota or uploading any copies.
do $$declare d text;anchor text;first integer;begin
 d:=pg_get_functiondef('taskfold_private.task_file_references(jsonb)'::regprocedure);anchor:='octet_length(document::text)>4194304';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current task file byte boundary required';end if;
 execute replace(d,anchor,'octet_length(document::text)>33554432');
 d:=pg_get_functiondef('taskfold_private.project_file_preparation_impl(text,uuid,jsonb)'::regprocedure);
 anchor:='for root in select * from public.tasks where project_id=any(ids) order by id loop';first:=strpos(d,anchor);
 if first=0 or cardinality(string_to_array(d,anchor))<>3 then raise exception 'Current file preparation preflight required';end if;
 d:=substring(d from 1 for first-1)||anchor||chr(10)||'   perform taskfold_private.task_file_references(to_jsonb(root));'||substring(d from first+length(anchor));
 anchor:=' exception when lock_not_available then';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current file preparation failure boundary required';end if;
 execute replace(d,anchor,' exception when program_limit_exceeded then return jsonb_build_object(''status'',''review''); when lock_not_available then');
end$$;

-- Keep every existing admission, connection, audio, child/history, role, expiry
-- and exact-receipt check. Extend the existing signed proof rather than trusting
-- a client assertion that a file copy or a project move already succeeded.
do $$declare d text;anchor text;entry text;begin
 foreach entry in array array['taskfold_private.project_adoption_review(text,jsonb)','taskfold_private.project_adoption_commit(jsonb)'] loop
  d:=pg_get_functiondef(entry::regprocedure);anchor:='||case when b ? ''recording_policy'' then array[''recording_policy''] else ''{}''::text[] end';
  if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current file transfer fields required: %',entry;end if;
  execute replace(d,anchor,anchor||'||case when b ? ''file_policy'' then array[''file_policy''] else ''{}''::text[] end');
 end loop;
 d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);anchor:=' proof jsonb;project_rows jsonb;';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project review declarations required';end if;
 d:=replace(d,anchor,' file_review jsonb;proof jsonb;project_rows jsonb;');
 anchor:=' return result||jsonb_build_object(''decisions'',assignees';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current signed project review result required';end if;
 d:=replace(d,anchor,$patch$
 if b ? 'file_policy' then
  file_review:=taskfold_private.review_project_file_policy(b->'file_policy',b-array['inspection_token','decisions','connection_policy','recording_policy','recording_count','unfinished_recording_count','retained_recording_count','file_policy'],snapshot);
  select encode(extensions.hmac(convert_to(jsonb_build_array(5,a,token,b->'file_policy',file_review,expires)::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
  result:=result||jsonb_build_object('file_policy',b->'file_policy','file_transfer',file_review);
 end if;
 return result||jsonb_build_object('decisions',assignees$patch$);
 anchor:='''requires_provider_custody'',(contents->>''provider_files'')::bigint>0,';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current provider custody refusal required';end if;
 execute replace(d,anchor,'''requires_provider_custody'',(contents->>''provider_files'')::bigint>0 and not(b ? ''file_policy''),');
 d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);
 anchor:=' if proof is distinct from b->>''review_token'' then';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project commit proof required';end if;
 d:=replace(d,anchor,$patch$ if b ? 'file_policy' then
 select encode(extensions.hmac(convert_to(jsonb_build_array(5,a,proof,b->'file_policy',preview->'file_transfer',b->>'expires_at')::text,'UTF8'),s.secret,'sha256'),'hex') into proof from taskfold_private.automation_revision_secret s where singleton;end if;
 if proof is distinct from b->>'review_token' then$patch$);
 anchor:=' perform taskfold_private.finish_child_adoption_custody(team,ids);';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current child custody finishing required';end if;
 d:=replace(d,anchor,' if b ? ''file_policy'' then perform taskfold_private.finish_project_adoption_files(team,ids,b->''file_policy'',preview->''file_transfer'');end if;'||chr(10)||anchor);
 anchor:=' delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project receipt required';end if;
 execute replace(d,anchor,' if b ? ''file_policy'' then update taskfold_private.project_adoption_receipts set file_plan_id=(b->''file_policy''->>''plan_id'')::uuid,file_count=(preview->''file_transfer''->>''count'')::integer,file_bytes=(preview->''file_transfer''->>''byte_count'')::bigint where team_id=team and request_id=q returning * into prior;end if;'||chr(10)||anchor);
 d:=pg_get_functiondef('taskfold_private.project_adoption_receipt_reply(taskfold_private.project_adoption_receipts,boolean)'::regprocedure);anchor:=' select jsonb_build_object(';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project receipt reply required';end if;
 -- Add only receipt facts. No original/copy provider identities or private paths.
 execute replace(d,anchor,' select case when r.file_plan_id is null then ''{}''::jsonb else jsonb_build_object(''file_transfer'',jsonb_build_object(''protocol'',1,''plan_id'',r.file_plan_id,''action'',''share_copies_keep_originals'',''count'',r.file_count,''byte_count'',r.file_bytes,''originals_kept_private'',true)) end || jsonb_build_object(');
 d:=pg_get_functiondef('taskfold_private.project_file_preparation_reply(taskfold_private.project_file_preparations,uuid)'::regprocedure);anchor:='''project_transferred'',false';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current private preparation reply required';end if;
 execute replace(d,anchor,'''project_transferred'',p.state=''committed''');
end$$;
notify pgrst,'reload schema';

commit;

-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Private inventory for reviewed project file custody. This does not authorize
-- a transfer or mutate Storage. Existing provider-file refusal remains in force.
create function taskfold_private.project_adoption_file_references(document jsonb) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare doc jsonb;items jsonb;item jsonb;depth integer;
 nodes integer:=0;refs integer:=0;inline_n integer:=0;external_n integer:=0;legacy_n integer:=0;provider_n integer:=0;ids uuid[]:='{}';
 fingerprint bytea:=extensions.digest('','sha256');result jsonb;
begin
 if jsonb_typeof(document) is distinct from 'object' or octet_length(document::text)>33554432 then
  raise exception using errcode='54000',message='Review these task files before moving';end if;
 for doc,depth in
  with recursive walk(node,level) as (
   select document,0 union all
   select child.value,parent.level+1 from walk parent cross join lateral jsonb_array_elements(case when jsonb_typeof(parent.node->'subtasks')='array' then parent.node->'subtasks' else '[]'::jsonb end) child where parent.level<32
  ) select node,level from walk limit 100002
 loop
  nodes:=nodes+1;
  if nodes>100001 or (depth=32 and jsonb_typeof(doc->'subtasks')='array' and jsonb_array_length(doc->'subtasks')>0) then
   raise exception using errcode='54000',message='Review these task files before moving';end if;
  if jsonb_typeof(doc)<>'object' then continue;end if;
  items:='[]';
  if jsonb_typeof(doc->'attachments')='array' then items:=doc->'attachments';
  elsif coalesce(doc->'attachments','null')<>'null'::jsonb then items:=jsonb_build_array(jsonb_build_object('unmapped_container',doc->'attachments'));end if;
  if jsonb_typeof(doc->'comments')='array' then
   select items||coalesce(jsonb_agg(comment.value->'attachment' order by comment.position) filter(where coalesce(comment.value->'attachment','null')<>'null'::jsonb),'[]'::jsonb) into items from jsonb_array_elements(doc->'comments') with ordinality comment(value,position);
  elsif coalesce(doc->'comments','null')<>'null'::jsonb then items:=items||jsonb_build_array(jsonb_build_object('unmapped_container',doc->'comments'));end if;
  for item in select * from jsonb_array_elements(items) loop
   refs:=refs+1;if refs>100000 then raise exception using errcode='54000',message='Review these task files before moving';end if;
   fingerprint:=extensions.digest(fingerprint||extensions.digest(convert_to(item::text,'UTF8'),'sha256'),'sha256');
   if jsonb_typeof(item)='object' and item ? 'storage_object_id' then
    if jsonb_typeof(item->'storage_object_id') is distinct from 'string' or (item->>'storage_object_id') !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then
     raise exception using errcode='22023',message='Review this stored file reference before moving';end if;
    ids:=array_append(ids,(item->>'storage_object_id')::uuid);provider_n:=provider_n+1;
   elsif jsonb_typeof(item)='object' and item->>'url' like 'data:%' then inline_n:=inline_n+1;
   elsif jsonb_typeof(item)='object' and item->>'url' ~ '^https?://' and item->>'url' !~* '/storage/v1/(object|render)/' then external_n:=external_n+1;
   else legacy_n:=legacy_n+1;provider_n:=provider_n+1;end if;
  end loop;
  if jsonb_typeof(doc->'subtasks') is distinct from 'array' and coalesce(doc->'subtasks','null')<>'null'::jsonb then
   legacy_n:=legacy_n+1;provider_n:=provider_n+1;refs:=refs+1;
   fingerprint:=extensions.digest(fingerprint||extensions.digest(convert_to((doc->'subtasks')::text,'UTF8'),'sha256'),'sha256');
  end if;
 end loop;
 select coalesce(jsonb_agg(x::text order by x),'[]') into result from(select distinct unnest(ids) x)s;
 if refs>100000 or jsonb_array_length(result)>10000 then raise exception using errcode='54000',message='Review these task files before moving';end if;
 return jsonb_build_object('ids',result,'attachments',refs,'inline_files',inline_n,'external_files',external_n,'provider_files',provider_n,'legacy',legacy_n,'references_hash',encode(fingerprint,'hex'));
end$$;

create function taskfold_private.project_adoption_file_inventory(ids uuid[]) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare t public.tasks;r jsonb;object_key uuid;o storage.objects;b storage.buckets;
 inventory bytea:=extensions.digest('','sha256');payload text;bytes bigint:=0;roots integer:=0;refs integer:=0;inline_n integer:=0;external_n integer:=0;provider_n integer:=0;
 stored_n integer:=0;legacy_n integer:=0;unavailable_n integer:=0;seen jsonb:='{}';
begin
 if ids is null or array_ndims(ids)<>1 or cardinality(ids) not between 1 and 1000 or array_position(ids,null) is not null
  or cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then raise exception using errcode='22023',message='Choose a bounded project selection';end if;
 for t in select * from public.tasks where project_id=any(ids) order by id limit 10001 loop
  roots:=roots+1;if roots>10000 then raise exception using errcode='54000',message='These projects have too many files to review together';end if;
  r:=taskfold_private.project_adoption_file_references(to_jsonb(t));
  refs:=refs+(r->>'attachments')::integer;inline_n:=inline_n+(r->>'inline_files')::integer;external_n:=external_n+(r->>'external_files')::integer;
  provider_n:=provider_n+(r->>'provider_files')::integer;legacy_n:=legacy_n+(r->>'legacy')::integer;
  if refs>100000 then raise exception using errcode='54000',message='These projects have too many files to review together';end if;
  payload:=jsonb_build_array(t.id,t.task_generation,t.project_id,t.user_id,r)::text;bytes:=bytes+octet_length(payload);
  inventory:=extensions.digest(inventory||extensions.digest(convert_to(payload,'UTF8'),'sha256'),'sha256');
  for object_key in select value::uuid from jsonb_array_elements_text(r->'ids') order by value loop
   stored_n:=stored_n+1;
   -- Unavailable references are opaque, including their hash contribution.
   -- Never turn the privileged inventory into a foreign-file metadata oracle.
   select * into o from storage.objects source where source.id=object_key and source.bucket_id='task-attachments'
    and coalesce(source.owner_id,source.owner::text)=auth.uid()::text
    and split_part(source.name,'/',1)=auth.uid()::text
    and not exists(select 1 from taskfold_private.team_content_files custody where custody.object_id=source.id);
   select * into b from storage.buckets where id=o.bucket_id;
   if o.id is null or o.bucket_id<>'task-attachments' or b.id is null or b.public is distinct from false
    or coalesce(to_jsonb(o)->>'owner_id',to_jsonb(o)->>'owner') is distinct from t.user_id::text
    or (to_jsonb(o)->>'owner_id' is not null and to_jsonb(o)->>'owner' is not null and to_jsonb(o)->>'owner_id'<>to_jsonb(o)->>'owner')
    or seen ? object_key::text then unavailable_n:=unavailable_n+1;end if;
   seen:=seen||jsonb_build_object(object_key::text,true);
   payload:=jsonb_build_array(t.id,t.task_generation,t.project_id,object_key,to_jsonb(o)-array['created_at','updated_at','last_accessed_at'],to_jsonb(b)-array['created_at','updated_at'])::text;bytes:=bytes+octet_length(payload);
   if bytes>8388608 then raise exception using errcode='54000',message='These projects and files are too large to review together';end if;
   inventory:=extensions.digest(inventory||extensions.digest(convert_to(payload,'UTF8'),'sha256'),'sha256');
  end loop;
  if bytes>8388608 then raise exception using errcode='54000',message='These projects and files are too large to review together';end if;
 end loop;
 if stored_n+legacy_n>10000 then raise exception using errcode='54000',message='These projects have too many stored files to review together';end if;
 return jsonb_build_object('attachments',refs,'inline_files',inline_n,'external_files',external_n,'provider_files',provider_n,'summary',jsonb_build_object('protocol',1,'stored',stored_n,'legacy',legacy_n,'unavailable',unavailable_n),'review_bytes',bytes,'inventory_hash',encode(inventory,'hex'));
end$$;
revoke all on function taskfold_private.project_adoption_file_references(jsonb),taskfold_private.project_adoption_file_inventory(uuid[]) from public,anon,authenticated,service_role;

-- Keep the current complete review contract, but include known inline-comment
-- locations and signed private provider identity/metadata. No custody permission.
do $$declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.project_adoption_contents(uuid[])'::regprocedure);
 anchor:=' rows jsonb; n bigint;';if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project contents declaration required';end if;
 d:=replace(d,anchor,' rows jsonb;file_rows jsonb; n bigint;');
 anchor:=' rows=taskfold_private.project_adoption_attachments(ids);';if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project attachment inventory required';end if;
 d:=replace(d,anchor,' file_rows=taskfold_private.project_adoption_file_inventory(ids);rows=file_rows;
 total=total+(file_rows->>''review_bytes'')::bigint;
 if total>33554432 then raise exception using errcode=''54000'',message=''These projects and files are too large to review together'';end if;
 hashes=hashes||jsonb_build_object(''project_files_v1'',file_rows->''inventory_hash'');');
 anchor:=' return jsonb_build_object(';if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project contents result required';end if;
 d:=replace(d,anchor,' return jsonb_build_object(''file_custody'',file_rows->''summary'',');execute d;
end$$;

commit;

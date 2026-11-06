-- Undeployed foundation for reviewed whole-project recording custody. This
-- binds actual ledger/provider metadata into the existing signed inspection.
-- Transfer remains refused until the explicit custody commit is implemented.
create function taskfold_private.project_adoption_audio_inventory(ids uuid[]) returns jsonb
language plpgsql stable security invoker set search_path='' as $$
declare item record;inventory bytea:=extensions.digest('','sha256');payload text;n integer:=0;published integer:=0;pending integer:=0;retained integer:=0;unavailable integer:=0;bytes bigint:=0;
begin
 if ids is null or array_ndims(ids)<>1 or cardinality(ids) not between 1 and 1000 or array_position(ids,null) is not null
  or cardinality(ids)<>(select count(distinct x) from unnest(ids) x) then
  raise exception using errcode='22023',message='Choose a bounded project selection';end if;
 for item in
  select r.operation_id,r.state,to_jsonb(r) publication,to_jsonb(c) custody,to_jsonb(o) provider,
   (t.id is null or t.task_generation is distinct from r.task_generation or t.project_id is distinct from r.project_id
    or c.operation_id is not null
    or (r.state<>'pending' and (o.id is null or not taskfold_private.audio_bucket_ready()
      or coalesce(to_jsonb(o)->>'owner_id',to_jsonb(o)->>'owner') is not null
      or o.metadata->'size' is distinct from to_jsonb(r.byte_count)
      or o.metadata->'mimetype' is distinct from '"audio/mp4"'::jsonb))) invalid
  from taskfold_private.audio_comment_publications r
  left join public.tasks t on t.id=r.task_id
  left join taskfold_private.audio_comment_custody c on c.operation_id=r.operation_id
  left join storage.objects o on o.bucket_id='taskfold-audio-v1' and o.name=r.object_name
  where r.state in('pending','published','retired') and (r.project_id=any(ids) or t.project_id=any(ids) or c.project_id=any(ids))
  order by r.operation_id limit 10001
 loop
  n:=n+1;payload:=jsonb_build_array(item.publication,item.custody,item.provider)::text;bytes:=bytes+octet_length(payload);
  if n>10000 or bytes>8388608 then raise exception using errcode='54000',message='These projects have too many recordings to review together';end if;
  if item.state='published' then published:=published+1;elsif item.state='pending' then pending:=pending+1;else retained:=retained+1;end if;
  if item.invalid then unavailable:=unavailable+1;end if;
  inventory:=extensions.digest(inventory||extensions.digest(convert_to(payload,'UTF8'),'sha256'),'sha256');
 end loop;
 return jsonb_build_object('protocol',1,'published',published,'pending',pending,'retained',retained,'unavailable',unavailable,
  'review_bytes',bytes,'inventory_hash',encode(inventory,'hex'));
end$$;
revoke all on function taskfold_private.project_adoption_audio_inventory(uuid[]) from public,anon,authenticated,service_role;

do $$declare d text;anchor text;begin
 d:=pg_get_functiondef('taskfold_private.project_adoption_contents(uuid[])'::regprocedure);
 anchor:=' return jsonb_build_object(''hashes'',hashes,''counts'',counts,';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current child-record project inspection required';end if;
 d:=replace(d,anchor,' rows:=taskfold_private.project_adoption_audio_inventory(ids); total:=total+(rows->>''review_bytes'')::bigint;
 if total>33554432 then raise exception using errcode=''54000'',message=''These projects and recordings are too large to review together'';end if;
 return jsonb_build_object(''recording_custody'',rows-array[''inventory_hash'',''review_bytes''],''hashes'',hashes||jsonb_build_object(''project_recordings_v1'',rows->''inventory_hash''),''counts'',counts,');
 execute d;
 d:=pg_get_functiondef('taskfold_private.project_adoption_review(text,jsonb)'::regprocedure);
 anchor:=' if operation=''inspect'' then return result;end if;';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current project review required';end if;
 d:=replace(d,anchor,' if (contents->''recording_custody''->>''published'')::integer+(contents->''recording_custody''->>''pending'')::integer+(contents->''recording_custody''->>''retained'')::integer>0 then
 result:=result||jsonb_build_object(''commit_supported'',false,''connection_pause_supported'',false);end if;'||anchor);
 execute d;
 d:=pg_get_functiondef('taskfold_private.project_adoption_commit(jsonb)'::regprocedure);
 anchor:=' if proof is distinct from b->>''review_token'' then raise exception using errcode=''PT409'',message=''The reviewed transfer changed; review again'';end if;';
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current reviewed project commit required';end if;
 d:=replace(d,anchor,anchor||'
 if (preview->''contents''->''recording_custody''->>''published'')::integer+(preview->''contents''->''recording_custody''->>''pending'')::integer+(preview->''contents''->''recording_custody''->>''retained'')::integer>0 then
 raise exception using errcode=''PT409'',message=''Review recording custody before transferring these projects'';end if;');
 execute d;
end$$;

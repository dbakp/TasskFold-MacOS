-- Read-only title search. Caller RLS, live session and rollout checks remain
-- identical to browsing; partial metadata never authorizes an upgrade.
create function public.taskfold_search_child_adoption_targets(_query text,_after uuid default null,_limit integer default 100) returns jsonb
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' set statement_timeout='5s' as $$
declare actor uuid;items jsonb:='[]';r record;more boolean:=false;cursor_id uuid;q text;
begin
 actor:=taskfold_private.child_adoption_discovery_actor();
 q:=normalize(_query,NFC);
 if q is null or char_length(q)<1 or char_length(q)>256 or octet_length(q)>1024 or _limit is null or _limit<1 or _limit>100 then
  raise exception using errcode='22023',message='Use a search of 1 to 256 characters and a page of 1 to 100 tasks';
 end if;
 for r in
  select t.id,t.task_generation,t.project_id,left(t.title,256) as title,char_length(t.title)>256 as title_truncated,
   case when strpos(lower(normalize(t.title,NFC)),lower(q))>256 then
    substring(normalize(t.title,NFC) from greatest(1,strpos(lower(normalize(t.title,NFC)),lower(q))-32) for 128) else null end as match_excerpt
  from public.tasks t
  where (_after is null or t.id>_after) and strpos(lower(normalize(t.title,NFC)),lower(q))>0
  order by t.id limit (_limit+1)
 loop
  if jsonb_array_length(items)=_limit then more:=true;exit;end if;
  cursor_id:=r.id;
  items:=items||jsonb_build_array(jsonb_build_object('task_id',r.id,'task_generation',r.task_generation,
   'project_id',r.project_id,'title',r.title,'title_truncated',coalesce(r.title_truncated,false),'match_excerpt',r.match_excerpt));
 end loop;
 if taskfold_private.child_adoption_discovery_actor() is distinct from actor then raise exception using errcode='28000',message='Account access changed';end if;
 return jsonb_build_object('protocol',2,'account',actor,'query',q,'items',items,'next_after',case when more then cursor_id else null end);
end$$;
revoke all on function public.taskfold_search_child_adoption_targets(text,uuid,integer) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_search_child_adoption_targets(text,uuid,integer) to authenticated;

-- Metadata discovery is independent of legacy JSON decoding. It never reads or
-- rewrites subtasks, and never seeds the editable task cache with partial rows.
create function taskfold_private.child_adoption_discovery_actor() returns uuid
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
begin
 perform taskfold_private.team_actor();
 perform 1 from taskfold_private.child_task_record_config where singleton and adoption_enabled for share;
 if not found then raise exception using errcode='PT503',message='Subtask migration review is not enabled';end if;
 return auth.uid();
end$$;

-- Keep selection under the caller's RLS. The private definer above authenticates
-- the live session and rollout only; it returns no other account's content.
create function public.taskfold_child_adoption_targets(_after uuid default null,_limit integer default 100,_id uuid default null) returns jsonb
language plpgsql volatile security invoker set search_path='' set lock_timeout='3s' as $$
declare actor uuid;items jsonb:='[]';row_data record;more boolean:=false;cursor_id uuid;
begin
 actor:=taskfold_private.child_adoption_discovery_actor();
 if _limit is null or _limit<1 or _limit>100 or (_id is not null and (_after is not null or _limit<>1)) then
  raise exception using errcode='22023',message='Review this discovery request';
 end if;
 for row_data in
  select t.id,t.task_generation,t.project_id,left(t.title,512) as title,char_length(t.title)>512 as title_truncated
  from public.tasks t where (_after is null or t.id>_after) and (_id is null or t.id=_id)
  order by t.id limit (_limit+1)
 loop
  if jsonb_array_length(items)=_limit then more:=true;exit;end if;
  cursor_id:=row_data.id;
  items:=items||jsonb_build_array(jsonb_build_object('task_id',row_data.id,'task_generation',row_data.task_generation,
    'project_id',row_data.project_id,'title',row_data.title,'title_truncated',coalesce(row_data.title_truncated,false)));
 end loop;
 if taskfold_private.child_adoption_discovery_actor() is distinct from actor then raise exception using errcode='28000',message='Account access changed';end if;
 return jsonb_build_object('protocol',1,'account',actor,'items',items,'next_after',case when more then cursor_id else null end);
end$$;
revoke all on function taskfold_private.child_adoption_discovery_actor(),public.taskfold_child_adoption_targets(uuid,integer,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.child_adoption_discovery_actor(),public.taskfold_child_adoption_targets(uuid,integer,uuid) to authenticated;

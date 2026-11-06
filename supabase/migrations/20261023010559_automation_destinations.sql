-- Candidate, not deployed. Destination discovery shares the key authorizer,
-- quota transaction and current project/member locks with task operations.
create function taskfold_private.automation_destinations(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare account uuid; p public.projects; s public.sections; cursor_id uuid; project uuid; parent uuid;
 page jsonb:='[]'; result jsonb; page_limit int:=25; page_count int:=0; more boolean:=false; last_id uuid;
 pattern constant text:='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$';
begin
 account:=taskfold_private.automation_authorize(_key,_hash,'tasks:read');
 if _body is null or jsonb_typeof(_body)<>'object' or octet_length(_body::text)>8192
 or _action not in('projects','sections') or _action is null
 or exists(select 1 from jsonb_object_keys(_body) k where k not in('after','limit','project_id'))
 or (_action='projects' and _body ? 'project_id') then
  raise exception using errcode='22023',message='Invalid destination page';
 end if;
 if _body ? 'limit' then
  if jsonb_typeof(_body->'limit') is distinct from 'number' then raise exception using errcode='22023',message='Invalid page size';end if;
  if (_body->>'limit')::numeric not between 1 and 50 or (_body->>'limit')::numeric<>trunc((_body->>'limit')::numeric) then raise exception using errcode='22023',message='Invalid page size';end if;
  page_limit:=(_body->>'limit')::numeric::int;
 end if;
 if _action='sections' then
  if jsonb_typeof(_body->'project_id') is distinct from 'string' or (_body->>'project_id')!~pattern then raise exception using errcode='22023',message='Choose a project';end if;
  project:=(_body->>'project_id')::uuid;
  perform taskfold_private.automation_lock_project(account,project);
 end if;
 if _body ? 'after' then
  if jsonb_typeof(_body->'after') is distinct from 'string' or (_body->>'after')!~pattern then raise exception using errcode='22023',message='Invalid destination cursor';end if;
  cursor_id:=(_body->>'after')::uuid;
  if _action='projects' then
   perform taskfold_private.automation_lock_project(account,cursor_id);
  else
   perform 1 from public.sections where id=cursor_id and project_id=project for share;
   if not found then raise exception using errcode='PT404',message='Destination page is unavailable';end if;
  end if;
 end if;
 if _action='projects' then
  for p in select * from public.projects x where public.has_project_access(account,x.id)
   and (cursor_id is null or x.id>cursor_id) order by x.id limit page_limit+1 for share loop
   perform taskfold_private.automation_lock_project(account,p.id);
   if page_count=page_limit then more:=true;exit;end if;
   parent:=null;
   if p.parent_id is not null and public.has_project_access(account,p.parent_id) then
    perform taskfold_private.automation_lock_project(account,p.parent_id);
    parent:=p.parent_id;
   end if;
   -- Never expose an inaccessible ancestor's identity, even for a shared child.
   page:=page||jsonb_build_array(jsonb_build_object('id',p.id,'name',p.name,'color',p.color,'order_index',p.order_index,
    'parent_id',parent,'parent_unavailable',p.parent_id is not null and parent is null,
    'is_archived',coalesce(p.is_archived,false),'ancestor_archived',coalesce(p.ancestor_archived,false),
    'accepts_tasks',not(coalesce(p.is_archived,false) or coalesce(p.ancestor_archived,false))));
   last_id:=p.id;page_count:=page_count+1;
  end loop;
  result:=jsonb_build_object('projects',page,'inbox',jsonb_build_object('name','Inbox','project_id',null,'section_id',null),
   'next_cursor',case when more then last_id else null end);
 else
  for s in select * from public.sections x where x.project_id=project
   and (cursor_id is null or x.id>cursor_id) order by x.id limit page_limit+1 for share loop
   if page_count=page_limit then more:=true;exit;end if;
   page:=page||jsonb_build_array(jsonb_build_object('id',s.id,'project_id',s.project_id,'name',s.name,'order_index',s.order_index));
   last_id:=s.id;page_count:=page_count+1;
  end loop;
  result:=jsonb_build_object('project_id',project,'sections',page,'next_cursor',case when more then last_id else null end);
 end if;
 if octet_length(result::text)>1048576 then raise exception using errcode='PT413',message='Request fewer destinations';end if;
 return result;
end $$;
create function public.taskfold_automation_destinations(_key uuid,_hash text,_action text,_body jsonb)
returns jsonb language sql volatile security invoker set search_path='' set statement_timeout='10s'
as $$select taskfold_private.automation_destinations(_key,_hash,_action,_body)$$;
revoke all on function taskfold_private.automation_destinations(uuid,text,text,jsonb),public.taskfold_automation_destinations(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.automation_destinations(uuid,text,text,jsonb),public.taskfold_automation_destinations(uuid,text,text,jsonb) to service_role;

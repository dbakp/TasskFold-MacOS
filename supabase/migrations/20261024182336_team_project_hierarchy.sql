-- Source-only reviewed team hierarchy; no task-write or rollout flag changes.
create table taskfold_private.team_project_hierarchy_operations (
 transaction_id bigint not null,actor_id uuid not null,team_id uuid not null,
 project_id uuid not null,root_id uuid not null,parent_id uuid,
 operation text not null check(operation in('move','create_subproject')),
 primary key(transaction_id,project_id)
);
alter table taskfold_private.team_project_hierarchy_operations enable row level security;
revoke all on taskfold_private.team_project_hierarchy_operations from public,anon,authenticated,service_role;

-- Keep the existing personal trigger's invoker/creator rules exactly intact.
-- The routing predicate already exists for authenticated RLS; trusted service
-- maintenance needs that same Boolean to run the personal/team trigger split.
grant execute on function taskfold_private.is_team_content_project(uuid) to service_role;
create function taskfold_private.guard_team_project_organization() returns trigger
language plpgsql security definer set search_path='' as $$
declare t uuid;pt uuid;ancestor public.projects;cursor_id uuid;visited uuid[]:=array[new.id];depth integer:=1;subtree_depth integer;bad boolean;n integer;
begin
 select team_id into t from taskfold_private.team_content_projects where project_id=new.id;
 if t is null then raise exception using errcode='42501',message='Team project custody is unavailable';end if;
 if tg_op='UPDATE' and (new.parent_id,new.is_archived,new.ancestor_archived) is not distinct from (old.parent_id,old.is_archived,old.ancestor_archived) then return new;end if;
 if auth.uid() is not null
  and not exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t)
  and not exists(select 1 from taskfold_private.team_project_metadata_operations where transaction_id=txid_current() and actor_id=auth.uid() and team_id=t and project_id=new.id)
  and not exists(select 1 from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and actor_id=auth.uid() and team_id=t and project_id=new.id) then
   raise exception using errcode='42501',message='Review this team project branch before moving it';end if;
 new.ancestor_archived=false;cursor_id=new.parent_id;
 while cursor_id is not null loop
  if cursor_id=any(visited) then raise exception using errcode='22023',message='A project cannot be moved into its own branch';end if;
  visited=array_append(visited,cursor_id);depth=depth+1;
  if depth>20 then raise exception using errcode='54000',message='Projects can be nested up to 20 levels';end if;
  select * into ancestor from public.projects where id=cursor_id;
  if not found then raise exception using errcode='22023',message='Choose an available team parent';end if;
  select team_id into pt from taskfold_private.team_content_projects where project_id=cursor_id;
  if pt is distinct from t then raise exception using errcode='22023',message='Move projects within the same team';end if;
  if cursor_id=new.parent_id then new.ancestor_archived=ancestor.is_archived or ancestor.ancestor_archived;end if;
  cursor_id=ancestor.parent_id;
 end loop;
 if tg_op='UPDATE' and new.parent_id is distinct from old.parent_id then
  with recursive tree(id,levels,path,cycle) as (
   select new.id,1,array[new.id],false
   union all select c.id,s.levels+1,s.path||c.id,c.id=any(s.path) from public.projects c join tree s on c.parent_id=s.id where not s.cycle and s.levels<=20
  ),bounded as(select * from tree limit 1001)
  select max(levels),bool_or(cycle or levels>20),count(*) into subtree_depth,bad,n from bounded;
  if n>1000 or bad or depth+subtree_depth-1>20 then raise exception using errcode='54000',message='This project branch exceeds the supported hierarchy limits';end if;
 end if;
 return new;
end$$;
revoke all on function taskfold_private.guard_team_project_organization() from public,anon,authenticated,service_role;
drop trigger taskfold_project_organization on public.projects;
create trigger taskfold_project_organization before insert or update on public.projects for each row
 when(not taskfold_private.is_team_content_project(new.id)) execute function taskfold_private.guard_project_organization();
create trigger taskfold_team_project_organization before insert or update on public.projects for each row
 when(taskfold_private.is_team_content_project(new.id)) execute function taskfold_private.guard_team_project_organization();

-- A shared team branch can contain work created by different people or a
-- departed creator. Live role/custody truth, not creator equality, authorizes it.
create or replace function taskfold_private.team_project_branch(a uuid,t uuid,p uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare ids uuid[]; bad boolean; n integer; token text; height integer;
begin
 with recursive tree(id,parent_id,depth,path,cycle) as (
  select x.id,x.parent_id,1,array[x.id],false from public.projects x where x.id=p
  union all
  select x.id,x.parent_id,s.depth+1,s.path||x.id,x.id=any(s.path) from public.projects x join tree s on x.parent_id=s.id where s.depth<=20 and not s.cycle
 ), bounded as(select * from tree limit 1001)
 select array_agg(id order by id),count(*),bool_or(cycle or depth>20),max(depth) into ids,n,bad,height from bounded;
 if n not between 1 and 1000 or coalesce(bad,true) then raise exception using errcode='54000',message='This project branch cannot be reviewed safely';end if;
 if exists(select 1 from public.projects x left join taskfold_private.team_content_projects c on c.project_id=x.id where x.id=any(ids)
  and (c.team_id is distinct from t or taskfold_private.team_project_role(a,x.id) is distinct from 'manager'))
  or exists(select 1 from public.projects x left join taskfold_private.team_content_projects c on c.project_id=x.parent_id where x.id=p and x.parent_id is not null and c.team_id is distinct from t) then
  raise exception using errcode='42501',message='Management access is required for the entire project branch';end if;
 if exists(select 1 from public.projects x where x.id=any(ids) and x.ancestor_archived is distinct from coalesce((select z.is_archived or z.ancestor_archived from public.projects z where z.id=x.parent_id),false)) then raise exception using errcode='PT409',message='The project archive projection needs repair';end if;
 select encode(extensions.digest(convert_to(jsonb_agg(jsonb_build_array(x.id,x.parent_id,c.revision,x.is_archived,x.ancestor_archived) order by x.id)::text,'UTF8'),'sha256'),'hex') into token
  from public.projects x join taskfold_private.team_content_projects c on c.project_id=x.id where x.id=any(ids);
 return jsonb_build_object('ids',to_jsonb(ids),'tree_token',token,'affected_count',n,'height',height);
end$$;
revoke all on function taskfold_private.team_project_branch(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create or replace function taskfold_private.guard_team_project_metadata() returns trigger
language plpgsql security definer set search_path='' as $$
declare t uuid; scope taskfold_private.team_project_metadata_operations; allowed text[];hierarchy taskfold_private.team_project_hierarchy_operations;
begin
 if auth.uid() is null then if tg_op='DELETE' then return old;else return new;end if;end if;
 select team_id into t from taskfold_private.team_content_projects where project_id=old.id;
 if t is null or exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 if tg_op='UPDATE' then
  select * into hierarchy from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and actor_id=auth.uid() and team_id=t and project_id=old.id;
  if found then
   allowed=case when hierarchy.root_id=old.id then array['parent_id','ancestor_archived','updated_at'] else array['ancestor_archived','updated_at'] end;
   if new.parent_id is not distinct from hierarchy.parent_id
    and new.ancestor_archived is not distinct from coalesce((select p.is_archived or p.ancestor_archived from public.projects p where p.id=new.parent_id),false)
    and (to_jsonb(new)-allowed) is not distinct from (to_jsonb(old)-allowed) then return new;end if;
   raise exception using errcode='42501',message='The reviewed project move changed';
  end if;
  select * into scope from taskfold_private.team_project_metadata_operations
   where transaction_id=txid_current() and actor_id=auth.uid() and team_id=t and project_id=old.id;
  if found then
   if scope.operation='rename' and scope.root_id=old.id then allowed=array['name','updated_at'];
   elsif scope.operation in('archive','unarchive') then
    allowed=case when scope.root_id=old.id then array['is_archived','ancestor_archived','updated_at'] else array['ancestor_archived','updated_at'] end;
    if new.ancestor_archived is distinct from coalesce((select p.is_archived or p.ancestor_archived from public.projects p where p.id=new.parent_id),false) then
     raise exception using errcode='42501',message='Project archive projection is invalid';end if;
    if scope.root_id=old.id and new.is_archived is distinct from (scope.operation='archive') then
     raise exception using errcode='42501',message='Project archive operation changed';end if;
   end if;
   if allowed is not null and (to_jsonb(new)-allowed) is not distinct from (to_jsonb(old)-allowed) then return new;end if;
  end if;
 end if;
 raise exception using errcode='42501',message='Review team project changes in a supported Taskfold app';
end$$;
revoke all on function taskfold_private.guard_team_project_metadata() from public,anon,authenticated,service_role;

create function taskfold_private.team_project_ancestors(t uuid,p uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare cursor_id uuid:=p;visited uuid[]:='{}';node public.projects;binding taskfold_private.team_content_projects;rows jsonb:='[]';archived boolean:=false;expected boolean:=false;i integer;
begin
 while cursor_id is not null loop
  if cursor_id=any(visited) then raise exception using errcode='22023',message='The destination branch contains a cycle';end if;
  visited=array_append(visited,cursor_id);
  if cardinality(visited)>20 then raise exception using errcode='54000',message='The destination is too deeply nested';end if;
  select * into node from public.projects where id=cursor_id;
  if not found then raise exception using errcode='42501',message='The destination branch is unavailable';end if;
  select * into binding from taskfold_private.team_content_projects where project_id=cursor_id and team_id=t;
  if not found then raise exception using errcode='42501',message='Choose a destination within this team';end if;
  if cursor_id=p then archived=node.is_archived or node.ancestor_archived;end if;
  rows=rows||jsonb_build_array(jsonb_build_array(node.id,node.parent_id,binding.revision,node.is_archived,node.ancestor_archived));
  cursor_id=node.parent_id;
 end loop;
 for i in reverse jsonb_array_length(rows)-1..0 loop
  if (rows->i->>4)::boolean is distinct from expected then raise exception using errcode='PT409',message='The destination archive projection needs repair';end if;
  expected=expected or (rows->i->>3)::boolean;
 end loop;
 return jsonb_build_object('ids',to_jsonb(visited),'manifest',rows,'depth',cardinality(visited),'archived',archived);
end$$;
revoke all on function taskfold_private.team_project_ancestors(uuid,uuid) from public,anon,authenticated,service_role;

create function taskfold_private.team_project_hierarchy_projection(a uuid,p uuid) returns jsonb
language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('project_hierarchy_protocol',1,
  'parent_id',case when x.parent_id is null or taskfold_private.team_project_role(a,x.parent_id) is not null then x.parent_id end,
  'parent_unavailable',x.parent_id is not null and taskfold_private.team_project_role(a,x.parent_id) is null)
 from public.projects x where x.id=p
$$;
revoke all on function taskfold_private.team_project_hierarchy_projection(uuid,uuid) from public,anon,authenticated,service_role;

create function taskfold_private.team_project_hierarchy_command(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();t uuid;p uuid;dest uuid;q uuid;operation text;team taskfold_private.teams;binding taskfold_private.team_content_projects;parent_binding taskfold_private.team_content_projects;
 node public.projects;parent_node public.projects;branch jsonb;ancestry jsonb;ids uuid[];fingerprint text;token text;prior taskfold_private.team_project_commands;issued timestamptz;today date;result jsonb;new_name text;chosen_visibility text;folder uuid;
begin
 if action not in('review_hierarchy','move','create_subproject') then return taskfold_private.team_project_metadata_command(action,b);end if;
 perform taskfold_private.team_actor();
 if action='review_hierarchy' then perform taskfold_private.team_fields(b,array['team_id','project_id','parent_id','operation']);operation=b->>'operation';
 elsif action='create_subproject' then
  perform taskfold_private.team_fields(b,array['team_id','project_id','parent_id','parent_revision','request_id','issued_at','team_revision','tree_token','affected_count','destination_archived','is_archived','name','visibility','folder_id']);operation=action;
 else perform taskfold_private.team_fields(b,array['team_id','project_id','parent_id','parent_revision','request_id','issued_at','team_revision','revision','tree_token','affected_count','destination_archived','is_archived']);operation=action;end if;
 if operation is null or operation not in('move','create_subproject') then raise exception using errcode='22023',message='Choose a supported project hierarchy change';end if;
 t=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');
 if b->'parent_id'<>'null'::jsonb then dest=taskfold_private.team_uuid(b,'parent_id');end if;
 if operation='create_subproject' and dest is null then raise exception using errcode='22023',message='Choose a parent for this subproject';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if action='review_hierarchy' then select * into team from taskfold_private.teams where id=t and state<>'deleted' for share;
 else select * into team from taskfold_private.teams where id=t and state<>'deleted' for update;end if;
 if not found then raise exception using errcode='PT404',message='Team is unavailable';end if;
 perform taskfold_private.team_actor();
 if taskfold_private.team_role(t,a) is null then raise exception using errcode='PT404',message='Team is unavailable';end if;
 if operation='move' and (not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=t) or taskfold_private.team_project_role(a,p) is distinct from 'manager') then
  raise exception using errcode='42501',message='Project management access is required';end if;
 if operation='create_subproject' and taskfold_private.team_role(t,a)='guest' then raise exception using errcode='42501',message='Team membership is required';end if;
 if action<>'review_hierarchy' then
  q=taskfold_private.team_uuid(b,'request_id');
  if jsonb_typeof(b->'issued_at') is distinct from 'string' or (b->>'issued_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then raise exception using errcode='22023',message='Review the project request again';end if;
  begin issued=(b->>'issued_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review the project request again';end;
  if issued<clock_timestamp()-interval '15 minutes' or issued>clock_timestamp()+interval '1 minute' then raise exception using errcode='PT409',message='Review the project request again';end if;
  fingerprint=encode(extensions.digest(convert_to(jsonb_build_array(action,b)::text,'UTF8'),'sha256'),'hex');
  select * into prior from taskfold_private.team_project_commands where team_id=t and request_id=q;
  if found then
   if prior.actor_id=a and prior.fingerprint=fingerprint and taskfold_private.team_project_role(a,p)='manager' then return prior.result;end if;
   raise exception using errcode='PT409',message='Project request changed or management access is unavailable';end if;
  if jsonb_typeof(b->'team_revision') is distinct from 'number' or (b->>'team_revision')::numeric<>team.revision then raise exception using errcode='PT409',message='Team changed; review it again';end if;
 end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team setup is paused';end if;
 if team.state<>'active' then raise exception using errcode='PT409',message='Reopen this team first';end if;
 today=(clock_timestamp() at time zone 'UTC')::date;
 if action<>'review_hierarchy' and team.usage_day=today and team.day_operations>=2000 then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 if operation='move' then
  if action='review_hierarchy' then
   select * into binding from taskfold_private.team_content_projects where project_id=p and team_id=t for share;
   select * into node from public.projects where id=p for share;
  else
   select * into binding from taskfold_private.team_content_projects where project_id=p and team_id=t for update;
   select * into node from public.projects where id=p for update;
  end if;
  if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
  if node.parent_id is not distinct from dest then raise exception using errcode='PT409',message='This project already has that parent';end if;
  branch=taskfold_private.team_project_branch(a,t,p);
  if action<>'review_hierarchy' and (jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')::numeric<>binding.revision) then raise exception using errcode='PT409',message='Project changed; review it again';end if;
 else
  if exists(select 1 from public.projects where id=p) or exists(select 1 from taskfold_private.team_project_identities where project_id=p) then raise exception using errcode='PT409',message='Project identity is unavailable';end if;
  branch=jsonb_build_object('ids',jsonb_build_array(p),'tree_token',p,'affected_count',1,'height',1);
 end if;
 select array_agg(value::uuid order by value::uuid) into ids from jsonb_array_elements_text(branch->'ids');
 if dest=any(ids) then raise exception using errcode='22023',message='Choose a parent outside this project branch';end if;
 if dest is not null then
  select * into parent_binding from taskfold_private.team_content_projects where project_id=dest and team_id=t for share;
  if not found or taskfold_private.team_project_role(a,dest) is distinct from 'manager' then raise exception using errcode='42501',message='Management access to the destination is required';end if;
  select * into parent_node from public.projects where id=dest for share;
  if not found then raise exception using errcode='42501',message='The destination is unavailable';end if;
 end if;
 ancestry=taskfold_private.team_project_ancestors(t,dest);
 if (ancestry->>'depth')::integer+(branch->>'height')::integer>20 then raise exception using errcode='54000',message='This move would exceed 20 project levels';end if;
 token=encode(extensions.digest(convert_to(jsonb_build_array(operation,p,branch->'tree_token',ancestry->'manifest')::text,'UTF8'),'sha256'),'hex');
 if action='review_hierarchy' then
  return jsonb_build_object('protocol',1,'project_hierarchy_protocol',1,'account',a,'team_id',t,'id',p,'operation',operation,'team_revision',team.revision,
   'revision',case when operation='move' then binding.revision end,'parent_id',dest,'parent_revision',case when dest is not null then parent_binding.revision end,
   'tree_token',token,'affected_count',branch->'affected_count','destination_archived',ancestry->'archived','is_archived',coalesce(node.is_archived,false));
 end if;
 if jsonb_typeof(b->'tree_token') is distinct from 'string' or b->>'tree_token' !~ '^[0-9a-f]{64}$' or b->>'tree_token'<>token
  or jsonb_typeof(b->'affected_count') is distinct from 'number' or b->'affected_count' is distinct from branch->'affected_count'
  or jsonb_typeof(b->'destination_archived') is distinct from 'boolean' or b->'destination_archived' is distinct from ancestry->'archived'
  or jsonb_typeof(b->'is_archived') is distinct from 'boolean' or b->'is_archived' is distinct from to_jsonb(coalesce(node.is_archived,false))
  or (dest is null and b->'parent_revision'<>'null'::jsonb)
  or (dest is not null and (jsonb_typeof(b->'parent_revision') is distinct from 'number' or (b->>'parent_revision')::numeric<>parent_binding.revision)) then
   raise exception using errcode='PT409',message='The project branch or destination changed; review it again';end if;
 if operation='create_subproject' then
  if (select count(*) from taskfold_private.team_content_projects where team_id=t)>=1000 then raise exception using errcode='54000',message='Team project limit reached';end if;
  new_name=taskfold_private.team_name(b);chosen_visibility=b->>'visibility';
  if jsonb_typeof(b->'visibility') is distinct from 'string' or chosen_visibility not in('team','private') then raise exception using errcode='22023',message='Choose team or private visibility';end if;
  if b->'folder_id'<>'null'::jsonb then folder=taskfold_private.team_uuid(b,'folder_id');end if;
  if folder is not null and not exists(select 1 from taskfold_private.team_folders where id=folder and team_id=t) then raise exception using errcode='22023',message='Choose a folder in this team';end if;
  insert into public.projects(id,user_id,name) values(p,a,new_name);
  insert into taskfold_private.team_content_projects(project_id,team_id,visibility,folder_id) values(p,t,chosen_visibility,folder);
  insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role) values(p,t,a,'manager');
 else
  perform 1 from taskfold_private.team_content_projects where project_id=any(ids) order by project_id for update;
  perform 1 from public.projects where id=any(ids) order by id for update;
  if exists(select 1 from taskfold_private.team_content_projects where project_id=any(ids) and revision>=9007199254740991) then raise exception using errcode='54000',message='Project revision limit reached';end if;
 end if;
 perform taskfold_private.team_actor();
 insert into taskfold_private.team_project_hierarchy_operations(transaction_id,actor_id,team_id,project_id,root_id,parent_id,operation)
  select txid_current(),a,t,x.id,p,case when x.id=p then dest else x.parent_id end,operation from public.projects x where x.id=any(ids);
 update public.projects set parent_id=dest,ancestor_archived=(ancestry->>'archived')::boolean where id=p;
 delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);
 if operation='move' then update taskfold_private.team_content_projects set revision=revision+1 where project_id=any(ids);end if;
 update taskfold_private.teams set usage_day=today,day_operations=case when usage_day=today then least(day_operations+1,2000) else 1 end where id=t;
 result=jsonb_build_object('protocol',1,'account',a,'request_id',q,'id',p,'team_id',t,'team_revision',team.revision,'revision',case when operation='create_subproject' then 1 else binding.revision+1 end,
  'project_hierarchy_protocol',1,'parent_id',dest,'affected_count',cardinality(ids),'is_archived',coalesce(node.is_archived,false),'ancestor_archived',ancestry->'archived');
 delete from taskfold_private.team_project_commands where team_id=t and created_at<clock_timestamp()-interval '1 day';
 insert into taskfold_private.team_project_commands values(t,q,a,fingerprint,result,clock_timestamp());
 return result;
end$$;
revoke all on function taskfold_private.team_project_hierarchy_command(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_project_hierarchy_command(text,jsonb) to authenticated;

create or replace function taskfold_private.team_project_present(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare result jsonb; rows jsonb;
begin
 result=taskfold_private.team_project_hierarchy_command(action,b);
 if action='list' then
  select coalesce(jsonb_agg(z.row||taskfold_private.team_project_hierarchy_projection(auth.uid(),p.id)||jsonb_build_object('project_state_protocol',1,'is_archived',p.is_archived,'ancestor_archived',p.ancestor_archived,'name',case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end) order by z.position),'[]') into rows
   from jsonb_array_elements(result->'projects') with ordinality z(row,position) join public.projects p on p.id=(z.row->>'id')::uuid;
  return jsonb_set(result,'{projects}',rows);
 elsif action='get' then
  result=result||taskfold_private.team_project_hierarchy_projection(auth.uid(),(result->>'id')::uuid)||(select jsonb_build_object('project_state_protocol',1,'is_archived',p.is_archived,'ancestor_archived',p.ancestor_archived) from public.projects p where p.id=(result->>'id')::uuid)||jsonb_build_object('name',(select case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end from public.projects p where p.id=(result->>'id')::uuid));
  if result->>'role'='manager' then
   -- Project managers need accepted recipients, not global account search. Names
   -- are presentation only. Email remains restricted to the team admin directory.
   select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',case when m.user_id=t.owner_id then 'owner' else m.role end,
    'display_name',case when char_length(btrim(p.display_name)) between 1 and 100 and octet_length(btrim(p.display_name))<=400 and p.display_name !~ '[[:cntrl:]]' then btrim(p.display_name) end) order by m.user_id),'[]') into rows
    from taskfold_private.team_members m join taskfold_private.teams t on t.id=m.team_id
    join auth.users u on u.id=m.user_id and u.email_confirmed_at is not null and coalesce(u.email,'')<>'' and (u.banned_until is null or u.banned_until<=clock_timestamp())
    left join public.profiles p on p.user_id=m.user_id
    where m.team_id=(result->>'team_id')::uuid and not exists(select 1 from taskfold_private.account_removal_receipts r where r.account_id=m.user_id and r.created_at>clock_timestamp()-interval '7 days');
   result=result||jsonb_build_object('eligible_members',rows);
  end if;
 end if;
 return result;
end$$;
revoke all on function taskfold_private.team_project_present(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_project_present(text,jsonb) to authenticated;
create or replace function public.taskfold_team_projects(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_project_present(_action,_body)$$;
revoke all on function public.taskfold_team_projects(text,jsonb) from public,anon,service_role;
grant execute on function public.taskfold_team_projects(text,jsonb) to authenticated;

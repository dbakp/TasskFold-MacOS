-- Reviewed team-project metadata only. Source-only; no rollout flag is enabled.
-- Exact private scopes keep ordinary project/task/comment/file writes closed.
create table taskfold_private.team_project_metadata_operations (
 transaction_id bigint not null,
 actor_id uuid not null,
 team_id uuid not null,
 project_id uuid not null,
 root_id uuid not null,
 operation text not null check(operation in('rename','archive','unarchive')),
 primary key(transaction_id,project_id)
);
alter table taskfold_private.team_project_metadata_operations enable row level security;
revoke all on taskfold_private.team_project_metadata_operations from public,anon,authenticated,service_role;

create function taskfold_private.guard_team_project_metadata() returns trigger
language plpgsql security definer set search_path='' as $$
declare t uuid; scope taskfold_private.team_project_metadata_operations; allowed text[];
begin
 if auth.uid() is null then if tg_op='DELETE' then return old;else return new;end if;end if;
 select team_id into t from taskfold_private.team_content_projects where project_id=old.id;
 if t is null or exists(select 1 from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=t) then
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 if tg_op='UPDATE' then
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
drop trigger aaa_taskfold_team_content_closed on public.projects;
create trigger aaa_taskfold_team_content_closed before update or delete on public.projects for each row execute function taskfold_private.guard_team_project_metadata();

-- Caller holds the team row and legacy same-creator hierarchy advisory lock.
-- A branch is reviewed in full or rejected without disclosing private children.
create function taskfold_private.team_project_branch(a uuid,t uuid,p uuid) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare ids uuid[]; bad boolean; n integer; token text; creator uuid;
begin
 select user_id into creator from public.projects where id=p;
 with recursive tree(id,parent_id,depth,path,cycle) as (
  select x.id,x.parent_id,1,array[x.id],false from public.projects x where x.id=p
  union all
  select x.id,x.parent_id,s.depth+1,s.path||x.id,x.id=any(s.path) from public.projects x join tree s on x.parent_id=s.id where s.depth<=20 and not s.cycle
 ), bounded as(select * from tree limit 1001)
 select array_agg(id order by id),count(*),bool_or(cycle or depth>20) into ids,n,bad from bounded;
 if n not between 1 and 1000 or coalesce(bad,true) then raise exception using errcode='54000',message='This project branch cannot be reviewed safely';end if;
 if exists(select 1 from public.projects x left join taskfold_private.team_content_projects c on c.project_id=x.id where x.id=any(ids)
  and (c.team_id is distinct from t or x.user_id is distinct from creator or taskfold_private.team_project_role(a,x.id) is distinct from 'manager'))
  or exists(select 1 from public.projects x left join taskfold_private.team_content_projects c on c.project_id=x.parent_id where x.id=p and x.parent_id is not null and c.team_id is distinct from t) then
  raise exception using errcode='42501',message='Management access is required for the entire project branch';end if;
 select encode(extensions.digest(convert_to(jsonb_agg(jsonb_build_array(x.id,x.parent_id,c.revision,x.is_archived,x.ancestor_archived) order by x.id)::text,'UTF8'),'sha256'),'hex') into token
  from public.projects x join taskfold_private.team_content_projects c on c.project_id=x.id where x.id=any(ids);
 return jsonb_build_object('ids',to_jsonb(ids),'tree_token',token,'affected_count',n);
end$$;
revoke all on function taskfold_private.team_project_branch(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function taskfold_private.team_project_metadata_command(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();t uuid;p uuid;q uuid;creator uuid;team taskfold_private.teams;binding taskfold_private.team_content_projects;
 root public.projects;prior taskfold_private.team_project_commands;branch jsonb;ids uuid[];fingerprint text;issued timestamptz;result jsonb;today date;operation text;n text;
begin
 if action not in('rename','archive','unarchive','review_structure') then return taskfold_private.team_project_command(action,b);end if;
 perform taskfold_private.team_actor();
 if action='review_structure' then perform taskfold_private.team_fields(b,array['team_id','project_id','operation']);
 elsif action='rename' then perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','revision','name']);
 else perform taskfold_private.team_fields(b,array['team_id','project_id','request_id','issued_at','team_revision','revision','tree_token','affected_count']);end if;
 t=taskfold_private.team_uuid(b,'team_id');p=taskfold_private.team_uuid(b,'project_id');
 operation=case when action='review_structure' then b->>'operation' else action end;
 if operation not in('rename','archive','unarchive') or operation is null or (action='review_structure' and operation='rename') then raise exception using errcode='22023',message='Choose an archive operation';end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if action='review_structure' then select * into team from taskfold_private.teams where id=t and state<>'deleted' for share;
 else select * into team from taskfold_private.teams where id=t and state<>'deleted' for update;end if;
 if not found then raise exception using errcode='PT404',message='Team is unavailable';end if;
 perform taskfold_private.team_actor();
 if taskfold_private.team_role(t,a) is null then raise exception using errcode='PT404',message='Team is unavailable';end if;
 if not exists(select 1 from taskfold_private.team_content_projects where project_id=p and team_id=t) or taskfold_private.team_project_role(a,p) is distinct from 'manager' then
  raise exception using errcode='42501',message='Project management access is required';end if;
 -- Same lock as the existing hierarchy trigger, including personal child inserts.
 select user_id into creator from public.projects where id=p;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(creator::text,20261020));
 select * into binding from taskfold_private.team_content_projects where project_id=p and team_id=t for update;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 select * into root from public.projects where id=p for update;
 if not found then raise exception using errcode='PT404',message='Project is unavailable';end if;
 if action<>'review_structure' then
  q=taskfold_private.team_uuid(b,'request_id');
  if jsonb_typeof(b->'issued_at') is distinct from 'string' or (b->>'issued_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then raise exception using errcode='22023',message='Review the project request again';end if;
  begin issued=(b->>'issued_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review the project request again';end;
  if issued<clock_timestamp()-interval '15 minutes' or issued>clock_timestamp()+interval '1 minute' then raise exception using errcode='PT409',message='Review the project request again';end if;
  fingerprint=encode(extensions.digest(convert_to(jsonb_build_array(action,b)::text,'UTF8'),'sha256'),'hex');
  select * into prior from taskfold_private.team_project_commands where team_id=t and request_id=q;
  if found then
   if prior.actor_id=a and prior.fingerprint=fingerprint then return prior.result;end if;
   raise exception using errcode='PT409',message='Project request changed';end if;
  if jsonb_typeof(b->'team_revision') is distinct from 'number' or (b->>'team_revision')::numeric<>team.revision then raise exception using errcode='PT409',message='Team changed; review it again';end if;
  if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')::numeric<>binding.revision or binding.revision>=9007199254740991 then raise exception using errcode='PT409',message='Project changed; review it again';end if;
 end if;
 if operation<>'archive' then
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team setup is paused';end if;
  if team.state<>'active' then raise exception using errcode='PT409',message='Reopen this team first';end if;
 end if;
 today=(clock_timestamp() at time zone 'UTC')::date;
 if action<>'review_structure' and operation<>'archive' and team.usage_day=today and team.day_operations>=2000 then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 if operation='rename' then
  n=taskfold_private.team_name(b);
  if n=root.name then raise exception using errcode='PT409',message='The project already has this name';end if;
  ids=array[p];
 else
  branch=taskfold_private.team_project_branch(a,t,p);
  select array_agg(value::uuid order by value::uuid) into ids from jsonb_array_elements_text(branch->'ids');
  perform 1 from taskfold_private.team_content_projects where project_id=any(ids) order by project_id for update;
  perform 1 from public.projects where id=any(ids) order by id for update;
  -- Re-read after row waits, under the hierarchy/team locks.
  branch=taskfold_private.team_project_branch(a,t,p);
  if root.is_archived=(operation='archive') then raise exception using errcode='PT409',message='The project archive state changed';end if;
  if operation='unarchive' and root.ancestor_archived then raise exception using errcode='PT409',message='Reopen the parent project first';end if;
  if action='review_structure' then
   return jsonb_build_object('protocol',1,'project_state_protocol',1,'account',a,'team_id',t,'id',p,'operation',operation,'team_revision',team.revision,'revision',binding.revision,
    'is_archived',root.is_archived,'ancestor_archived',root.ancestor_archived,'tree_token',branch->'tree_token','affected_count',branch->'affected_count');
  end if;
  if jsonb_typeof(b->'tree_token') is distinct from 'string' or b->>'tree_token' !~ '^[0-9a-f]{64}$' or b->'tree_token' is distinct from branch->'tree_token'
   or jsonb_typeof(b->'affected_count') is distinct from 'number' or b->'affected_count' is distinct from branch->'affected_count' then
   raise exception using errcode='PT409',message='The project branch changed; review it again';end if;
 end if;
 -- Authentication may have changed while waiting for project/hierarchy locks.
 perform taskfold_private.team_actor();
 if exists(select 1 from taskfold_private.team_content_projects where project_id=any(ids) and revision>=9007199254740991) then raise exception using errcode='54000',message='Project revision limit reached';end if;
 insert into taskfold_private.team_project_metadata_operations select txid_current(),a,t,x,p,operation from unnest(ids) x;
 if operation='rename' then update public.projects set name=n where id=p;
 else update public.projects set is_archived=(operation='archive') where id=p;end if;
 delete from taskfold_private.team_project_metadata_operations where transaction_id=txid_current() and project_id=any(ids);
 update taskfold_private.team_content_projects set revision=revision+1 where project_id=any(ids);
 update taskfold_private.teams set usage_day=today,day_operations=case when usage_day=today then least(day_operations+1,2000) else 1 end where id=t;
 result=jsonb_build_object('protocol',1,'account',a,'request_id',q,'id',p,'team_id',t,'revision',binding.revision+1,'team_revision',team.revision);
 if operation<>'rename' then result=result||jsonb_build_object('project_state_protocol',1,'is_archived',operation='archive','ancestor_archived',root.ancestor_archived,'affected_count',cardinality(ids));end if;
 delete from taskfold_private.team_project_commands where team_id=t and created_at<clock_timestamp()-interval '1 day';
 insert into taskfold_private.team_project_commands values(t,q,a,fingerprint,result,clock_timestamp());
 return result;
end$$;
revoke all on function taskfold_private.team_project_metadata_command(text,jsonb) from public,anon,authenticated,service_role;
-- Direct execution remains authenticated and fully guarded like the old dispatcher.
grant execute on function taskfold_private.team_project_metadata_command(text,jsonb) to authenticated;

create or replace function taskfold_private.team_project_present(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare result jsonb; rows jsonb;
begin
 result=taskfold_private.team_project_metadata_command(action,b);
 if action='list' then
  select coalesce(jsonb_agg(z.row||jsonb_build_object('project_state_protocol',1,'is_archived',p.is_archived,'ancestor_archived',p.ancestor_archived,'name',case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end) order by z.position),'[]') into rows
   from jsonb_array_elements(result->'projects') with ordinality z(row,position) join public.projects p on p.id=(z.row->>'id')::uuid;
  return jsonb_set(result,'{projects}',rows);
 elsif action='get' then
  result=result||(select jsonb_build_object('project_state_protocol',1,'is_archived',p.is_archived,'ancestor_archived',p.ancestor_archived) from public.projects p where p.id=(result->>'id')::uuid)||jsonb_build_object('name',(select case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end from public.projects p where p.id=(result->>'id')::uuid));
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

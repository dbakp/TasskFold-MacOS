-- A native refresh is accepted under one current access boundary. Content still
-- uses ordinary RLS reads and guarded writes; no legacy policy is widened.
create table taskfold_private.team_access_epochs (
 team_id uuid primary key references taskfold_private.teams(id) on delete restrict,
 revision bigint not null default 1 check(revision between 1 and 9007199254740991)
);
insert into taskfold_private.team_access_epochs(team_id) select id from taskfold_private.teams;
alter table taskfold_private.team_access_epochs enable row level security;
revoke all on taskfold_private.team_access_epochs from public,anon,authenticated,service_role;
create function taskfold_private.bump_team_access_epoch() returns trigger
language plpgsql security definer set search_path='' as $$
declare t uuid;p uuid;begin
 if tg_table_name='teams' then
  t=case when tg_op='DELETE' then old.id else new.id end;
 elsif tg_table_schema='public' then
  if tg_op='UPDATE' and (old.parent_id,old.is_archived,old.ancestor_archived) is not distinct from (new.parent_id,new.is_archived,new.ancestor_archived) then return new;end if;
  p=case when tg_op='DELETE' then old.id else new.id end;
  select team_id into t from taskfold_private.team_project_identities where project_id=p;
 else t=case when tg_op='DELETE' then old.team_id else new.team_id end;end if;
 if t is not null then
  insert into taskfold_private.team_access_epochs(team_id) values(t)
   on conflict(team_id) do update set revision=taskfold_private.team_access_epochs.revision+1;
 end if;
 if tg_op='DELETE' then return old;else return new;end if;
end$$;
revoke all on function taskfold_private.bump_team_access_epoch() from public,anon,authenticated,service_role;
create trigger team_workspace_access_epoch after insert or update or delete on taskfold_private.teams for each row execute function taskfold_private.bump_team_access_epoch();
create trigger team_workspace_member_epoch after insert or update or delete on taskfold_private.team_members for each row execute function taskfold_private.bump_team_access_epoch();
create trigger team_workspace_grant_epoch after insert or update or delete on taskfold_private.team_project_grants for each row execute function taskfold_private.bump_team_access_epoch();
create trigger team_workspace_binding_epoch after insert or update or delete on taskfold_private.team_content_projects for each row execute function taskfold_private.bump_team_access_epoch();
create trigger team_workspace_project_epoch after update or delete on public.projects for each row execute function taskfold_private.bump_team_access_epoch();

create function taskfold_private.workspace_boundary() returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare a uuid:=auth.uid();ids uuid[]:='{}';tr taskfold_private.teams;reads boolean;edits boolean;enabled boolean;projects jsonb;teams jsonb;result jsonb;token text;
begin
 perform taskfold_private.team_actor();
 select native_reads_enabled,native_task_edits_enabled into reads,edits from taskfold_private.team_project_config where singleton for share;
 select c.enabled into enabled from taskfold_private.team_config c where singleton for share;
 -- Match role-command serialization; recheck identity after every potential wait.
 for tr in select t.* from taskfold_private.teams t join taskfold_private.team_members m on m.team_id=t.id where m.user_id=a and t.state<>'deleted' order by t.id for share of t loop ids=array_append(ids,tr.id);end loop;
 perform 1 from taskfold_private.team_access_epochs e where e.team_id=any(ids) order by e.team_id for share;
 perform taskfold_private.team_actor();
 -- The epoch includes access ABA changes, not ordinary task edits. Continuous
 -- collaboration need not prevent refreshing under unchanged permissions.
 select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'state',t.state,'revision',t.revision,'access_revision',e.revision) order by t.id),'[]') into teams
  from taskfold_private.teams t join taskfold_private.team_access_epochs e on e.team_id=t.id
  join taskfold_private.team_members m on m.team_id=t.id and m.user_id=a where t.id=any(ids) and t.state<>'deleted' and reads;
 select coalesce(jsonb_agg(v order by id),'[]') into projects from (
  select p.id,jsonb_build_object('id',p.id,'team_id',null,'role',case when p.user_id=a then 'owner' else 'collaborator' end,
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',true) v
  from public.projects p where not exists(select 1 from taskfold_private.team_project_identities i where i.project_id=p.id)
   and (p.user_id=a or exists(select 1 from public.project_collaborators c where c.project_id=p.id and c.user_id=a and c.status='accepted'))
  union all
  select p.id,jsonb_build_object('id',p.id,'team_id',c.team_id,'role',taskfold_private.team_project_role(a,p.id),
   'archived',p.is_archived or p.ancestor_archived,'can_send_tasks',coalesce(edits and enabled and t.state='active' and not(p.is_archived or p.ancestor_archived) and taskfold_private.team_project_role(a,p.id) in('manager','editor'),false))
  from public.projects p join taskfold_private.team_content_projects c on c.project_id=p.id join taskfold_private.teams t on t.id=c.team_id
  where reads and c.team_id=any(ids) and t.state<>'deleted' and taskfold_private.team_project_role(a,p.id) is not null
 ) q;
 if jsonb_array_length(projects)>10000 or jsonb_array_length(teams)>1000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 result=jsonb_build_object('workspace_boundary_protocol',1,'account',a,'native_team_reads_enabled',coalesce(reads,false),'setup_paused',not coalesce(enabled,false),'projects',projects,'teams',teams);
 select encode(extensions.hmac(convert_to(result::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 result=result||jsonb_build_object('token',token);
 if octet_length(result::text)>3000000 then raise exception using errcode='54000',message='This workspace access list is too large to refresh safely';end if;
 return result;
end$$;
create function public.taskfold_workspace_boundary() returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.workspace_boundary()$$;
revoke all on function taskfold_private.workspace_boundary(),public.taskfold_workspace_boundary() from public,anon,authenticated,service_role;
grant execute on function taskfold_private.workspace_boundary(),public.taskfold_workspace_boundary() to authenticated;

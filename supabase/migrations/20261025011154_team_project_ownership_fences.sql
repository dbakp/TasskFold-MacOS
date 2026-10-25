-- Source-only ownership-cutover primitives. No adoption API or rollout is enabled.
-- Each row has its own monotonic epoch: unrelated edits never contend on one
-- project-wide counter, and delete/recreate or edit/revert cannot reuse a review.
create table taskfold_private.project_content_epochs (
 table_name text not null,row_id uuid not null,
 revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 primary key(table_name,row_id)
);
-- Tickets exist only inside the writing transaction and are removed by its
-- deferred validator. UNLOGGED is safe here: after a crash the associated
-- uncommitted public writes roll back; a committed transaction has no tickets.
create unlogged table taskfold_private.project_realm_writes (
 id uuid primary key default gen_random_uuid(),transaction_id bigint not null,
 before_realms jsonb not null,approved_realms jsonb not null default '{}'
);
create index project_realm_writes_transaction on taskfold_private.project_realm_writes(transaction_id);
create table taskfold_private.team_project_adoption_scope (
 transaction_id bigint not null,actor_id uuid not null,team_id uuid not null,
 project_id uuid not null,root_id uuid not null,parent_id uuid,
 visibility text not null check(visibility in('team','private')),folder_id uuid,
 primary key(transaction_id,project_id)
);
alter table taskfold_private.project_content_epochs enable row level security;
alter table taskfold_private.project_realm_writes enable row level security;
alter table taskfold_private.team_project_adoption_scope enable row level security;
revoke all on taskfold_private.project_content_epochs,taskfold_private.project_realm_writes,taskfold_private.team_project_adoption_scope from public,anon,authenticated,service_role;

create function taskfold_private.capture_project_realm_write() returns trigger
language plpgsql security definer set search_path='' as $$
declare ids uuid[];p uuid;before_map jsonb:='{}';team uuid;row_id uuid;v jsonb;doc jsonb;
begin
 if tg_op='UPDATE' and to_jsonb(new) is not distinct from to_jsonb(old) then return new;end if;
 if tg_op='DELETE' then row_id=old.id;else row_id=new.id;end if;
 if tg_table_name='projects' then
  ids=array[row_id];
  if tg_op<>'INSERT' then ids=array_append(ids,old.parent_id);end if;
  if tg_op<>'DELETE' then ids=array_append(ids,new.parent_id);end if;
 elsif tg_table_name in('tasks','sections','task_comments','project_collaborators') then
  if tg_op<>'INSERT' then ids=array_append(ids,old.project_id);end if;
  if tg_op<>'DELETE' then ids=array_append(ids,new.project_id);end if;
 elsif tg_table_name='task_mentions' then
  select array_agg(distinct c.project_id) into ids from public.task_comments c
   where c.id=case when tg_op='DELETE' then old.comment_id else new.comment_id end;
 elsif tg_table_name='task_assignment_provenance' then
  select array_agg(t.project_id) into ids from public.tasks t
   where t.id=case when tg_op='DELETE' then old.task_id else new.task_id end;
 elsif tg_table_name='task_activity' then
  if tg_op='DELETE' then doc=to_jsonb(old);else doc=to_jsonb(new);end if;
  select array_agg(t.project_id) into ids from public.tasks t where t.id=(doc->>'task_id')::uuid;
  for v in select value from jsonb_each(jsonb_build_object('before',doc->'before_state','after',doc->'after_state')) loop
   if v->>'project_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then ids=array_append(ids,(v->>'project_id')::uuid);end if;
  end loop;
 end if;
 for p in select distinct x from unnest(coalesce(ids,'{}')) x where x is not null order by x loop
  select team_id into team from taskfold_private.team_project_identities where project_id=p;
  before_map=before_map||jsonb_build_object(p::text,team);
 end loop;
 -- Team custody is immutable; its existing native scopes remain authoritative.
 -- Inbox-only writes cannot cross a project ownership boundary either.
 if before_map='{}' or not exists(select 1 from jsonb_each(before_map) e where e.value='null'::jsonb) then
  if tg_op='DELETE' then return old;else return new;end if;
 end if;
 -- Reading a mention is not an authored-content change and must not invalidate
 -- a contents review. It still receives the ownership check at commit.
 if not (tg_table_name='task_mentions' and tg_op='UPDATE' and
  (to_jsonb(new)-array['read_at','revision'])=(to_jsonb(old)-array['read_at','revision'])) then
  insert into taskfold_private.project_content_epochs(table_name,row_id) values(tg_table_name,row_id)
   on conflict on constraint project_content_epochs_pkey do update set revision=taskfold_private.project_content_epochs.revision+1;
 end if;
 insert into taskfold_private.project_realm_writes(transaction_id,before_realms) values(txid_current(),before_map);
 if tg_op='DELETE' then return old;else return new;end if;
end$$;

create function taskfold_private.validate_project_realm_writes() returns trigger
language plpgsql security definer set search_path='' as $$
declare p text;team uuid;item record;v record;current_realm jsonb;
begin
 if not exists(select 1 from taskfold_private.project_realm_writes where id=new.id) then return null;end if;
 -- Collect every ticket before the first check. Try-locks never wait while a
 -- writer holds a task/comment row needed by an ownership transaction.
 for p in select distinct k from taskfold_private.project_realm_writes w
  cross join lateral jsonb_object_keys(w.before_realms) k where w.transaction_id=txid_current() order by k loop
  if not pg_try_advisory_xact_lock_shared(hashtextextended('project-realm:'||p,20261025)) then
   raise exception using errcode='PT409',message='Project ownership is changing. Refresh before retrying this saved edit';end if;
 end loop;
 for item in select * from taskfold_private.project_realm_writes where transaction_id=txid_current() loop
  for v in select key,value from jsonb_each(item.before_realms) loop
   select team_id into team from taskfold_private.team_project_identities where project_id=v.key::uuid;
   current_realm=coalesce(to_jsonb(team),'null'::jsonb);
   if current_realm is distinct from v.value and current_realm is distinct from item.approved_realms->v.key then
    raise exception using errcode='PT409',message='This project changed workspaces. Refresh before retrying this saved edit';end if;
  end loop;
 end loop;
 delete from taskfold_private.project_realm_writes where transaction_id=txid_current();
 return null;
end$$;
create constraint trigger project_ownership_at_commit after insert on taskfold_private.project_realm_writes
 deferrable initially deferred for each row execute function taskfold_private.validate_project_realm_writes();

create function taskfold_private.try_project_adoption_fences(projects uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare p uuid;begin
 if projects is null or cardinality(projects) not between 1 and 1000 or array_position(projects,null) is not null then
  raise exception using errcode='22023',message='Choose a bounded project branch';end if;
 -- The reviewed controller must first NOWAIT-lock the current content rows,
 -- then take these fences and recheck the complete row-ID set and content proof.
 -- New/unseen rows must cause a new review, never a blocking lock after here.
 for p in select distinct x from unnest(projects) x order by x loop
  if not pg_try_advisory_xact_lock(hashtextextended('project-realm:'||p::text,20261025)) then
   raise exception using errcode='PT409',message='A project edit is still finishing. Refresh the transfer review';end if;
 end loop;
end$$;

create function taskfold_private.validate_adoption_placement() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.projects p join taskfold_private.team_content_projects b on b.project_id=p.id
  where p.id=new.project_id and p.user_id=new.actor_id and p.parent_id is not distinct from new.parent_id
   and b.team_id=new.team_id and b.visibility=new.visibility and b.folder_id is not distinct from new.folder_id) then
  raise exception using errcode='PT409',message='The reviewed project placement was not completed';end if;
 return null;
end$$;
create constraint trigger project_adoption_final_placement after insert on taskfold_private.team_project_adoption_scope
 deferrable initially deferred for each row execute function taskfold_private.validate_adoption_placement();

create function taskfold_private.guard_legacy_collaborator_realm() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is not null and exists(select 1 from taskfold_private.team_project_identities where project_id=new.project_id) then
  -- Match the existing invitation trigger's narrowly defined Auth/profile
  -- maintenance, not a native invitation acceptance against an old snapshot.
  if tg_op='UPDATE' and pg_trigger_depth()>1 then
   if old.user_id is null and new.user_id is not null and (to_jsonb(new)-'user_id')=(to_jsonb(old)-'user_id')
    and exists(select 1 from auth.users where id=new.user_id and lower(email)=lower(new.invited_email)) then return new;end if;
   if old.user_id is not null and new.user_id is null and (to_jsonb(new)-'user_id')=(to_jsonb(old)-'user_id')
    and not exists(select 1 from auth.users where id=old.user_id) then return new;end if;
   if old.invited_by is not null and new.invited_by is null and (to_jsonb(new)-'invited_by')=(to_jsonb(old)-'invited_by')
    and (not exists(select 1 from auth.users where id=old.invited_by) or not exists(select 1 from public.profiles where user_id=old.invited_by)) then return new;end if;
  end if;
  raise exception using errcode='42501',message='Manage team project access through a reviewed team action';
 end if;
 return new;
end$$;
create trigger a0_taskfold_collaborator_realm before insert or update on public.project_collaborators
 for each row execute function taskfold_private.guard_legacy_collaborator_realm();

do $$declare n text;begin
 foreach n in array array['projects','tasks','sections','project_collaborators','task_comments','task_mentions','task_activity','task_assignment_provenance'] loop
  if to_regclass('public.'||n) is not null then
   execute format('create trigger zz_taskfold_ownership_capture before insert or update or delete on public.%I for each row execute function taskfold_private.capture_project_realm_write()',n);
  end if;
 end loop;
end$$;
revoke all on function taskfold_private.capture_project_realm_write(),taskfold_private.validate_project_realm_writes(),taskfold_private.try_project_adoption_fences(uuid[]),taskfold_private.validate_adoption_placement(),taskfold_private.guard_legacy_collaborator_realm() from public,anon,authenticated,service_role;

create or replace function taskfold_private.admit_team_content_project() returns trigger
language plpgsql security definer set search_path='' as $$
declare creator uuid;plan taskfold_private.team_project_adoption_scope;begin
 if tg_op='UPDATE' then
  if new.project_id is distinct from old.project_id or new.team_id is distinct from old.team_id then raise exception using errcode='PT409',message='Team project custody cannot be reassigned';end if;
 else
  select user_id into creator from public.projects where id=new.project_id;
  perform 1 from auth.users where id=creator for key share;
  if not found then raise exception using errcode='23503',message='Project creator is no longer available';end if;
  perform 1 from taskfold_private.teams where id=new.team_id and state='active' for update;
  if not found then raise exception using errcode='PT409',message='Team is unavailable';end if;
  perform 1 from public.projects where id=new.project_id for no key update;
  perform taskfold_private.try_project_adoption_fences(array[new.project_id]);
  select * into plan from taskfold_private.team_project_adoption_scope
   where transaction_id=txid_current() and project_id=new.project_id and team_id=new.team_id and actor_id=auth.uid();
  if found then
   if creator is distinct from plan.actor_id or new.visibility<>plan.visibility or new.folder_id is distinct from plan.folder_id then
    raise exception using errcode='42501',message='The project transfer scope changed';end if;
   if exists(select 1 from public.projects c where c.parent_id=new.project_id and not exists(
      select 1 from taskfold_private.team_content_projects b where b.project_id=c.id and b.team_id=new.team_id)
     and not exists(select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=new.team_id and s.project_id=c.id and s.parent_id=new.project_id))
    or plan.parent_id is not null and not exists(select 1 from taskfold_private.team_content_projects b where b.project_id=plan.parent_id and b.team_id=new.team_id)
     and not exists(select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=new.team_id and s.project_id=plan.parent_id)
    or exists(select 1 from public.tasks c join public.tasks parent on parent.id=c.recurrence_parent_id
     left join taskfold_private.team_content_projects cb on cb.project_id=c.project_id
     left join taskfold_private.team_content_projects pb on pb.project_id=parent.project_id
     where (c.project_id=new.project_id or parent.project_id=new.project_id)
      and (case when c.project_id=new.project_id then new.team_id else coalesce(cb.team_id,(select s.team_id from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.project_id=c.project_id)) end)
       is distinct from (case when parent.project_id=new.project_id then new.team_id else coalesce(pb.team_id,(select s.team_id from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.project_id=parent.project_id)) end)) then
    raise exception using errcode='22023',message='Review all linked projects in the same team transfer';end if;
  else
  if exists(select 1 from public.projects c left join taskfold_private.team_content_projects b on b.project_id=c.id where c.parent_id=new.project_id and b.team_id is distinct from new.team_id)
   or exists(select 1 from public.projects c left join taskfold_private.team_content_projects b on b.project_id=c.parent_id where c.id=new.project_id and c.parent_id is not null and b.team_id is distinct from new.team_id)
   or exists(select 1 from public.tasks c join public.tasks parent on parent.id=c.recurrence_parent_id
    left join taskfold_private.team_content_projects cb on cb.project_id=c.project_id
    left join taskfold_private.team_content_projects pb on pb.project_id=parent.project_id
    where (c.project_id=new.project_id or parent.project_id=new.project_id)
     and (case when c.project_id=new.project_id then new.team_id else cb.team_id end) is distinct from (case when parent.project_id=new.project_id then new.team_id else pb.team_id end)) then
   raise exception using errcode='22023',message='Move linked work into the same workspace before sharing';end if;
  end if;
  insert into taskfold_private.team_project_identities values(new.project_id,new.team_id);
  -- Only the private binding writer can approve this transaction's own
  -- deliberate cutover. Another transaction's earlier ticket is never stamped.
  update taskfold_private.project_realm_writes w set approved_realms=w.approved_realms||jsonb_build_object(new.project_id::text,new.team_id)
   where w.transaction_id=txid_current() and w.before_realms->new.project_id::text='null'::jsonb;
  insert into taskfold_private.team_content_tasks(task_id,generation,team_id,project_id)
   select id,coalesce(task_generation,'00000000-0000-0000-0000-000000000000'),new.team_id,new.project_id from public.tasks where project_id=new.project_id on conflict(task_id,generation) do nothing;
 end if;
 if new.folder_id is not null and not exists(select 1 from taskfold_private.team_folders where id=new.folder_id and team_id=new.team_id) then raise exception using errcode='22023',message='Choose a folder in this team';end if;
 return new;
end$$;

CREATE OR REPLACE FUNCTION taskfold_private.clear_departed_assignments()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
 -- The reviewed transfer preserves eligible assignments itself. Do not erase
 -- them merely because the obsolete personal invitation rows are being retired.
 if exists(select 1 from taskfold_private.team_project_adoption_scope s
  where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.project_id=old.project_id) then return null;end if;
 if old.status = 'accepted' and old.user_id is not null and (tg_op='DELETE' or new.status <> 'accepted') then
   -- Another accepted membership, if present, still grants access.
   if not public.has_project_access(old.user_id,old.project_id) then
     update public.tasks set
       assigned_to = case when assigned_to=old.user_id then null else assigned_to end,
       subtasks = taskfold_private.clear_assignee(subtasks,old.user_id)
     where project_id=old.project_id and (assigned_to=old.user_id or subtasks::text like '%' || old.user_id::text || '%');
   end if;
 end if;
 return null;
end $function$
;
revoke all on function taskfold_private.admit_team_content_project(),taskfold_private.clear_departed_assignments() from public,anon,authenticated,service_role;

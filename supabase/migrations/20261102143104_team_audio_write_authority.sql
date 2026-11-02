-- Candidate only. New team publication is separately disabled by default.
-- Media remains bound to its exact task generation and project. Existing custody
-- triggers still refuse moves/replacement while live recordings exist.
alter table taskfold_private.audio_comment_config
 add column team_publication_enabled boolean not null default false;

create function taskfold_private.audio_team_scope(a uuid,t uuid,g uuid,p uuid,writable boolean) returns boolean
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare root public.tasks;team uuid;role text;
begin
 select * into root from public.tasks where id=t and task_generation=g and project_id=p for share;
 if not found or p is null or coalesce(to_jsonb(root)->'is_heading','false'::jsonb) not in('false'::jsonb,'null'::jsonb) then return false;end if;
 -- Discover without a binding lock; access management locks team before binding.
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if not found then return false;end if;
 perform 1 from taskfold_private.teams where id=team and state<>'deleted' and (not writable or state='active') for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and (not writable or native_task_edits_enabled) for share;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 if not found then return false;end if;
 perform 1 from public.projects where id=p and (not writable or (not is_archived and not ancestor_archived)) for share;
 if not found then return false;end if;
 -- FOR UPDATE also fences an absent explicit grant: a concurrent INSERT grant
 -- needs a foreign-key key-share lock on this membership row. A downgrade must
 -- not race an implicit team-visible editor authorization.
 if writable then
  perform 1 from taskfold_private.team_members where team_id=team and user_id=a for update;
 else
  perform 1 from taskfold_private.team_members where team_id=team and user_id=a for share;
 end if;
 if not found then return false;end if;
 perform 1 from taskfold_private.team_project_grants where project_id=p and user_id=a for share;
 perform 1 from taskfold_private.team_content_tasks where task_id=t and generation=g and project_id=p and team_id=team for share;
 if not found then return false;end if;
 role:=taskfold_private.team_project_role(a,p);
 return coalesce(role in('manager','editor','viewer') and (not writable or role in('manager','editor')),false);
end$$;
revoke all on function taskfold_private.audio_team_scope(uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;

create or replace function taskfold_private.audio_scope(a uuid,t uuid,g uuid,p uuid,writable boolean) returns boolean
language plpgsql volatile security definer set search_path='' as $$
declare task public.tasks;project public.projects;
begin
 -- Replace in place so already-prepared coordinator plans keep the same OID.
 -- The personal branch retains its previous scope and collaborator semantics.
 if not taskfold_private.is_team_content_task(t) then
  select * into task from public.tasks where id=t and task_generation=g and project_id is not distinct from p for share;
  if not found or coalesce(to_jsonb(task)->'is_heading','false'::jsonb) not in('false'::jsonb,'null'::jsonb) then return false;end if;
  if p is null then return coalesce(task.user_id=a,false);end if;
  select * into project from public.projects where id=p for share;
  if not found or (writable and (project.is_archived or project.ancestor_archived)) or not coalesce(public.has_project_access(a,p),false) then return false;end if;
  if project.user_id=a then return true;end if;
  perform 1 from public.project_collaborators where project_id=p and user_id=a and status='accepted' for share;
  return found;
 end if;
 if writable then
  perform 1 from taskfold_private.audio_comment_config where singleton and team_publication_enabled for share;
  if not found then return false;end if;
 end if;
 return taskfold_private.audio_team_scope(a,t,g,p,writable);
end$$;
revoke all on function taskfold_private.audio_scope(uuid,uuid,uuid,uuid,boolean) from public,anon,authenticated,service_role;

alter function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) rename to audio_comment_before_team_writes;
revoke all on function taskfold_private.audio_comment_before_team_writes(text,uuid,uuid,jsonb) from public,anon,authenticated,service_role;
create function taskfold_private.audio_comment_command(action text,a uuid,s uuid,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare id uuid;original taskfold_private.audio_comment_publications;r taskfold_private.audio_comment_publications;role text;
begin
 if action is distinct from 'remove' then return taskfold_private.audio_comment_before_team_writes(action,a,s,b);end if;
 if not coalesce(taskfold_private.audio_actor(a,s),false) then return jsonb_build_object('status','unavailable');end if;
 perform taskfold_private.audio_fields(b,array['comment_id']);id:=taskfold_private.audio_uuid(b,'comment_id');
 select * into original from taskfold_private.audio_comment_publications where comment_id=id;
 if not found then return jsonb_build_object('status','unavailable');end if;
 if not taskfold_private.is_team_content_project(original.project_id) then
  return taskfold_private.audio_comment_before_team_writes(action,a,s,b);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-account:'||a::text,20261028));
 perform pg_advisory_xact_lock(hashtextextended('audio-task:'||original.task_id::text,20261028));
 if not coalesce(taskfold_private.audio_actor(a,s),false)
  or not taskfold_private.audio_team_scope(a,original.task_id,original.task_generation,original.project_id,true) then
  return jsonb_build_object('status','unavailable');end if;
 role:=taskfold_private.team_project_role(a,original.project_id);
 if original.author_id is distinct from a and role is distinct from 'manager' then return jsonb_build_object('status','unavailable');end if;
 perform pg_advisory_xact_lock(hashtextextended('audio-operation:'||original.operation_id::text,20261028));
 select * into r from taskfold_private.audio_comment_publications where operation_id=original.operation_id and comment_id=id
  and task_id=original.task_id and task_generation=original.task_generation and project_id=original.project_id for update;
 if not found then return jsonb_build_object('status','unavailable');end if;
 -- Disable publishing without stranding removal. Retire metadata only; the
 -- existing fenced worker owns byte deletion and eventual quota release.
 if r.state not in('retired','purged') then
  update taskfold_private.audio_comment_publications set state='retired',caption=null,audio_descriptor=null,
   cleanup_after=clock_timestamp()+interval '5 minutes' where operation_id=r.operation_id returning * into r;
 end if;
 return jsonb_build_object('protocol',1,'account',a,'operation_id',r.operation_id,'comment_id',r.comment_id,'state',r.state);
end$$;
revoke all on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function taskfold_private.audio_comment_command(text,uuid,uuid,jsonb) to service_role;
create or replace function public.taskfold_audio_comment_command(_action text,_actor uuid,_session uuid,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.audio_comment_command(_action,_actor,_session,_body)$$;
revoke all on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.taskfold_audio_comment_command(text,uuid,uuid,jsonb) to service_role;

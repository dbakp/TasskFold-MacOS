-- Source-only assignment directory. No rollout or table privileges change.
-- The existing write service independently rechecks recipients when applying a task edit.
create function taskfold_private.team_task_recipients(_team_id uuid,_project_id uuid) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid(); boundary jsonb; access jsonb; ids uuid[]; people jsonb; result jsonb;
begin
 -- This acquires live actor/session, config, sorted team and access-epoch locks
 -- in the same order as workspace refresh and role-management commands.
 boundary=taskfold_private.workspace_boundary();
 select p into access from jsonb_array_elements(boundary->'projects') p
  where p->>'id'=_project_id::text and p->>'team_id'=_team_id::text and p->'can_send_tasks'='true'::jsonb;
 if access is null then raise exception using errcode='42501',message='Open an editable team project before choosing an assignee';end if;
 select array_agg(user_id order by user_id) into ids from
  (select user_id from taskfold_private.team_members where team_id=_team_id order by user_id limit 501) q;
 if coalesce(cardinality(ids),0)>500 then raise exception using errcode='54000',message='This project recipient list exceeds the supported limit';end if;
 -- Read-only candidates are current at this query's snapshot. Do not lock other
 -- Auth rows after teams: account removal uses Auth-before-team lock ordering.
 -- No cached catalog can authorize a write; assignment submission rechecks live rights.
 select coalesce(jsonb_agg(jsonb_build_object('user_id',u.id,'role',taskfold_private.team_project_role(u.id,_project_id),
  'display_name',case when char_length(btrim(p.display_name)) between 1 and 100 and octet_length(btrim(p.display_name))<=400 and p.display_name !~ '[[:cntrl:]]' and p.display_name !~ U&'[\202A-\202E\2066-\2069]' then btrim(p.display_name) end) order by u.id),'[]') into people
 from auth.users u left join public.profiles p on p.user_id=u.id
 where u.id=any(coalesce(ids,'{}')) and u.email_confirmed_at is not null and coalesce(u.email,'')<>''
  and (u.banned_until is null or u.banned_until<=clock_timestamp())
  and not exists(select 1 from taskfold_private.account_removal_receipts r where r.account_id=u.id and r.created_at>clock_timestamp()-interval '7 days')
  and taskfold_private.team_project_role(u.id,_project_id) in('manager','editor');
 perform taskfold_private.team_actor();
 result=jsonb_build_object('recipient_protocol',1,'account',a,'team_id',_team_id,'project_id',_project_id,
  'access_token',boundary->'token','recipients',people);
 if octet_length(result::text)>350000 then raise exception using errcode='54000',message='This project recipient list is too large';end if;
 return result;
end$$;
create function public.taskfold_team_task_recipients(_team_id uuid,_project_id uuid) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_task_recipients(_team_id,_project_id)$$;
revoke all on function taskfold_private.team_task_recipients(uuid,uuid),public.taskfold_team_task_recipients(uuid,uuid) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_task_recipients(uuid,uuid),public.taskfold_team_task_recipients(uuid,uuid) to authenticated;

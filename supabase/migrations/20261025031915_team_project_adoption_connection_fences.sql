-- Source-only coordination for reviewed project connection cutover.
-- This does not enable adoption, pause connections, retarget credentials or send mail.
-- Every sending permit is identity-only and outlives cancellation of its queue row.
create table taskfold_private.webhook_write_permits (
 event_id uuid not null,lease_id uuid not null,project_id uuid,task_id uuid not null,
 safe_until timestamptz not null check(isfinite(safe_until)),primary key(event_id,lease_id)
);
create index webhook_write_permits_project on taskfold_private.webhook_write_permits(project_id,safe_until);
create index webhook_write_permits_task on taskfold_private.webhook_write_permits(task_id,safe_until);
create index webhook_write_permits_expiry on taskfold_private.webhook_write_permits(safe_until);
alter table taskfold_private.webhook_write_permits enable row level security;
revoke all on taskfold_private.webhook_write_permits from public,anon,authenticated,service_role;
-- Cleanup is bounded and never waits behind another permit pruner while a
-- worker holds account/task locks. Expired rows never confer delivery authority.
create function taskfold_private.prune_webhook_write_permits() returns integer
language plpgsql volatile security invoker set search_path='' as $$
declare removed integer;begin
 with expired as(select event_id,lease_id from taskfold_private.webhook_write_permits
  where safe_until<=clock_timestamp() order by safe_until,event_id,lease_id limit 256 for update skip locked)
 delete from taskfold_private.webhook_write_permits p using expired e where (p.event_id,p.lease_id)=(e.event_id,e.lease_id);
 get diagnostics removed=row_count;return removed;
end$$;
revoke all on function taskfold_private.prune_webhook_write_permits() from public,anon,authenticated,service_role;
-- Cover a packet authorized by the preceding implementation during migration.
insert into taskfold_private.webhook_write_permits(event_id,lease_id,project_id,task_id,safe_until)
 select id,lease_id,access_project,task_id,clock_timestamp()+interval '60 seconds'
 from taskfold_private.webhook_outbox where status='leased' and authorized_at is not null and lease_id is not null;

create index email_routes_adoption_project on taskfold_private.email_routes(project_id,id) where state<>'revoked';
create index webhook_subscriptions_adoption_project on taskfold_private.webhook_subscriptions(project_id,id) where state<>'revoked';
create index webhook_subscriptions_adoption_global on taskfold_private.webhook_subscriptions(user_id,id) where scope='all' and state<>'revoked';
create index webhook_outbox_adoption_project on taskfold_private.webhook_outbox(access_project,id) where payload is not null and status in('pending','leased','failed');
create index webhook_outbox_adoption_task on taskfold_private.webhook_outbox(task_id,id) where payload is not null and status in('pending','leased','failed');

create function taskfold_private.project_adoption_connection_accounts(ids uuid[]) returns uuid[]
language sql volatile security invoker set search_path='' as $$
 select coalesce(array_agg(distinct person order by person),'{}'::uuid[]) from (
  select user_id person from public.projects where id=any(ids)
  union select user_id from public.project_collaborators where project_id=any(ids) and status='accepted'
  union select user_id from taskfold_private.email_routes where project_id=any(ids) and state<>'revoked'
  union select user_id from taskfold_private.webhook_subscriptions where project_id=any(ids) and state<>'revoked'
  union select user_id from taskfold_private.webhook_outbox where payload is not null and status in('pending','leased','failed')
   and (access_project=any(ids) or task_id in(select id from public.tasks where project_id=any(ids)))
 ) x where person is not null
$$;
create function taskfold_private.try_project_adoption_connection_accounts(ids uuid[],people uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare person uuid;accounts uuid[]:=taskfold_private.project_adoption_connection_accounts(ids);begin
 if not accounts <@ people then raise exception using errcode='PT409',message='Personal connection participants changed; review again';end if;
 -- Auth rows are already locked in the closed participant cohort. Never wait
 -- here while a service worker could hold this account lock and need a task row.
 foreach person in array accounts loop
  if not pg_try_advisory_xact_lock(hashtextextended('automation:'||person::text,11819)) then
   raise exception using errcode='PT409',message='A personal connection is still finishing; review again';end if;
 end loop;
end$$;
create function taskfold_private.lock_project_adoption_connections(ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$
begin
 perform 1 from taskfold_private.email_routes where project_id=any(ids) and state<>'revoked' order by id for no key update nowait;
 perform 1 from taskfold_private.webhook_subscriptions h where h.state<>'revoked' and
  (h.project_id=any(ids) or h.scope='all' and h.user_id in(select user_id from public.projects where id=any(ids) union select user_id from public.project_collaborators where project_id=any(ids) and status='accepted')) order by id for no key update nowait;
 perform 1 from taskfold_private.webhook_budgets b where b.subscription_id in(
  select subscription_id from taskfold_private.webhook_outbox where payload is not null and status in('pending','leased','failed')
   and (access_project=any(ids) or task_id in(select id from public.tasks where project_id=any(ids)))) order by subscription_id for no key update nowait;
 perform 1 from taskfold_private.webhook_outbox where payload is not null and status in('pending','leased','failed')
  and (access_project=any(ids) or task_id in(select id from public.tasks where project_id=any(ids))) order by id for no key update nowait;
exception when lock_not_available then raise exception using errcode='PT409',message='A connection or queued update is still finishing; review again';
end$$;

-- Direct/legacy private writers must participate too. Shared project-realm
-- tickets reuse the existing deferred, fresh read-committed ownership validator.
create function taskfold_private.capture_project_connection_write() returns trigger
language plpgsql security definer set search_path='' as $$
declare person uuid;p uuid;owners uuid[]:='{}';ids uuid[]:='{}';realms jsonb:='{}';team uuid;row_id uuid;begin
 if tg_op='UPDATE' and to_jsonb(new)=to_jsonb(old) then return null;end if;
 if tg_op<>'INSERT' then owners=array_append(owners,old.user_id);ids=array_append(ids,old.project_id);end if;
 if tg_op<>'DELETE' then owners=array_append(owners,new.user_id);ids=array_append(ids,new.project_id);end if;
 for person in select distinct x from unnest(owners) x where x is not null order by x loop
  if not pg_try_advisory_xact_lock(hashtextextended('automation:'||person::text,11819)) then
   raise exception using errcode='PT409',message='A project connection is being reviewed; retry this saved change';end if;
 end loop;
 if exists(select 1 from unnest(ids) x where x is not null) and current_setting('transaction_isolation')<>'read committed' then
  raise exception using errcode='25000',message='Use a fresh read-committed transaction for project connections';end if;
 if tg_op<>'DELETE' and new.project_id is not null and new.state in('active','pending') and taskfold_private.is_team_content_project(new.project_id) then
  raise exception using errcode='PT409',message='Use a reviewed team destination for this connection';end if;
 for p in select distinct x from unnest(ids) x where x is not null order by x loop
  select team_id into team from taskfold_private.team_project_identities where project_id=p;
  realms=realms||jsonb_build_object(p::text,team);
 end loop;
 if tg_op='DELETE' then row_id=old.id;else row_id=new.id;end if;
 insert into taskfold_private.project_content_epochs(table_name,row_id) values(tg_table_name,row_id)
  on conflict on constraint project_content_epochs_pkey do update set revision=taskfold_private.project_content_epochs.revision+1;
 if realms<>'{}' and exists(select 1 from jsonb_each(realms) r where r.value='null'::jsonb) then
  insert into taskfold_private.project_realm_writes(transaction_id,before_realms) values(txid_current(),realms);
 end if;
 return null;
end$$;
create trigger email_routes_adoption_boundary after insert or update or delete on taskfold_private.email_routes for each row execute function taskfold_private.capture_project_connection_write();
create trigger webhook_subscriptions_adoption_boundary after insert or update or delete on taskfold_private.webhook_subscriptions for each row execute function taskfold_private.capture_project_connection_write();
revoke all on function taskfold_private.project_adoption_connection_accounts(uuid[]),taskfold_private.try_project_adoption_connection_accounts(uuid[],uuid[]),taskfold_private.lock_project_adoption_connections(uuid[]),taskfold_private.capture_project_connection_write() from public,anon,authenticated,service_role;


create or replace function taskfold_private.project_adoption_people(ids uuid[],team uuid) returns uuid[]
language sql volatile security invoker set search_path='' as $$
 select coalesce(array_agg(distinct person order by person),'{}'::uuid[]) from (
  select auth.uid() person union select user_id from public.projects where id=any(ids)
  union select user_id from public.sections where project_id=any(ids)
  union select user_id from public.tasks where project_id=any(ids)
  union select user_id from public.project_collaborators where project_id=any(ids)
  union select invited_by from public.project_collaborators where project_id=any(ids)
  union select author_id from public.task_comments where project_id=any(ids)
  union select m.recipient_id from public.task_mentions m join public.task_comments c on c.id=m.comment_id where c.project_id=any(ids)
  union select p.actor_id from public.task_assignment_provenance p join public.tasks t on t.id=p.task_id where t.project_id=any(ids)
  union select p.assignee_id from public.task_assignment_provenance p join public.tasks t on t.id=p.task_id where t.project_id=any(ids)
  union select assigned_to from public.tasks where project_id=any(ids)
  union select (n.value->>'assignee')::uuid from public.tasks t cross join lateral jsonb_each(taskfold_private.assignment_nodes(t.subtasks)) n where t.project_id=any(ids)
  union select user_id from public.task_activity where before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) or task_id in(select id from public.tasks where project_id=any(ids))
  union select actor_id from public.task_activity where before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) or task_id in(select id from public.tasks where project_id=any(ids))
  union select unnest(taskfold_private.project_adoption_connection_accounts(ids))
  union select user_id from taskfold_private.team_members where team_id=team
 ) p where person is not null
$$;

create or replace function taskfold_private.project_adoption_contents(ids uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare item record; hashes jsonb:='{}'; counts jsonb:='{}'; rows jsonb; n bigint; bytes bigint; total bigint:=0; entries bigint:=0;
 attachments bigint; inline_files bigint; external_files bigint; unknown_files bigint; email_rows jsonb:='[]'; hooks jsonb:='[]';queue_rows jsonb:='[]';queued bigint;inflight bigint;begin
 for item in select * from(values
  ('projects','x.id=any($1)','to_jsonb(x)'),
  ('tasks','x.project_id=any($1)','to_jsonb(x)'),
  ('sections','x.project_id=any($1)','to_jsonb(x)'),
  ('project_collaborators','x.project_id=any($1)','to_jsonb(x)'),
  ('task_comments','x.project_id=any($1)','to_jsonb(x)'),
  ('task_mentions','exists(select 1 from public.task_comments c where c.id=x.comment_id and c.project_id=any($1))','to_jsonb(x)-array[''read_at'',''revision'']'),
  ('task_assignment_provenance','exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1))','to_jsonb(x)'),
  ('task_activity','exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1)) or x.before_state->>''project_id''=any($1::text[]) or x.after_state->>''project_id''=any($1::text[])','to_jsonb(x)')
 ) v(rel,predicate,projection) loop
  execute format('select count(*),coalesce(sum(octet_length((%s)::text)),0) from public.%I x where %s',item.projection,item.rel,item.predicate)
   into n,bytes using ids;
  total=total+bytes;entries=entries+n;
  if total>33554432 or entries>100000 or item.rel='tasks' and n>10000 or item.rel='project_collaborators' and n>1000 then
   raise exception using errcode='54000',message='These projects are too large to review as one atomic transfer';end if;
  execute format('select coalesce(jsonb_agg(jsonb_build_array(x.id,coalesce(e.revision,0),encode(extensions.digest(convert_to((%s)::text,''UTF8''),''sha256''),''hex'')) order by x.id),''[]'') from public.%I x left join taskfold_private.project_content_epochs e on e.table_name=%L and e.row_id=x.id where %s',item.projection,item.rel,item.rel,item.predicate)
   into rows using ids;
  hashes=hashes||jsonb_build_object(item.rel,encode(extensions.digest(convert_to(rows::text,'UTF8'),'sha256'),'hex'));
  counts=counts||jsonb_build_object(item.rel,n);
 end loop;
 rows=taskfold_private.project_adoption_attachments(ids);
 attachments=(rows->>'attachments')::bigint;inline_files=(rows->>'inline_files')::bigint;external_files=(rows->>'external_files')::bigint;unknown_files=(rows->>'provider_files')::bigint;
 -- Only private identity/state projections. Provider bindings need a reviewed
 -- pause/custody adapter before commit support; a count is not authorization.
 if to_regclass('taskfold_private.email_routes') is not null then
  execute 'select coalesce(jsonb_agg(jsonb_build_array(id,user_id,project_id,state,revision,coalesce((select e.revision from taskfold_private.project_content_epochs e where e.table_name=''email_routes'' and e.row_id=email_routes.id),0)) order by id),''[]'') from taskfold_private.email_routes where project_id=any($1) and state<>''revoked''' into email_rows using ids;
 end if;
 if to_regclass('taskfold_private.webhook_subscriptions') is not null then
  execute 'select coalesce(jsonb_agg(jsonb_build_array(id,user_id,project_id,scope,state,revision,expires_at,coalesce((select e.revision from taskfold_private.project_content_epochs e where e.table_name=''webhook_subscriptions'' and e.row_id=webhook_subscriptions.id),0)) order by id),''[]'') from taskfold_private.webhook_subscriptions where state<>''revoked'' and (project_id=any($1) or scope=''all'' and user_id in(select user_id from public.projects where id=any($1) union select user_id from public.project_collaborators where project_id=any($1) and status=''accepted''))' into hooks using ids;
 end if;
 if octet_length(email_rows::text)+octet_length(hooks::text)>1000000 then raise exception using errcode='54000',message='Too many integration destinations to review safely';end if;
 hashes=hashes||jsonb_build_object('email_routes',encode(extensions.digest(convert_to(email_rows::text,'UTF8'),'sha256'),'hex'),
  'webhook_subscriptions',encode(extensions.digest(convert_to(hooks::text,'UTF8'),'sha256'),'hex'));
 select count(*) into queued from taskfold_private.webhook_outbox e where e.payload is not null and e.status in('pending','leased','failed')
  and (e.access_project=any(ids) or e.task_id in(select id from public.tasks where project_id=any(ids)));
 if queued>100000 then raise exception using errcode='54000',message='Too many queued updates to review safely';end if;
 select coalesce(jsonb_agg(jsonb_build_array(e.id,e.subscription_id,e.task_id,e.task_generation,e.access_project,e.status,e.lease_id,e.lease_until,e.authorized_at,e.payload_sha256,e.next_part,e.part_attempts) order by e.id),'[]') into queue_rows
 from taskfold_private.webhook_outbox e where e.payload is not null and e.status in('pending','leased','failed')
  and (e.access_project=any(ids) or e.task_id in(select id from public.tasks where project_id=any(ids)));
 perform taskfold_private.prune_webhook_write_permits();
 select count(*) into inflight from taskfold_private.webhook_write_permits e where e.safe_until>clock_timestamp()
  and (e.project_id=any(ids) or e.task_id in(select id from public.tasks where project_id=any(ids)));
 hashes=hashes||jsonb_build_object('webhook_queue',encode(extensions.digest(convert_to(queue_rows::text,'UTF8'),'sha256'),'hex'));
 return jsonb_build_object('hashes',hashes,'counts',counts,'content_bytes',total,'attachments',attachments,'inline_files',inline_files,
  'external_files',external_files,'provider_files',unknown_files,'email_routes',jsonb_array_length(email_rows),'webhooks',jsonb_array_length(hooks),'queued_webhook_events',queued,'inflight_webhook_events',inflight);
end$$;

create or replace function taskfold_private.project_adoption_review(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid(); team uuid;roots uuid[];ids uuid[];person uuid;parent uuid;folder uuid;visibility text;
 forest jsonb;fresh jsonb;contents jsonb;people uuid[];ancestry jsonb;team_row taskfold_private.teams;epoch bigint;
 members jsonb;collaborators jsonb;decisions jsonb:='[]';item jsonb;result jsonb;snapshot text;token text;expires text;
 proof jsonb;project_rows jsonb;cleared bigint:=0;assignees jsonb;entry record;role text;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception using errcode='25000',message='Use a fresh read-committed transaction for this project transfer';end if;
 perform taskfold_private.team_actor();
 if operation='inspect' then perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id']);
 elsif operation='review' then perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id','inspection_token','decisions']);
 else raise exception using errcode='22023',message='Choose a supported project transfer review';end if;
 if octet_length(b::text)>262144 then raise exception using errcode='54000',message='This transfer review is too large';end if;
 team=taskfold_private.team_uuid(b,'team_id');
 if jsonb_typeof(b->'roots') is distinct from 'array' or jsonb_array_length(b->'roots') not between 1 and 100
  or exists(select 1 from jsonb_array_elements(b->'roots') x where jsonb_typeof(x)<>'string' or x#>>'{}' !~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$') then
  raise exception using errcode='22023',message='Choose project branches to transfer';end if;
 select array_agg(v::uuid order by v::uuid) into roots from jsonb_array_elements_text(b->'roots') v;
 if b->'parent_id'<>'null'::jsonb then parent=taskfold_private.team_uuid(b,'parent_id');end if;
 if b->'folder_id'<>'null'::jsonb then folder=taskfold_private.team_uuid(b,'folder_id');end if;
 visibility=b->>'visibility';
 if jsonb_typeof(b->'visibility')<>'string' or visibility not in('team','private') then raise exception using errcode='22023',message='Choose team-visible or private access';end if;
 forest=taskfold_private.project_adoption_forest(a,roots);select array_agg(v::uuid order by v::uuid) into ids from jsonb_array_elements_text(forest->'ids') v;
 if exists(select 1 from public.tasks where project_id=any(ids) and taskfold_private.assignment_nodes(subtasks) is null) then
  raise exception using errcode='PT409',message='Review unsupported checklist assignments before transferring';end if;
 if exists(select 1 from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id where t.project_id=any(ids)) then raise exception using errcode='PT409',message='Review existing task custody before transferring';end if;
 contents=taskfold_private.project_adoption_contents(ids);
 people=taskfold_private.project_adoption_people(ids,team);
 if cardinality(people)>2000 then raise exception using errcode='54000',message='This project transfer has too many participants to review safely';end if;
 perform 1 from auth.users where id=any(people) order by id for share;
 perform taskfold_private.try_project_adoption_connection_accounts(ids,people);
 perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team project transfers are not enabled';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team setup is paused';end if;
 -- Match existing membership/grant writers: team before access epoch, both
 -- UPDATE from the start. No shared-to-exclusive upgrade during later adoption.
 select * into team_row from taskfold_private.teams where id=team and state='active' for update;
 if not found or not taskfold_private.project_adoption_member_live(a,team) or coalesce(taskfold_private.team_role(team,a),'guest')='guest' then
  raise exception using errcode='42501',message='Team membership with project creation access is required';end if;
 select revision into epoch from taskfold_private.team_access_epochs where team_id=team for update;
 if not found then raise exception using errcode='PT409',message='Refresh team access before transferring';end if;
 if (select count(*) from taskfold_private.team_content_projects where team_id=team)+cardinality(ids)>1000 then raise exception using errcode='54000',message='This transfer would exceed the team project limit';end if;
 perform taskfold_private.team_actor();
 if folder is not null and not exists(select 1 from taskfold_private.team_folders where id=folder and team_id=team) then raise exception using errcode='42501',message='Choose an available folder in this team';end if;
 if parent is not null and taskfold_private.team_project_role(a,parent) is distinct from 'manager' then raise exception using errcode='42501',message='Management access to the destination parent is required';end if;
 ancestry=taskfold_private.team_project_ancestors(team,parent);
 if (select max((v->>'depth')::integer) from jsonb_array_elements(forest->'nodes') v)+(ancestry->>'depth')::integer>20 then
  raise exception using errcode='54000',message='This destination would exceed 20 project levels';end if;
 -- Nonblocking row locks cannot wait behind a personal writer that needs a team
 -- row held here. Re-expansion/proof after the fences discovers phantom inserts.
 begin
  perform 1 from public.projects where id=any(ids||array(select jsonb_array_elements_text(ancestry->'ids')::uuid)) order by id for no key update nowait;
  perform 1 from public.project_collaborators where project_id=any(ids) order by id for no key update nowait;
  perform 1 from public.tasks where project_id=any(ids) order by id for no key update nowait;
  perform 1 from public.sections where project_id=any(ids) order by id for no key update nowait;
  perform 1 from public.task_comments where project_id=any(ids) order by id for no key update nowait;
  perform 1 from public.task_mentions where comment_id in(select id from public.task_comments where project_id=any(ids)) order by id for no key update nowait;
  perform 1 from public.task_assignment_provenance where task_id in(select id from public.tasks where project_id=any(ids)) order by id for no key update nowait;
  perform 1 from public.task_activity where task_id in(select id from public.tasks where project_id=any(ids)) or before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) order by id for no key update nowait;
 exception when lock_not_available then raise exception using errcode='PT409',message='An edit is still finishing; refresh this transfer review';end;
 perform taskfold_private.lock_project_adoption_connections(ids);
 perform taskfold_private.try_project_adoption_fences(ids);
 fresh=taskfold_private.project_adoption_forest(a,roots);
 if fresh<>forest or taskfold_private.project_adoption_people(ids,team)<>people then raise exception using errcode='PT409',message='The project branch or participants changed; review again';end if;
 if exists(select 1 from public.tasks c join public.tasks p on p.id=c.recurrence_parent_id
  where (c.project_id=any(ids) or p.project_id=any(ids)) and
  (case when c.project_id=any(ids) then team else (select team_id from taskfold_private.team_project_identities where project_id=c.project_id) end)
  is distinct from (case when p.project_id=any(ids) then team else (select team_id from taskfold_private.team_project_identities where project_id=p.project_id) end)) then
  raise exception using errcode='PT409',message='Select the other linked personal project explicitly before transferring';end if;
 if exists(select 1 from public.task_comments c left join public.tasks t on t.id=c.task_id where c.project_id=any(ids) and (t.id is null or t.project_id is distinct from c.project_id or t.task_generation is distinct from c.task_generation))
  or exists(select 1 from public.tasks t left join public.sections s on s.id=t.section_id where t.project_id=any(ids) and t.section_id is not null and (s.id is null or s.project_id is distinct from t.project_id)) then
  raise exception using errcode='PT409',message='Review inconsistent task sections or discussions before transferring';end if;
 contents=taskfold_private.project_adoption_contents(ids);
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'root_id',n->'root_id','depth',n->'depth','name',case when char_length(p.name) between 1 and 100 and octet_length(p.name)<=400 and p.name !~ '[[:cntrl:]]' then p.name end,'parent_id',case when p.id=any(roots) then parent else p.parent_id end,
  'is_archived',p.is_archived,'source_ancestor_archived',p.ancestor_archived) order by (n->>'depth')::integer,p.id),'[]') into project_rows
 from public.projects p join jsonb_array_elements(forest->'nodes') n on n->>'id'=p.id::text;
 select coalesce(jsonb_agg(jsonb_build_array(m.user_id,m.role,taskfold_private.project_adoption_member_live(m.user_id,team)) order by m.user_id),'[]') into members from taskfold_private.team_members m where m.team_id=team;
 select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'project_id',c.project_id,'user_id',c.user_id,'email',case when octet_length(c.invited_email)<=320 and c.invited_email !~ '[[:cntrl:]]' then c.invited_email end,'status',c.status,
  'eligible',c.user_id is not null and taskfold_private.project_adoption_member_live(c.user_id,team)) order by c.project_id,c.id),'[]') into collaborators from public.project_collaborators c where c.project_id=any(ids);
 proof=jsonb_build_array(1,a,team,roots,visibility,folder,parent,forest,contents,team_row.revision,epoch,members,ancestry,collaborators);
 select encode(extensions.hmac(convert_to(proof::text,'UTF8'),s.secret,'sha256'),'hex') into snapshot from taskfold_private.automation_revision_secret s where singleton;
 result=jsonb_build_object('project_adoption_protocol',1,'account',a,'team_id',team,'roots',roots,'visibility',visibility,'folder_id',folder,'parent_id',parent,
  'projects',project_rows,'contents',contents-'hashes','collaborators',collaborators,'inspection_token',snapshot,
  'destination_archived',ancestry->'archived','team_name',team_row.name,'creates_memberships',false,'sends_invitations',false,'automatic_undo',false,
  'commit_supported',coalesce((select native_project_adoption_enabled from taskfold_private.team_project_config where singleton),false) and (contents->>'inflight_webhook_events')::bigint=0 and (contents->>'provider_files')::bigint=0 and (contents->>'email_routes')::integer=0 and (contents->>'webhooks')::integer=0,'team_member_count',jsonb_array_length(members));
 if operation='inspect' then return result;end if;
 if jsonb_typeof(b->'inspection_token') is distinct from 'string' or b->>'inspection_token' is distinct from snapshot then raise exception using errcode='PT409',message='The project contents or access changed; inspect the transfer again';end if;
 if jsonb_typeof(b->'decisions') is distinct from 'array' or jsonb_array_length(b->'decisions')>1000 then raise exception using errcode='22023',message='Review every accepted collaborator';end if;
 for item in select value from jsonb_array_elements(b->'decisions') loop
  perform taskfold_private.team_fields(item,array['project_id','user_id','role']);
  perform taskfold_private.team_uuid(item,'project_id');perform taskfold_private.team_uuid(item,'user_id');
  if item->'role'<>'null'::jsonb and (jsonb_typeof(item->'role')<>'string' or item->>'role' not in('editor','viewer')) then raise exception using errcode='22023',message='Choose editor, viewer or retire personal access';end if;
  if not exists(select 1 from public.project_collaborators c where c.project_id=(item->>'project_id')::uuid and c.project_id=any(ids) and c.user_id=(item->>'user_id')::uuid and c.status='accepted') then raise exception using errcode='22023',message='Choose an existing accepted collaborator';end if;
  if item->'role'<>'null'::jsonb and not taskfold_private.project_adoption_member_live((item->>'user_id')::uuid,team) then raise exception using errcode='PT409',message='Retained collaborators must already be eligible team members';end if;
 end loop;
 if (select count(*) from jsonb_array_elements(b->'decisions'))<>(select count(distinct ((v->>'project_id')::uuid,(v->>'user_id')::uuid)) from jsonb_array_elements(b->'decisions') v)
  or exists(select 1 from public.project_collaborators c where c.project_id=any(ids) and c.status='accepted' and c.user_id is not null and
   not exists(select 1 from jsonb_array_elements(b->'decisions') d where (d->>'project_id')::uuid=c.project_id and (d->>'user_id')::uuid=c.user_id)) then raise exception using errcode='22023',message='Choose one explicit decision for each accepted collaborator';end if;
 select coalesce(jsonb_agg(jsonb_build_object('project_id',(v->>'project_id')::uuid,'user_id',(v->>'user_id')::uuid,'role',v->'role') order by (v->>'project_id')::uuid,(v->>'user_id')::uuid),'[]') into decisions from jsonb_array_elements(b->'decisions') v;
 select coalesce(jsonb_agg(v||jsonb_build_object('effective_role',taskfold_private.project_adoption_role((v->>'user_id')::uuid,(v->>'project_id')::uuid,team,visibility,decisions)) order by v->>'project_id',v->>'user_id'),'[]') into assignees from jsonb_array_elements(decisions) v;
 for entry in select t.project_id,t.assigned_to person from public.tasks t where t.project_id=any(ids) and t.assigned_to is not null
  union all select t.project_id,(n.value->>'assignee')::uuid from public.tasks t cross join lateral jsonb_each(taskfold_private.assignment_nodes(t.subtasks)) n where t.project_id=any(ids) and n.value->>'assignee' is not null loop
  role=taskfold_private.project_adoption_role(entry.person,entry.project_id,team,visibility,decisions);
  if coalesce(role,'') not in('manager','editor') then cleared=cleared+1;end if;
 end loop;
 expires=to_char(clock_timestamp()+interval '15 minutes','YYYY-MM-DD"T"HH24:MI:SS.US"Z"');
 select encode(extensions.hmac(convert_to(jsonb_build_array(1,a,snapshot,decisions,expires)::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 return result||jsonb_build_object('decisions',assignees,'assignments_cleared',cleared,'invitations_closed',jsonb_array_length(collaborators),
  'review_token',token,'expires_at',expires,'requires_provider_custody',(contents->>'provider_files')::bigint>0,
  'requires_integration_pause',(contents->>'email_routes')::integer>0 or (contents->>'webhooks')::integer>0);
end$$;

create or replace function taskfold_private.project_adoption_commit(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;q uuid;fingerprint text;prior taskfold_private.project_adoption_receipts;
 preview jsonb;body jsonb;decisions jsonb;expires timestamptz;proof text;ids uuid[];roots uuid[];parent uuid;folder uuid;visibility text;
 node jsonb;t public.tasks;item record;desired jsonb;recipient uuid;cleared integer:=0;role text;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception using errcode='25000',message='Use a fresh read-committed transaction for this project transfer';end if;
 perform taskfold_private.team_actor();
 perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id','inspection_token','decisions','review_token','expires_at','request_id']);
 if octet_length(b::text)>262144 then raise exception using errcode='54000',message='This transfer request is too large';end if;
 team=taskfold_private.team_uuid(b,'team_id');q=taskfold_private.team_uuid(b,'request_id');
 if not pg_try_advisory_xact_lock(hashtextextended(team::text||':'||q::text,2026102502)) then raise exception using errcode='PT409',message='This transfer is still finishing; retry the saved request';end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(1,a,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 select * into prior from taskfold_private.project_adoption_receipts where team_id=team and request_id=q;
 if found then
  if prior.actor_id<>a or prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This transfer request identity is already used';end if;
  -- No content is returned or projected over later work. Confirmation can be
  -- recovered after access changes, an expired review, or a disabled rollout.
  return taskfold_private.project_adoption_receipt_reply(prior,true);
 end if;
 if jsonb_typeof(b->'expires_at') is distinct from 'string' or b->>'expires_at' !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$'
  or jsonb_typeof(b->'review_token') is distinct from 'string' or b->>'review_token' !~ '^[0-9a-f]{64}$' then raise exception using errcode='22023',message='Review this project transfer again';end if;
 begin expires=(b->>'expires_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review this project transfer again';end;
 if expires<=clock_timestamp() or expires>clock_timestamp()+interval '16 minutes' then raise exception using errcode='PT409',message='This transfer review expired; review again';end if;
 -- A personal hierarchy writer takes this owner lock before it changes rows.
 -- Never wait for it while holding team/content rows in the new custody order.
 if not pg_try_advisory_xact_lock(hashtextextended(a::text,20261020)) then raise exception using errcode='PT409',message='A personal project move is still finishing; review again';end if;
 body=b-array['review_token','expires_at','request_id'];
 preview=taskfold_private.project_adoption_review('review',body);
 perform 1 from taskfold_private.team_project_config where singleton and native_project_adoption_enabled for share;
 if not found then raise exception using errcode='PT503',message='Team project transfers are not enabled';end if;
 select coalesce(jsonb_agg(v-array['effective_role'] order by (v->>'project_id')::uuid,(v->>'user_id')::uuid),'[]') into decisions from jsonb_array_elements(preview->'decisions') v;
 select encode(extensions.hmac(convert_to(jsonb_build_array(1,a,preview->>'inspection_token',decisions,b->>'expires_at')::text,'UTF8'),s.secret,'sha256'),'hex') into proof from taskfold_private.automation_revision_secret s where singleton;
 if proof is distinct from b->>'review_token' then raise exception using errcode='PT409',message='The reviewed transfer changed; review again';end if;
 if exists(select 1 from taskfold_private.teams where id=team and usage_day=(clock_timestamp() at time zone 'UTC')::date and day_operations>=2000) then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 if (preview->'contents'->>'inflight_webhook_events')::bigint>0 then raise exception using errcode='PT409',message='An outgoing update is still finishing; review this transfer again';end if;
 if (preview->>'requires_provider_custody')::boolean or (preview->>'requires_integration_pause')::boolean then
  raise exception using errcode='PT409',message='Review file custody and personal integration destinations before transferring';end if;
 select array_agg((v->>'id')::uuid order by (v->>'id')::uuid) into ids from jsonb_array_elements(preview->'projects') v;
 select array_agg(v::uuid order by v::uuid) into roots from jsonb_array_elements_text(preview->'roots') v;
 parent=(preview->>'parent_id')::uuid;folder=(preview->>'folder_id')::uuid;visibility=preview->>'visibility';
 -- Exact authority is transaction-local and never available through a client
 -- setting/JWT. Any error rolls back all assignment/access/placement changes.
 insert into taskfold_private.team_project_adoption_scope(transaction_id,actor_id,team_id,project_id,root_id,parent_id,visibility,folder_id)
 select txid_current(),a,team,(v->>'id')::uuid,(v->>'root_id')::uuid,(v->>'parent_id')::uuid,visibility,folder from jsonb_array_elements(preview->'projects') v;
 -- Clear only reviewed ineligible assignees while these are still personal
 -- rows and all reviewed memberships still exist. The provenance trigger keeps
 -- every unchanged eligible assignment's original event/actor/date byte-exact.
 for t in select * from public.tasks where project_id=any(ids) order by id loop
  desired=coalesce(t.subtasks,'[]');recipient=t.assigned_to;
  if recipient is not null and coalesce(taskfold_private.project_adoption_role(recipient,t.project_id,team,visibility,decisions),'') not in('manager','editor') then recipient=null;cleared=cleared+1;end if;
  for item in select distinct (n.value->>'assignee')::uuid person from jsonb_each(taskfold_private.assignment_nodes(t.subtasks)) n where n.value->>'assignee' is not null loop
   role=taskfold_private.project_adoption_role(item.person,t.project_id,team,visibility,decisions);
   if coalesce(role,'') not in('manager','editor') then
    cleared=cleared+(select count(*) from jsonb_each(taskfold_private.assignment_nodes(desired)) n where n.value->>'assignee'=item.person::text);
    desired=taskfold_private.project_adoption_clear_assignee(desired,item.person);
   end if;
  end loop;
  if recipient is distinct from t.assigned_to or desired is distinct from t.subtasks then update public.tasks set assigned_to=recipient,subtasks=desired where id=t.id;end if;
 end loop;
 if cleared<>(preview->>'assignments_cleared')::integer then raise exception using errcode='PT409',message='The reviewed assignment changes no longer match';end if;
 delete from public.project_collaborators where project_id=any(ids);
 -- Detach selected roots from their external personal parents before creating
 -- team bindings. Final placement is checked again by deferred exact scopes.
 update public.projects set parent_id=null where id=any(roots) and parent_id is not null;
 insert into taskfold_private.team_content_projects(project_id,team_id,visibility,folder_id)
  select id,team,cmd.visibility,folder from public.projects where id=any(ids) order by id;
 insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role)
  select id,team,a,'manager' from unnest(ids) id;
 insert into taskfold_private.team_project_grants(project_id,team_id,user_id,role)
  select (v->>'project_id')::uuid,team,(v->>'user_id')::uuid,v->>'role' from jsonb_array_elements(decisions) v
  where v->>'role' is not null and (v->>'user_id')::uuid<>a;
 insert into taskfold_private.team_project_hierarchy_operations(transaction_id,actor_id,team_id,project_id,root_id,parent_id,operation)
 select txid_current(),a,team,(v->>'id')::uuid,(v->>'root_id')::uuid,(v->>'parent_id')::uuid,'move' from jsonb_array_elements(preview->'projects') v;
 -- Root updates propagate inherited archive state through the same guarded
 -- hierarchy paths as ordinary team moves. Own archive flags never change.
 update public.projects set parent_id=parent,ancestor_archived=(preview->>'destination_archived')::boolean where id=any(roots);
 update taskfold_private.teams set usage_day=(clock_timestamp() at time zone 'UTC')::date,day_operations=case when usage_day=(clock_timestamp() at time zone 'UTC')::date then least(day_operations+1,2000) else 1 end where id=team;
 perform taskfold_private.team_actor();
 insert into taskfold_private.project_adoption_receipts(team_id,request_id,actor_id,fingerprint,project_ids,root_ids,parent_id,folder_id,visibility,assignments_cleared,invitations_closed)
 values(team,q,a,fingerprint,ids,roots,parent,folder,cmd.visibility,cleared,(preview->>'invitations_closed')::integer) returning * into prior;
 delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);
 delete from taskfold_private.team_project_adoption_scope where transaction_id=txid_current() and project_id=any(ids);
 return taskfold_private.project_adoption_receipt_reply(prior,false);
end$$;

create or replace function taskfold_private.webhook_prepare(_id uuid,_lease uuid,_authorize boolean) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare e taskfold_private.webhook_outbox;s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;t public.tasks;stamp timestamptz;reason text;wire text;part uuid;hex text;defer_until timestamptz;
begin
 select * into e from taskfold_private.webhook_outbox where id=_id;if not found then return jsonb_build_object('ready',false,'reason','stale');end if;
 -- A failed account lock is recorded under the same short locking order below.
 begin perform taskfold_private.automation_account_lock(e.user_id);exception when sqlstate '28000' then reason='account_unavailable';end;
 if exists(select 1 from taskfold_private.webhook_removal_blocks where user_id=e.user_id) then reason='account_unavailable';end if;
 if not e.minimal and reason is null then
  select * into t from public.tasks where id=e.task_id for share;
  if not found or coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid)<>e.task_generation or row(t.user_id,t.project_id) is distinct from row(e.access_owner,e.access_project) then reason='resource_unavailable';end if;
 end if;
 if reason is null then
  begin perform taskfold_private.automation_lock_task_access(e.user_id,e.access_owner,e.access_project);exception when sqlstate 'PT404' then reason='resource_unavailable';end;
 end if;
 select * into s from taskfold_private.webhook_subscriptions where id=e.subscription_id for share;
 if not found then return jsonb_build_object('ready',false,'reason','stale');end if;
 select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
 select * into e from taskfold_private.webhook_outbox where id=_id for update;
 stamp=clock_timestamp();
 if not found or e.status<>'leased' or e.lease_id is distinct from _lease or b.lease_id is distinct from _lease or e.lease_until<=stamp then return jsonb_build_object('ready',false,'reason','stale');end if;
 if reason is not null or s.state='revoked' or s.expires_at<=stamp or e.expires_at<=stamp then
  perform taskfold_private.webhook_terminal(e,case when e.expires_at<=stamp then 'expired' else 'cancelled' end,coalesce(reason,'connection_unavailable'));
  return jsonb_build_object('ready',false,'reason',coalesce(reason,'connection_unavailable'));
 end if;
 if s.state<>'active' or s.revision<>e.lease_revision or b.blocked_reason is not null then
  update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=stamp where id=e.id;
  update taskfold_private.webhook_budgets set lease_id=null,lease_until=null where subscription_id=s.id;
  return jsonb_build_object('ready',false,'reason','connection_changed');
 end if;
 if b.send_day<>(stamp at time zone 'UTC')::date then b.send_day=(stamp at time zone 'UTC')::date;b.day_sends=0;end if;
 if b.send_window<=stamp-interval '1 minute' then b.send_window=stamp;b.window_sends=0;end if;
 if e.authorized_at is null and (b.day_sends>=1000 or b.window_sends>=60) then
  defer_until=case when b.day_sends>=1000 then (date_trunc('day',stamp at time zone 'UTC') at time zone 'UTC')+interval '24 hours' else b.send_window+interval '1 minute' end;
  update taskfold_private.webhook_outbox set status='pending',lease_id=null,lease_revision=null,lease_until=null,authorized_at=null,next_attempt_at=defer_until,last_error='quota' where id=e.id;
  update taskfold_private.webhook_budgets set lease_id=null,lease_until=null,last_error='quota' where subscription_id=s.id;
  return jsonb_build_object('ready',false,'reason','quota');
 end if;
 if _authorize then
  if e.authorized_at is null then
   if e.part_attempts>=12 then perform taskfold_private.webhook_terminal(e,'failed','attempts_exhausted');return jsonb_build_object('ready',false,'reason','attempts_exhausted');end if;
   update taskfold_private.webhook_budgets set send_day=b.send_day,day_sends=b.day_sends+1,send_window=b.send_window,window_sends=b.window_sends+1 where subscription_id=s.id;
   update taskfold_private.webhook_outbox set authorized_at=stamp,part_attempts=part_attempts+1,total_attempts=total_attempts+1 where id=e.id;
  end if;
  -- The current worker has a 55 s invocation deadline and a 10 s socket
  -- deadline. This permit survives cancellation, revocation and queue pruning;
  -- adoption waits at least 60 s from the first authorization of this lease.
  perform taskfold_private.prune_webhook_write_permits();
  insert into taskfold_private.webhook_write_permits(event_id,lease_id,project_id,task_id,safe_until)
   values(e.id,_lease,e.access_project,e.task_id,stamp+interval '60 seconds') on conflict do nothing;
  return jsonb_build_object('ready',true,'lease_until',e.lease_until);
 end if;
 if e.part_count=1 then wire=e.payload;part=e.id;
 else
  hex=left(encode(extensions.digest(convert_to(e.id::text||':'||e.next_part::text,'UTF8'),'sha256'),'hex'),32);
  part=(substr(hex,1,8)||'-'||substr(hex,9,4)||'-'||substr(hex,13,4)||'-'||substr(hex,17,4)||'-'||substr(hex,21,12))::uuid;
  wire=jsonb_build_object('version',1,'type','taskfold.event.part','event_id',e.id,'part_id',part,'part_index',e.next_part,'part_count',e.part_count,'encoding','base64','sha256',e.payload_sha256,
   'data',replace(encode(substring(convert_to(e.payload,'UTF8') from e.next_part*180000+1 for 180000),'base64'),E'\n',''))::text;
 end if;
 return jsonb_build_object('ready',true,'event_id',e.id,'part_id',part,'subscription_id',s.id,'account',s.user_id,'endpoint',s.endpoint,'secret_envelope',s.secret_envelope,'body',wire,'lease_until',e.lease_until);
end$$;

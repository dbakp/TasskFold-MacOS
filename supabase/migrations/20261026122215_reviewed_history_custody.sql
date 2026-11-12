-- Review-owned history is separate from current task custody. No source event
-- or actor is rewritten, and a history binding never grants live-task access.
-- Apply transactionally in Auth -> task -> history order, matching cleanup.
-- Do not wait after taking source locks while an old adoption owns this table.
lock table taskfold_private.team_project_adoption_scope in access exclusive mode nowait;
alter table taskfold_private.team_project_adoption_scope add column history_custody_version integer not null default 0;
create function taskfold_private.guard_history_custody_scope() returns trigger
language plpgsql security invoker set search_path='' as $$begin
 if new.history_custody_version is distinct from 1 then raise exception using errcode='PT409',message='Refresh this transfer review after the history upgrade';end if;
 return new;
end$$;
create trigger history_custody_scope_version before insert or update on taskfold_private.team_project_adoption_scope
 for each row execute function taskfold_private.guard_history_custody_scope();
lock table auth.users in share row exclusive mode;
lock table public.tasks in share row exclusive mode;
lock table public.task_activity in share row exclusive mode;
lock table public.task_node_activity in share row exclusive mode;
create table taskfold_private.reviewed_history_custody (
 feed text not null check(feed in('root','child')),event_id uuid not null,
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 projects uuid[] not null check(cardinality(projects) between 1 and 1000 and array_position(projects,null) is null),
 recorded_at timestamptz not null default clock_timestamp(),
 primary key(feed,event_id,team_id)
);
create index reviewed_history_custody_team on taskfold_private.reviewed_history_custody(team_id,feed,event_id);
alter table taskfold_private.reviewed_history_custody enable row level security;
revoke all on taskfold_private.reviewed_history_custody from public,anon,authenticated,service_role;

-- UUID-only custody tombstones survive team deletion; they cannot reopen a row.
create function taskfold_private.history_is_custodied(f text,e uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.reviewed_history_custody where feed=f and event_id=e)
$$;
create function taskfold_private.history_has_live_custody(f text,e uuid,excluding_team uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.reviewed_history_custody h join taskfold_private.teams t on t.id=h.team_id
 where h.feed=f and h.event_id=e and t.state<>'deleted' and (excluding_team is null or h.team_id<>excluding_team))
$$;
create function taskfold_private.history_root_has_live_custody(t uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from taskfold_private.team_content_tasks c join taskfold_private.teams x on x.id=c.team_id where c.task_id=t and x.state<>'deleted')
$$;
create function taskfold_private.history_has_personal_context(b jsonb,a jsonb,owner_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=owner_id) and exists(
  select 1 from jsonb_array_elements(jsonb_build_array(b,a)) v(s) where s<>'{}'::jsonb and s ? 'project_id' and
   (s->'project_id'='null'::jsonb or exists(select 1 from public.projects p where p.user_id=owner_id
    and p.id::text=s->>'project_id' and not exists(select 1 from taskfold_private.team_project_identities t where t.project_id=p.id))))
$$;
create function taskfold_private.history_state_read(s jsonb,owner_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select s='{}'::jsonb or case when s->'project_id'='null'::jsonb then auth.uid()=owner_id
  when s->>'project_id' ~* '^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$' then
   case when exists(select 1 from taskfold_private.team_project_identities t where t.project_id=(s->>'project_id')::uuid)
    then taskfold_private.team_native_project_read((s->>'project_id')::uuid)
    else public.has_project_access(auth.uid(),(s->>'project_id')::uuid) end
  else false end
$$;
create function taskfold_private.history_native_read(f text,e uuid,b jsonb,a jsonb,owner_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select taskfold_private.team_native_actor_live() and taskfold_private.history_state_read(b,owner_id) and taskfold_private.history_state_read(a,owner_id)
 and ((auth.uid()=owner_id and taskfold_private.history_has_personal_context(b,a,owner_id)) or exists(select 1 from taskfold_private.reviewed_history_custody h join taskfold_private.teams t on t.id=h.team_id
  cross join lateral unnest(h.projects) p where h.feed=f and h.event_id=e and t.state='active'
  and taskfold_private.team_native_project_read(p)))
$$;

-- Callable only inside the exact, fresh adoption scope established by commit.
create function taskfold_private.register_reviewed_history_custody(team uuid,ids uuid[]) returns void
language plpgsql volatile security invoker set search_path='' as $$
declare rel text;f text;begin
 if ids is null or cardinality(ids) not between 1 and 1000 or exists(select 1 from unnest(ids) p where not exists(
  select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=p)) then
  raise exception using errcode='42501',message='Reviewed history requires the current transfer scope';end if;
 for rel,f in values('task_activity','root'),('task_node_activity','child') loop
  execute format('insert into taskfold_private.reviewed_history_custody(feed,event_id,team_id,projects)
   select $3,x.id,$2,array(select p.id from public.projects p where p.id=any($1) and
    (p.id in(select t.project_id from public.tasks t where t.id=x.task_id) or x.before_state->>''project_id''=p.id::text or x.after_state->>''project_id''=p.id::text) order by p.id)
   from public.%I x where exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1)) or x.before_state->>''project_id''=any($1::text[]) or x.after_state->>''project_id''=any($1::text[])
   on conflict(feed,event_id,team_id) do update set projects=array(select distinct p from unnest(reviewed_history_custody.projects||excluded.projects) p order by p)',rel) using ids,team,f;
 end loop;
end$$;


create or replace function taskfold_private.project_adoption_contents(ids uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare custody_rows jsonb; custody_count bigint; custody_bytes bigint; item record; hashes jsonb:='{}'; counts jsonb:='{}'; rows jsonb; n bigint; bytes bigint; total bigint:=0; entries bigint:=0;
 attachments bigint; inline_files bigint; external_files bigint; unknown_files bigint; email_rows jsonb:='[]'; hooks jsonb:='[]';queue_rows jsonb:='[]';queued bigint;inflight bigint;effects jsonb;begin
 for item in select * from(values
  ('projects','x.id=any($1)','to_jsonb(x)'),
  ('tasks','x.project_id=any($1)','to_jsonb(x)'),
  ('sections','x.project_id=any($1)','to_jsonb(x)'),
  ('project_collaborators','x.project_id=any($1)','to_jsonb(x)'),
  ('task_comments','x.project_id=any($1)','to_jsonb(x)'),
  ('task_mentions','exists(select 1 from public.task_comments c where c.id=x.comment_id and c.project_id=any($1))','to_jsonb(x)-array[''read_at'',''revision'']'),
  ('task_assignment_provenance','exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1))','to_jsonb(x)'),
  ('task_activity','exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1)) or x.before_state->>''project_id''=any($1::text[]) or x.after_state->>''project_id''=any($1::text[])','to_jsonb(x)'),
  ('task_node_activity','exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any($1)) or x.before_state->>''project_id''=any($1::text[]) or x.after_state->>''project_id''=any($1::text[])','to_jsonb(x)')
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
 effects=taskfold_private.project_adoption_connection_effects(ids);
 if (effects->>'queued_updates_discarded')::bigint<>queued then raise exception using errcode='PT409',message='The outgoing queue changed; review again';end if;
 select count(*),coalesce(sum(octet_length(to_jsonb(h)::text)),0) into custody_count,custody_bytes from taskfold_private.reviewed_history_custody h where (h.feed='root' and exists(select 1 from public.task_activity x where x.id=h.event_id and (exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any(ids)) or x.before_state->>'project_id'=any(ids::text[]) or x.after_state->>'project_id'=any(ids::text[])))) or (h.feed='child' and exists(select 1 from public.task_node_activity x where x.id=h.event_id and (exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any(ids)) or x.before_state->>'project_id'=any(ids::text[]) or x.after_state->>'project_id'=any(ids::text[]))));
 if custody_count>100000 or total+custody_bytes>33554432 then raise exception using errcode='54000',message='These projects have too much shared history to review together';end if;
 select coalesce(jsonb_agg(to_jsonb(h) order by h.feed,h.event_id,h.team_id),'[]') into custody_rows from taskfold_private.reviewed_history_custody h where (h.feed='root' and exists(select 1 from public.task_activity x where x.id=h.event_id and (exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any(ids)) or x.before_state->>'project_id'=any(ids::text[]) or x.after_state->>'project_id'=any(ids::text[])))) or (h.feed='child' and exists(select 1 from public.task_node_activity x where x.id=h.event_id and (exists(select 1 from public.tasks t where t.id=x.task_id and t.project_id=any(ids)) or x.before_state->>'project_id'=any(ids::text[]) or x.after_state->>'project_id'=any(ids::text[]))));
 total=total+custody_bytes;
 hashes=hashes||jsonb_build_object('reviewed_history_custody',encode(extensions.digest(convert_to(custody_rows::text,'UTF8'),'sha256'),'hex'));
 return jsonb_build_object('hashes',hashes,'counts',counts,'content_bytes',total,'attachments',attachments,'inline_files',inline_files,
  'external_files',external_files,'provider_files',unknown_files,'email_routes',jsonb_array_length(email_rows),'webhooks',jsonb_array_length(hooks),'queued_webhook_events',queued,'inflight_webhook_events',inflight,'project_webhooks',(effects->>'project_webhooks_paused')::bigint+(effects->>'pending_webhooks_cancelled')::bigint,'pending_project_webhooks',(effects->>'pending_webhooks_cancelled')::bigint,'global_webhooks',(effects->>'global_webhooks_excluded')::bigint);
end$$;

create or replace function taskfold_private.project_adoption_review(operation text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid(); team uuid;roots uuid[];ids uuid[];person uuid;parent uuid;folder uuid;visibility text;
 forest jsonb;fresh jsonb;contents jsonb;people uuid[];ancestry jsonb;team_row taskfold_private.teams;epoch bigint;
 members jsonb;collaborators jsonb;decisions jsonb:='[]';item jsonb;result jsonb;snapshot text;token text;expires text;
 proof jsonb;project_rows jsonb;effects jsonb;policy text;cleared bigint:=0;assignees jsonb;entry record;role text;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception using errcode='25000',message='Use a fresh read-committed transaction for this project transfer';end if;
 perform taskfold_private.team_actor();
 if operation='inspect' then perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id']);
 elsif operation='review' then perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id','inspection_token','decisions']||case when b ? 'connection_policy' then array['connection_policy'] else '{}'::text[] end);
 else raise exception using errcode='22023',message='Choose a supported project transfer review';end if;
 if octet_length(b::text)>262144 then raise exception using errcode='54000',message='This transfer review is too large';end if;
 if b ? 'connection_policy' then
  if jsonb_typeof(b->'connection_policy') is distinct from 'string' or b->>'connection_policy'<>'pause' then raise exception using errcode='22023',message='Choose a supported personal connection action';end if;
  policy=b->>'connection_policy';
 end if;
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
  perform 1 from public.task_node_activity where task_id in(select id from public.tasks where project_id=any(ids)) or before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) order by id for no key update nowait;
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
 result=jsonb_build_object('history_custody_protocol',1,'child_history_protocol',1,'project_adoption_protocol',1,'account',a,'team_id',team,'roots',roots,'visibility',visibility,'folder_id',folder,'parent_id',parent,
  'projects',project_rows,'contents',contents-'hashes','collaborators',collaborators,'inspection_token',snapshot,
  'destination_archived',ancestry->'archived','team_name',team_row.name,'creates_memberships',false,'sends_invitations',false,'automatic_undo',false,
  'commit_supported',coalesce((select native_project_adoption_enabled from taskfold_private.team_project_config where singleton),false) and (contents->>'inflight_webhook_events')::bigint=0 and (contents->>'provider_files')::bigint=0 and (contents->>'email_routes')::integer=0 and (contents->>'webhooks')::integer=0,'team_member_count',jsonb_array_length(members));
 result=result||jsonb_build_object('connection_pause_protocol',1,'connection_pause_supported',
  coalesce((select native_project_adoption_enabled from taskfold_private.team_project_config where singleton),false)
  and (contents->>'provider_files')::bigint=0 and (contents->>'inflight_webhook_events')::bigint=0
  and ((contents->>'email_routes')::bigint+(contents->>'webhooks')::bigint+(contents->>'queued_webhook_events')::bigint)>0);
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
 if policy='pause' then
  effects=taskfold_private.project_adoption_connection_effects(ids);
  select encode(extensions.hmac(convert_to(jsonb_build_array(2,a,snapshot,decisions,policy,effects,expires)::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 else
 select encode(extensions.hmac(convert_to(jsonb_build_array(1,a,snapshot,decisions,expires)::text,'UTF8'),s.secret,'sha256'),'hex') into token from taskfold_private.automation_revision_secret s where singleton;
 end if;
 return result||jsonb_build_object('decisions',assignees,'assignments_cleared',cleared,'invitations_closed',jsonb_array_length(collaborators),
  'review_token',token,'expires_at',expires,'requires_provider_custody',(contents->>'provider_files')::bigint>0,
  'requires_integration_pause',policy is null and ((contents->>'email_routes')::bigint+(contents->>'webhooks')::bigint+(contents->>'queued_webhook_events')::bigint)>0,'connection_policy',policy,'connection_effects',effects);
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
 perform taskfold_private.project_adoption_fields(b,array['team_id','roots','visibility','folder_id','parent_id','inspection_token','decisions','review_token','expires_at','request_id']||case when b ? 'connection_policy' then array['connection_policy'] else '{}'::text[] end);
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
 if b->>'connection_policy'='pause' then
  select encode(extensions.hmac(convert_to(jsonb_build_array(2,a,preview->>'inspection_token',decisions,'pause',preview->'connection_effects',b->>'expires_at')::text,'UTF8'),s.secret,'sha256'),'hex') into proof from taskfold_private.automation_revision_secret s where singleton;
 else
 select encode(extensions.hmac(convert_to(jsonb_build_array(1,a,preview->>'inspection_token',decisions,b->>'expires_at')::text,'UTF8'),s.secret,'sha256'),'hex') into proof from taskfold_private.automation_revision_secret s where singleton;
 end if;
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
 insert into taskfold_private.team_project_adoption_scope(transaction_id,actor_id,team_id,project_id,root_id,parent_id,visibility,folder_id,history_custody_version)
 select txid_current(),a,team,(v->>'id')::uuid,(v->>'root_id')::uuid,(v->>'parent_id')::uuid,visibility,folder,1 from jsonb_array_elements(preview->'projects') v;
 perform taskfold_private.register_reviewed_history_custody(team,ids);
 if b->>'connection_policy'='pause' then perform taskfold_private.project_adoption_pause_connections(ids,preview->'connection_effects');end if;
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
 insert into taskfold_private.project_adoption_receipts(team_id,request_id,actor_id,fingerprint,project_ids,root_ids,parent_id,folder_id,visibility,assignments_cleared,invitations_closed,connection_policy,connection_effects)
 values(team,q,a,fingerprint,ids,roots,parent,folder,cmd.visibility,cleared,(preview->>'invitations_closed')::integer,b->>'connection_policy',case when b->>'connection_policy'='pause' then preview->'connection_effects' end) returning * into prior;
 delete from taskfold_private.team_project_hierarchy_operations where transaction_id=txid_current() and project_id=any(ids);
 delete from taskfold_private.team_project_adoption_scope where transaction_id=txid_current() and project_id=any(ids);
 return taskfold_private.project_adoption_receipt_reply(prior,false);
end$$;

create or replace function taskfold_private.remove_content_identity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from taskfold_private.teams where owner_id=old.id and state<>'deleted') then
  raise exception using errcode='PT409',message='Transfer or delete owned teams before removing your account';end if;
 -- Detach every surviving series child from a root that will actually disappear.
 update public.tasks child set recurrence_parent_id=null
 where child.recurrence_parent_id in(select root.id from public.tasks root where root.user_id=old.id
  and not taskfold_private.is_team_content_task(root.id))
 and (child.user_id<>old.id or taskfold_private.is_team_content_task(child.id));
 delete from public.tasks where user_id=old.id and not taskfold_private.is_team_content_task(id);
 delete from public.sections where user_id=old.id and not taskfold_private.is_team_content_project(project_id);
 delete from public.projects where user_id=old.id and not taskfold_private.is_team_content_project(id);
 delete from public.task_activity where user_id=old.id and not taskfold_private.history_root_has_live_custody(task_id) and not taskfold_private.history_has_live_custody('root',id,null);
 delete from public.task_node_activity where user_id=old.id and not taskfold_private.history_root_has_live_custody(task_id) and not taskfold_private.history_has_live_custody('child',id,null);
 delete from taskfold_private.task_generations where user_id=old.id and not taskfold_private.is_team_content_task(task_id);
 update taskfold_private.content_identities set removed_at=clock_timestamp() where id=old.id;
 return old;
end$$;

create or replace function taskfold_private.delete_team_content() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if new.state='deleted' and old.state<>'deleted' then
  delete from taskfold_private.team_content_file_removals r where r.team_id=old.id and not exists(select 1 from storage.objects where id=r.object_id);
  if exists(select 1 from taskfold_private.team_content_files f join taskfold_private.team_content_projects p on p.project_id=f.project_id where p.team_id=old.id) or exists(select 1 from taskfold_private.team_content_file_removals where team_id=old.id) then
   raise exception using errcode='PT409',message='Remove team files before deleting this team';end if;
  -- Drain concurrent reviewed transfers without waiting on an older snapshot.
  begin
   perform 1 from public.task_activity x where x.task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id) or exists(select 1 from taskfold_private.reviewed_history_custody h where h.feed='root' and h.event_id=x.id and h.team_id=old.id) order by x.id for no key update nowait;
   perform 1 from public.task_node_activity x where x.task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id) or exists(select 1 from taskfold_private.reviewed_history_custody h where h.feed='child' and h.event_id=x.id and h.team_id=old.id) order by x.id for no key update nowait;
  exception when lock_not_available then raise exception using errcode='PT409',message='A history transfer is still finishing; retry team deletion';end;
  insert into taskfold_private.team_content_operations values(txid_current(),old.id);
  update public.tasks child set recurrence_parent_id=null where child.recurrence_parent_id in(
   select t.id from public.tasks t join taskfold_private.team_content_tasks c on c.task_id=t.id where c.team_id=old.id)
   and not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=child.id and c.team_id=old.id);
  delete from public.tasks where id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id);
  delete from public.projects where id in(select project_id from taskfold_private.team_content_projects where team_id=old.id);
  delete from public.task_activity where (task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id) or exists(select 1 from taskfold_private.reviewed_history_custody h where h.feed='root' and h.event_id=task_activity.id and h.team_id=old.id)) and not taskfold_private.history_has_live_custody('root',id,old.id) and not taskfold_private.history_has_personal_context(before_state,after_state,user_id);
  delete from public.task_node_activity where (task_id in(select task_id from taskfold_private.team_content_tasks where team_id=old.id) or exists(select 1 from taskfold_private.reviewed_history_custody h where h.feed='child' and h.event_id=task_node_activity.id and h.team_id=old.id)) and not taskfold_private.history_has_live_custody('child',id,old.id) and not taskfold_private.history_has_personal_context(before_state,after_state,user_id);
  delete from taskfold_private.team_content_operations where transaction_id=txid_current() and team_id=old.id;
  -- Generation/custody tombstones contain UUIDs only and continue preventing replay.
 end if;
 return new;
end$$;

alter policy task_activity_read on public.task_activity
 using(taskfold_private.history_is_custodied('root',id) or taskfold_private.is_team_content_task(task_id) or taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));
alter policy team_activity_native_read on public.task_activity
 using(case when taskfold_private.history_is_custodied('root',id) then taskfold_private.history_native_read('root',id,before_state,after_state,user_id)
 else not taskfold_private.is_team_content_task(task_id) or (taskfold_private.team_native_activity_read(task_id) and taskfold_private.team_native_activity_states_read(before_state,after_state)) end);

alter policy task_node_activity_read on public.task_node_activity
 using(taskfold_private.history_is_custodied('child',id) or taskfold_private.is_team_content_task(task_id) or taskfold_private.can_read_task_activity(user_id,task_id,before_state,after_state));
alter policy team_node_activity_native_read on public.task_node_activity
 using(case when taskfold_private.history_is_custodied('child',id) then taskfold_private.history_native_read('child',id,before_state,after_state,user_id)
 else not taskfold_private.is_team_content_task(task_id) or (taskfold_private.team_native_activity_read(task_id) and taskfold_private.team_native_activity_states_read(before_state,after_state)) end);

-- Preserve existing review/commit ACLs used by the public invoker wrapper.
revoke all on function taskfold_private.guard_history_custody_scope(),taskfold_private.history_root_has_live_custody(uuid),taskfold_private.history_has_personal_context(jsonb,jsonb,uuid),taskfold_private.history_state_read(jsonb,uuid),taskfold_private.history_is_custodied(text,uuid),taskfold_private.history_has_live_custody(text,uuid,uuid),
 taskfold_private.history_native_read(text,uuid,jsonb,jsonb,uuid),taskfold_private.register_reviewed_history_custody(uuid,uuid[])
 from public,anon,authenticated,service_role;
grant execute on function taskfold_private.history_is_custodied(text,uuid),taskfold_private.history_native_read(text,uuid,jsonb,jsonb,uuid) to authenticated;


-- Earlier observed rows stay intact; prior author cleanup may already have lost
-- unbound history. Do not certify a pre-upgrade interval or invent a backfill.
update public.task_activity_epoch set recorded_from=greatest(recorded_from,clock_timestamp()) where id='current';
update public.task_node_activity_epoch set recorded_from=greatest(recorded_from,clock_timestamp()) where id='current';

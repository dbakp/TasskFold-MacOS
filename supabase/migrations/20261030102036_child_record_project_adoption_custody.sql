-- Reviewed personal-project adoption with independent child records. No rollout
-- gates change. Private deletion copies never become team content or restorable
-- in the new realm. Current record identities are renewed to fence queued edits.
alter table taskfold_private.team_project_adoption_scope add column child_custody_version integer not null default 0;
alter table taskfold_private.team_project_adoption_scope add column child_custody_ready boolean not null default false;
alter table taskfold_private.child_task_structure_archives add column restore_blocked boolean not null default false;

create function taskfold_private.lock_child_adoption_custody(ids uuid[]) returns void
language plpgsql security invoker set search_path='' as $$begin
 -- Caller already owns all source root locks. Never wait behind archive disposal
 -- or a private writer in the opposite order; a fresh review can retry safely.
 begin
  perform 1 from taskfold_private.child_task_projections where task_id in(select id from public.tasks where project_id=any(ids)) order by task_id for update nowait;
  perform 1 from taskfold_private.child_task_record_authority where task_id in(select id from public.tasks where project_id=any(ids)) order by task_id for update nowait;
  perform 1 from taskfold_private.child_task_records where task_id in(select id from public.tasks where project_id=any(ids)) order by task_id,node_key for update nowait;
  perform 1 from taskfold_private.child_task_structure_archives where task_id in(select id from public.tasks where project_id=any(ids)) order by actor_id,request_id for update nowait;
 exception when lock_not_available then raise exception using errcode='PT409',message='A subtask edit or saved-copy decision is finishing; review again';end;
end$$;

create function taskfold_private.finish_child_adoption_custody(team uuid,ids uuid[]) returns void
language plpgsql security invoker set search_path='' as $$
declare t public.tasks;p taskfold_private.child_task_projections;a taskfold_private.child_task_record_authority;begin
 if cardinality(ids) not between 1 and 1000 or exists(select 1 from unnest(ids) id where not exists(
  select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.team_id=team and s.project_id=id and s.child_custody_version=1 and not s.child_custody_ready)) then
  raise exception using errcode='42501',message='Subtask custody requires the reviewed project transfer';end if;
 for t in select * from public.tasks where project_id=any(ids) order by id for update loop
  select * into p from taskfold_private.child_task_projections where task_id=t.id;
  if not found then continue;end if;
  if p.state<>'ready' or p.task_generation is distinct from t.task_generation or p.source_tree is distinct from coalesce(t.subtasks,'null'::jsonb)
   or p.revision>=9007199254740991 or p.structure_revision>=9007199254740991 then
   raise exception using errcode='PT409',message='Review this subtask hierarchy before transferring';end if;
  if taskfold_private.materialize_child_task_records(t.id,case when coalesce(t.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end) is distinct from coalesce(t.subtasks,'null'::jsonb) then
   raise exception using errcode='PT409',message='Review this subtask projection before transferring';end if;
  select * into a from taskfold_private.child_task_record_authority where task_id=t.id;
  if found and (a.task_generation is distinct from t.task_generation or a.project_id is distinct from t.project_id or taskfold_private.materialize_child_task_records(t.id,a.root_kind) is distinct from coalesce(t.subtasks,'null'::jsonb)) then
   raise exception using errcode='PT409',message='Review this separate subtask hierarchy before transferring';end if;
  -- Preserve all fields/order/raw IDs and completion metadata. New incarnations
  -- fence unconfirmed field/completion requests; topology revision fences old
  -- insert/move/delete and Undo requests despite an unchanged project UUID.
  update taskfold_private.child_task_records set incarnation=gen_random_uuid() where task_id=t.id;
  update taskfold_private.child_task_projections set revision=revision+1,structure_revision=structure_revision+1 where task_id=t.id;
 end loop;
 update taskfold_private.child_task_structure_archives set restore_blocked=true where task_id in(select id from public.tasks where project_id=any(ids));
 update taskfold_private.team_project_adoption_scope set child_custody_ready=true where transaction_id=txid_current() and actor_id=auth.uid() and team_id=team and project_id=any(ids);
end$$;

create or replace function taskfold_private.guard_child_record_project_transfer() returns trigger
language plpgsql security definer set search_path='' as $$begin
 if tg_op='UPDATE' and new.team_id is not distinct from old.team_id then return new;end if;
 if exists(select 1 from taskfold_private.child_task_projections a join public.tasks t on t.id=a.task_id where t.project_id=new.project_id)
  or exists(select 1 from taskfold_private.child_task_structure_archives a join public.tasks t on t.id=a.task_id where t.project_id=new.project_id) then
  if tg_op<>'INSERT' or not exists(select 1 from taskfold_private.team_project_adoption_scope s where s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.project_id=new.project_id and s.team_id=new.team_id and s.child_custody_version=1 and s.child_custody_ready) then
   raise exception using errcode='PT409',message='Review subtask custody before transferring this project';end if;
 end if;return new;
end$$;
revoke all on function taskfold_private.lock_child_adoption_custody(uuid[]),taskfold_private.finish_child_adoption_custody(uuid,uuid[]) from public,anon,authenticated,service_role;

create or replace function taskfold_private.advance_child_task_structure() returns trigger
language plpgsql security invoker set search_path='' as $$
declare before_shape jsonb;after_shape jsonb;
begin
 -- Root lock precedes projection lock in the existing bridge. This trigger
 -- participates in that transaction, including rollback and concurrent edits.
 new.structure_revision:=old.structure_revision;
 if new.source_tree is not distinct from old.source_tree and new.task_generation is not distinct from old.task_generation
  and new.revision=old.revision+1 and exists(select 1 from public.tasks t join taskfold_private.team_project_adoption_scope s on s.project_id=t.project_id
   where t.id=new.task_id and s.transaction_id=txid_current() and s.actor_id=auth.uid() and s.child_custody_version=1 and not s.child_custody_ready) then
  new.structure_revision:=old.structure_revision+1;
 elsif new.task_generation is distinct from old.task_generation or new.state<>'ready' or old.state<>'ready' then
  new.structure_revision:=old.structure_revision+1;
 elsif new.source_tree is distinct from old.source_tree then
  before_shape:=taskfold_private.child_task_topology(old.source_tree);
  after_shape:=taskfold_private.child_task_topology(new.source_tree);
  if before_shape is null or after_shape is null or before_shape is distinct from after_shape then
   new.structure_revision:=old.structure_revision+1;
  end if;
 end if;
 return new;
end $$;

create or replace function taskfold_private.project_adoption_contents(ids uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare child_rows jsonb;child_bytes bigint;child_count bigint;child_hashes jsonb;child_item record;own_archives bigint;custody_rows jsonb; custody_count bigint; custody_bytes bigint; item record; hashes jsonb:='{}'; counts jsonb:='{}'; rows jsonb; n bigint; bytes bigint; total bigint:=0; entries bigint:=0;
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
 -- Signed, bounded digests include actual child rows, their authority and
 -- private archive content. No private subtree, actor identity or other actor's
 -- archive count is returned to the review client.
 child_hashes:='{}';child_bytes:=0;
 for child_item in select * from(values('child_task_projections'),('child_task_record_authority'),('child_task_records'),('child_task_structure_archives')) x(rel) loop
  execute format('select count(*),coalesce(sum(octet_length(to_jsonb(x)::text)),0) from taskfold_private.%I x where task_id in(select id from public.tasks where project_id=any($1))',child_item.rel) into child_count,bytes using ids;
  child_bytes:=child_bytes+bytes;
  if child_count>100000 or child_bytes+total>33554432 then raise exception using errcode='54000',message='These subtasks and saved copies are too large to review together';end if;
  execute format('select coalesce(jsonb_agg(encode(extensions.digest(convert_to(to_jsonb(x)::text,''UTF8''),''sha256''),''hex'') order by to_jsonb(x)::text),''[]'') from taskfold_private.%I x where task_id in(select id from public.tasks where project_id=any($1))',child_item.rel) into child_rows using ids;
  child_hashes:=child_hashes||jsonb_build_object(child_item.rel,encode(extensions.digest(convert_to(child_rows::text,'UTF8'),'sha256'),'hex'));
 end loop;
 hashes:=hashes||jsonb_build_object('child_record_custody_v1',child_hashes);
 select count(*) into own_archives from taskfold_private.child_task_structure_archives where actor_id=auth.uid() and task_id in(select id from public.tasks where project_id=any(ids));
 return jsonb_build_object('hashes',hashes,'counts',counts,'child_record_custody_protocol',1,'subtask_undo_policy','kept_private_no_restore','private_subtask_undo_count',own_archives,'content_bytes',total,'attachments',attachments,'inline_files',inline_files,
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
 perform taskfold_private.lock_child_adoption_custody(ids);
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
 result=jsonb_build_object('child_record_custody_protocol',1,'history_custody_protocol',1,'child_history_protocol',1,'project_adoption_protocol',1,'account',a,'team_id',team,'roots',roots,'visibility',visibility,'folder_id',folder,'parent_id',parent,
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
 insert into taskfold_private.team_project_adoption_scope(transaction_id,actor_id,team_id,project_id,root_id,parent_id,visibility,folder_id,history_custody_version,child_custody_version)
 select txid_current(),a,team,(v->>'id')::uuid,(v->>'root_id')::uuid,(v->>'parent_id')::uuid,visibility,folder,1,1 from jsonb_array_elements(preview->'projects') v;
 perform taskfold_private.register_reviewed_history_custody(team,ids);
 if b->>'connection_policy'='pause' then perform taskfold_private.project_adoption_pause_connections(ids,preview->'connection_effects');end if;
 -- Clear only reviewed ineligible assignees while these are still personal
 -- rows and all reviewed memberships still exist. The provenance trigger keeps
 -- every unchanged eligible assignment's original event/actor/date byte-exact.
 for t in select * from public.tasks where project_id=any(ids) order by id loop
  desired=t.subtasks;recipient=t.assigned_to;
  if recipient is not null and coalesce(taskfold_private.project_adoption_role(recipient,t.project_id,team,visibility,decisions),'') not in('manager','editor') then recipient=null;cleared=cleared+1;end if;
  for item in select distinct (n.value->>'assignee')::uuid person from jsonb_each(taskfold_private.assignment_nodes(t.subtasks)) n where n.value->>'assignee' is not null loop
   role=taskfold_private.project_adoption_role(item.person,t.project_id,team,visibility,decisions);
   if coalesce(role,'') not in('manager','editor') then
    cleared=cleared+(select count(*) from jsonb_each(taskfold_private.assignment_nodes(desired)) n where n.value->>'assignee'=item.person::text);
    desired=taskfold_private.project_adoption_clear_assignee(desired,item.person);
   end if;
  end loop;
  if recipient is distinct from t.assigned_to or desired is distinct from t.subtasks then
   desired:=taskfold_private.prepare_child_record_tree(t.id,t.task_generation,desired);
   update public.tasks set assigned_to=recipient,subtasks=desired where id=t.id;end if;
 end loop;
 if cleared<>(preview->>'assignments_cleared')::integer then raise exception using errcode='PT409',message='The reviewed assignment changes no longer match';end if;
 perform taskfold_private.finish_child_adoption_custody(team,ids);
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

create or replace function taskfold_private.edit_child_structure(b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
<<op>>
declare a uuid:=auth.uid();id uuid;q uuid;g uuid;p uuid;team uuid;initial public.tasks;t public.tasks;
 projection taskfold_private.child_task_projections;n taskfold_private.child_task_records;destination taskfold_private.child_task_records;
 prior taskfold_private.child_task_structure_receipts;original taskfold_private.child_task_structure_receipts;
 key text;parent text;mode text;undo_id uuid;fingerprint text;rev bigint;slot integer;container_kind text;
 decoded jsonb;extra_decoded jsonb;extra_tree jsonb:='[]';subtree jsonb;desired jsonb;inverse jsonb:='{}';
 recipients uuid[];current_recipients uuid[];replaying boolean;archive_size bigint;archive_count bigint;
begin
 perform 1 from taskfold_private.child_task_record_config where singleton and reads_enabled and edits_enabled and completions_enabled and structure_reads_enabled and structure_edits_enabled for share;
 if not found then raise exception using errcode='PT503',message='Separate child structure editing is not enabled';end if;
 perform taskfold_private.team_actor();perform pg_advisory_xact_lock(hashtextextended(a::text,73918));perform taskfold_private.team_actor();
 perform taskfold_private.validate_child_structure_request(b,a);
 id:=taskfold_private.team_uuid(b,'task_id');q:=taskfold_private.team_uuid(b,'request_id');
 g:=case when b->'task_generation'='null'::jsonb then null else taskfold_private.team_uuid(b,'task_generation') end;
 p:=case when b->'project_id'='null'::jsonb then null else taskfold_private.team_uuid(b,'project_id') end;
 mode:=b->>'action';rev:=(b->>'structure_revision')::bigint;key:=b->>'node_key';parent:=b->>'parent_key';slot:=(b->>'index')::integer;
 fingerprint:=encode(extensions.digest(convert_to(b::text,'UTF8'),'sha256'),'hex');
 if not pg_try_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73919)) then raise exception using errcode='55P03',message='Another request decision is finishing; retry the same action';end if;
 if exists(select 1 from taskfold_private.child_task_structure_closures where actor_id=a and request_id=q) then raise exception using errcode='PT410',message='This original structure action is closed';end if;
 if exists(select 1 from taskfold_private.child_task_edit_preparations where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_edit_closures where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_receipts where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.child_task_completion_closures where actor_id=a and request_id=q) then raise exception using errcode='PT409',message='This request identity belongs to another child action';end if;
 select * into prior from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=q;
 replaying:=found;
 if replaying and prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='This structure identity was already used';end if;
 if not replaying then
  if mode='insert' then
   extra_decoded:=taskfold_private.decode_child_task_tree(jsonb_build_array(b->'node'));
   if extra_decoded->>'state'<>'ready' then raise exception using errcode='22023',message='Review the new child hierarchy';end if;
   subtree:=taskfold_private.child_structure_fresh_node(b->'node',false);extra_tree:=jsonb_build_array(subtree);key:=normalize(subtree->>'id',NFC);
  elsif mode='undo' then
   undo_id:=taskfold_private.team_uuid(b,'undo_of');
   select * into original from taskfold_private.child_task_structure_receipts where actor_id=a and request_id=undo_id;
   if not found or original.action='undo' or original.reversed_by is not null or original.task_id<>id or original.generation is distinct from g or original.project_id is distinct from p then raise exception using errcode='PT409',message='This structure action can no longer be undone';end if;
   key:=original.node_key;
   if original.action='delete' then
    select ar.subtree into subtree from taskfold_private.child_task_structure_archives ar where actor_id=a and request_id=undo_id and task_id=id and not restore_blocked;
    if not found then raise exception using errcode='PT409',message='The saved subtree is no longer available for Undo';end if;
    extra_tree:=jsonb_build_array(subtree);
   end if;
  end if;
 end if;
 select * into initial from public.tasks where tasks.id=op.id;
 if not found or initial.task_generation is distinct from g or initial.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 if octet_length(coalesce(initial.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 decoded:=taskfold_private.decode_child_task_tree(initial.subtasks);extra_decoded:=taskfold_private.decode_child_task_tree(extra_tree);
 if decoded->>'state'<>'ready' or extra_decoded->>'state'<>'ready' then raise exception using errcode='PT409',message='Review this child hierarchy';end if;
 -- Lock all existing/new/restored recipients before team/project/root locks.
 select array_agg(distinct recipient order by recipient) into recipients from (
  select initial.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements((decoded->'nodes')||(extra_decoded->'nodes')) x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 perform 1 from auth.users where users.id=any(coalesce(recipients,'{}')) order by users.id for share;
 select team_id into team from taskfold_private.team_content_projects where project_id=p;
 if team is not null then
  perform 1 from taskfold_private.teams where teams.id=team and state='active' for share;
  if not found or coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access is required';end if;
  perform 1 from taskfold_private.team_project_config where singleton and native_reads_enabled and native_task_edits_enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is not enabled';end if;
  if not replaying and exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x where x->'fields'->'is_heading'='true'::jsonb) then
   perform 1 from taskfold_private.team_project_config where singleton and native_task_types_enabled for share;
   if not found then raise exception using errcode='PT503',message='Shared task types are not enabled';end if;
  end if;
  perform 1 from taskfold_private.team_config where singleton and enabled for share;
  if not found then raise exception using errcode='PT503',message='Team editing is paused';end if;
  perform 1 from taskfold_private.team_content_projects where project_id=p and team_id=team for share;
 elsif taskfold_private.is_team_content_task(id) then raise exception using errcode='42501',message='This task is unavailable';
 elsif p is null then
  if initial.user_id<>a then raise exception using errcode='42501',message='This task is unavailable';end if;
 elsif not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='This task is unavailable';end if;
 if p is not null then
  perform 1 from public.projects where projects.id=p and not is_archived and not ancestor_archived for share;
  if not found then raise exception using errcode='PT409',message='This project is archived or unavailable';end if;
 end if;
 perform pg_advisory_xact_lock(hashtextextended(a::text||':'||q::text,73917));
 if team is not null then perform pg_advisory_xact_lock(hashtextextended(team::text||':'||q::text,79241));end if;
 if (exists(select 1 from taskfold_private.team_task_edits where actor_id=a and request_id=q)
  or exists(select 1 from taskfold_private.team_task_batches where actor_id=a and request_id=q)
  or (team is not null and (exists(select 1 from taskfold_private.team_task_edits where team_id=team and request_id=q) or exists(select 1 from taskfold_private.team_task_batches where team_id=team and request_id=q)))) and not replaying then raise exception using errcode='PT409',message='This action identity was already used';end if;
 select * into t from public.tasks where tasks.id=op.id for update;
 if not found or t.task_generation is distinct from g or t.project_id is distinct from p then raise exception using errcode='PT409',message='This task or project changed';end if;
 perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 if replaying then return taskfold_private.child_structure_receipt(prior,true);end if;
 if octet_length(coalesce(t.subtasks,'null'::jsonb)::text)>2000000 then raise exception using errcode='54000',message='This hierarchy is too large for structure editing';end if;
 -- Verify stored records against the actual tree, not just a saved source hash.
 perform taskfold_private.read_child_task_records(id,g);
 select * into projection from taskfold_private.child_task_projections where task_id=id;
 if projection.structure_revision<>rev or projection.structure_revision>=9007199254740991 or projection.revision>=9007199254740991 then raise exception using errcode='PT409',message='The hierarchy changed; review this structure action';end if;
 decoded:=taskfold_private.decode_child_task_tree(t.subtasks);
 select array_agg(distinct recipient order by recipient) into current_recipients from (
  select t.assigned_to recipient union select (x->'fields'->>'assigned_to')::uuid from jsonb_array_elements(decoded->'nodes') x where coalesce(x->'fields'->>'assigned_to','')<>'') y where recipient is not null;
 if not coalesce(current_recipients,'{}')<@coalesce(recipients,'{}') then raise exception using errcode='PT409',message='Assignments changed; review this structure action';end if;
 if mode in('move','delete') or (mode='undo' and original.action in('move','insert')) then
  select * into n from taskfold_private.child_task_records where task_id=id and node_key=key;
  if not found or n.incarnation is distinct from (case when mode='undo' then original.incarnation else taskfold_private.team_uuid(b,'incarnation') end) then raise exception using errcode='PT409',message='This child changed or was recreated';end if;
  subtree:=taskfold_private.child_structure_extract(t.subtasks,key);
  if subtree is null then raise exception using errcode='PT409',message='This child is unavailable';end if;
 end if;
 if mode in('insert','move') then
  if parent is null then container_kind:=case when coalesce(t.subtasks,'null'::jsonb)='null'::jsonb then 'null' else 'array' end;
  else
   select * into destination from taskfold_private.child_task_records where task_id=id and node_key=parent;
   if not found then raise exception using errcode='PT409',message='The destination is unavailable';end if;
   container_kind:=destination.children_kind;
   if mode='move' and destination.identity_path[1:cardinality(n.identity_path)]=n.identity_path then raise exception using errcode='22023',message='A subtask cannot contain itself';end if;
  end if;
 end if;
 if mode='insert' then
  if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records r on r.task_id=id and r.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A new child identity is already in use';end if;
  desired:=taskfold_private.child_structure_insert(coalesce(t.subtasks,'null'::jsonb),parent,slot,subtree);
  inverse:=jsonb_build_object('parent_key',parent,'container_kind',container_kind);
 elsif mode='move' then
  desired:=taskfold_private.child_structure_insert(taskfold_private.child_structure_remove(t.subtasks,key),parent,slot,subtree);
  inverse:=jsonb_build_object('parent_key',n.parent_key,'index',n.sibling_order,'destination_parent',parent,'destination_kind',container_kind);
 elsif mode='delete' then
  if b->'subtree_versions' is distinct from taskfold_private.child_structure_versions(id,key) then raise exception using errcode='PT409',message='A subtask being removed changed; review it before deleting';end if;
  select count(*),coalesce(sum(octet_length(ar.subtree::text)),0) into archive_count,archive_size from taskfold_private.child_task_structure_archives ar where actor_id=a;
  if archive_count>=64 or archive_size+octet_length(subtree::text)>16777216 then raise exception using errcode='PT429',message='Review saved subtree Undo content before deleting more tasks';end if;
  desired:=taskfold_private.child_structure_remove(t.subtasks,key);inverse:=jsonb_build_object('parent_key',n.parent_key,'index',n.sibling_order);
 else
  if original.after_revision<>rev then raise exception using errcode='PT409',message='The hierarchy changed after this action; review it before Undo';end if;
  if original.action='insert' then
   if taskfold_private.child_structure_digest(id,key) is distinct from original.inverse->>'subtree_digest' then raise exception using errcode='PT409',message='The inserted subtree changed; keep its new work and review it before deleting';end if;
   desired:=taskfold_private.child_structure_remove(t.subtasks,key);
   desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'parent_key',original.inverse->>'container_kind');
  elsif original.action='move' then
   desired:=taskfold_private.child_structure_insert(taskfold_private.child_structure_remove(t.subtasks,key),original.inverse->>'parent_key',(original.inverse->>'index')::integer,subtree);
   desired:=taskfold_private.child_structure_restore_container(desired,original.inverse->>'destination_parent',original.inverse->>'destination_kind');
  else
   -- A fresh completion epoch fences supported legacy tokened requests too.
   subtree:=taskfold_private.child_structure_fresh_node(subtree,true);
   if exists(select 1 from jsonb_array_elements(extra_decoded->'nodes') x join taskfold_private.child_task_records r on r.task_id=id and r.node_key=x->>'key' collate "C") then raise exception using errcode='PT409',message='A restored child identity is already in use';end if;
   desired:=taskfold_private.child_structure_insert(coalesce(t.subtasks,'null'::jsonb),original.inverse->>'parent_key',(original.inverse->>'index')::integer,subtree);
  end if;
 end if;
 if desired is not distinct from coalesce(t.subtasks,'null'::jsonb) then raise exception using errcode='22023',message='Choose a different child slot';end if;
 if octet_length(desired::text)>2000000 or taskfold_private.decode_child_task_tree(desired)->>'state'<>'ready' then raise exception using errcode='54000',message='The resulting hierarchy needs review or exceeds its limits';end if;
 if (select count(*) from taskfold_private.child_task_structure_receipts where actor_id=a and created_at>clock_timestamp()-interval '1 day')>=2000 then raise exception using errcode='PT429',message='Too many structure actions; try again later';end if;
 if team is not null then
  if not exists(select 1 from taskfold_private.team_content_tasks c where c.task_id=id and c.generation=g and c.team_id=team) then raise exception using errcode='PT409',message='This team task changed';end if;
  insert into taskfold_private.team_task_edit_scope(transaction_id,team_id,project_id,task_id,generation,actor_id,operation,request_id) values(txid_current(),team,p,id,g,a,'patch',q);
 end if;
 desired:=taskfold_private.prepare_child_record_tree(op.id,g,desired);
 update public.tasks set subtasks=case when desired='null'::jsonb then null else desired end where tasks.id=op.id returning * into t;
 if team is not null then
  delete from taskfold_private.team_task_edit_scope where transaction_id=txid_current() and task_id=id;
  insert into taskfold_private.team_task_edits(team_id,request_id,actor_id,fingerprint,task_id,generation,operation) values(team,q,a,fingerprint,id,g,'child_structure');
 end if;
 if coalesce(t.subtasks,'null'::jsonb)<>desired or not exists(select 1 from taskfold_private.child_task_projections where task_id=id and structure_revision=rev+1 and source_tree=desired) then raise exception using errcode='PT409',message='This structure action could not be confirmed';end if;
 perform taskfold_private.read_child_task_records(id,g);perform taskfold_private.team_actor();
 if team is not null and coalesce(taskfold_private.team_project_role(a,p),'') not in('manager','editor') then raise exception using errcode='42501',message='Editing access changed';end if;
 if team is null and p is not null and not coalesce(public.has_project_access(a,p),false) then raise exception using errcode='42501',message='Editing access changed';end if;
 select * into n from taskfold_private.child_task_records where task_id=id and node_key=key;
 if mode='insert' then inverse:=inverse||jsonb_build_object('subtree_digest',taskfold_private.child_structure_digest(id,key));end if;
 insert into taskfold_private.child_task_structure_receipts(actor_id,request_id,fingerprint,task_id,generation,project_id,action,undo_of,before_revision,after_revision,node_key,incarnation,inverse)
 values(a,q,fingerprint,id,g,p,mode,undo_id,rev,rev+1,key,n.incarnation,inverse) returning * into prior;
 if mode='delete' then insert into taskfold_private.child_task_structure_archives(actor_id,request_id,task_id,subtree) values(a,q,id,subtree);end if;
 if mode='undo' then
  update taskfold_private.child_task_structure_receipts set reversed_by=q where actor_id=a and request_id=undo_id;
  delete from taskfold_private.child_task_structure_archives where actor_id=a and request_id=undo_id;
 end if;
 return taskfold_private.child_structure_receipt(prior,false);
end$$;

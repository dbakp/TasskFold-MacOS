-- Include child history in the existing bounded, reviewed project transfer.
-- Existing receipts/retry bodies are unchanged. A new counts key makes old
-- strict readers request an update; old uncommitted proofs become stale.
-- Apply transactionally; no rollout flag, provider or client write grants change.


create or replace function taskfold_private.capture_project_realm_write() returns trigger
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
 elsif tg_table_name in('task_activity','task_node_activity') then
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

create trigger zz_taskfold_ownership_capture before insert or update or delete on public.task_node_activity
 for each row execute function taskfold_private.capture_project_realm_write();

create or replace function taskfold_private.project_adoption_contents(ids uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare item record; hashes jsonb:='{}'; counts jsonb:='{}'; rows jsonb; n bigint; bytes bigint; total bigint:=0; entries bigint:=0;
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
 return jsonb_build_object('hashes',hashes,'counts',counts,'content_bytes',total,'attachments',attachments,'inline_files',inline_files,
  'external_files',external_files,'provider_files',unknown_files,'email_routes',jsonb_array_length(email_rows),'webhooks',jsonb_array_length(hooks),'queued_webhook_events',queued,'inflight_webhook_events',inflight,'project_webhooks',(effects->>'project_webhooks_paused')::bigint+(effects->>'pending_webhooks_cancelled')::bigint,'pending_project_webhooks',(effects->>'pending_webhooks_cancelled')::bigint,'global_webhooks',(effects->>'global_webhooks_excluded')::bigint);
end$$;

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
  union select user_id from public.task_node_activity where before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) or task_id in(select id from public.tasks where project_id=any(ids))
  union select actor_id from public.task_node_activity where before_state->>'project_id'=any(ids::text[]) or after_state->>'project_id'=any(ids::text[]) or task_id in(select id from public.tasks where project_id=any(ids))
  union select unnest(taskfold_private.project_adoption_connection_accounts(ids))
  union select user_id from taskfold_private.team_members where team_id=team
 ) p where person is not null
$$;

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
 result=jsonb_build_object('child_history_protocol',1,'project_adoption_protocol',1,'account',a,'team_id',team,'roots',roots,'visibility',visibility,'folder_id',folder,'parent_id',parent,
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

revoke all on function taskfold_private.capture_project_realm_write(),
 taskfold_private.project_adoption_contents(uuid[]),taskfold_private.project_adoption_people(uuid[],uuid) from public,anon,authenticated,service_role;

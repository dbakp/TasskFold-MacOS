-- Access decisions can exceed the ordinary 16 KiB team command envelope.
-- Keep an explicit bounded shape validator rather than silently reducing the
-- documented 1,000-collaborator atomic-review limit.
create function taskfold_private.project_adoption_fields(b jsonb,required text[]) returns void
language plpgsql immutable security invoker set search_path='' as $$begin
 if b is null or jsonb_typeof(b)<>'object' or not b ?& required or exists(select 1 from jsonb_object_keys(b) k where not(k=any(required))) then raise exception using errcode='22023',message='Invalid project transfer request';end if;
 if octet_length(b::text)>262144 then raise exception using errcode='54000',message='This project transfer request is too large';end if;
end$$;
revoke all on function taskfold_private.project_adoption_fields(jsonb,text[]) from public,anon,authenticated,service_role;

-- Reviewed personal-project adoption, first stage: bounded contents/access proofs.
-- Inspect/review never transfer custody. The commit operation and native UI follow.
-- No rollout configuration or hosted state changes in this migration.
create function taskfold_private.project_adoption_forest(a uuid, roots uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$
declare ids uuid[]; nodes jsonb; n integer; bad boolean;begin
 if cardinality(roots) not between 1 and 100 or exists(select 1 from unnest(roots) r where r is null)
  or cardinality(roots)<>(select count(distinct r) from unnest(roots) r) then
  raise exception using errcode='22023',message='Choose up to 100 distinct project branches';end if;
 if exists(select 1 from unnest(roots) r where not exists(select 1 from public.projects p where p.id=r and p.user_id=a)
   or exists(select 1 from taskfold_private.team_project_identities b where b.project_id=r)) then
  raise exception using errcode='42501',message='Choose personal projects you own';end if;
 with recursive branch(id,root_id,depth,path,cycle) as (
  select p.id,p.id,1,array[p.id],false from public.projects p where p.id=any(roots)
  union all select p.id,b.root_id,b.depth+1,b.path||p.id,p.id=any(b.path)
   from public.projects p join branch b on p.parent_id=b.id where not b.cycle and b.depth<=20
 ), bounded as materialized(select * from branch limit 1001)
 select array_agg(id order by id),count(*),bool_or(cycle or depth>20) or count(*)<>count(distinct id),
  jsonb_agg(jsonb_build_object('id',id,'root_id',root_id,'depth',depth) order by depth,id)
 into ids,n,bad,nodes from bounded;
 if n not between 1 and 1000 or coalesce(bad,true) then
  raise exception using errcode='54000',message='Choose separate project branches within the supported size and depth';end if;
 if exists(select 1 from public.projects p where p.id=any(ids) and (p.user_id<>a
   or exists(select 1 from taskfold_private.team_project_identities b where b.project_id=p.id))) then
  raise exception using errcode='42501',message='You must own every personal project in these branches';end if;
 if exists(select 1 from public.projects p where p.id=any(ids) and p.ancestor_archived is distinct from
  coalesce((select x.is_archived or x.ancestor_archived from public.projects x where x.id=p.parent_id),false)) then
  raise exception using errcode='PT409',message='Refresh the project archive state before transferring';end if;
 return jsonb_build_object('ids',ids,'nodes',nodes);
end$$;

-- Rich checklist items have their own attachment arrays too. Inventory every
-- supported depth rather than silently treating child files as ordinary text.
create function taskfold_private.project_adoption_attachments(ids uuid[]) returns jsonb
language sql volatile security invoker set search_path='' as $$
 with recursive nodes(node,depth) as (
  select to_jsonb(t),0 from public.tasks t where t.project_id=any(ids)
  union all select c.value,n.depth+1 from nodes n cross join lateral
   jsonb_array_elements(case when jsonb_typeof(n.node->'subtasks')='array' then n.node->'subtasks' else '[]'::jsonb end) c where n.depth<32
 ), files as (
  select a.value from nodes n cross join lateral jsonb_array_elements(case when jsonb_typeof(n.node->'attachments')='array' then n.node->'attachments' else '[]'::jsonb end) a
 ), inventory as (
  select count(*) total,count(*) filter(where value->>'url' like 'data:%') inline_files,
  count(*) filter(where value->>'url' ~ '^https?://' and value->>'url' !~* '/storage/v1/(object|render)/') external_files,
  count(*) filter(where jsonb_typeof(value)<>'object' or coalesce(value->>'url','')='' or
   not(value->>'url' like 'data:%' or value->>'url' ~ '^https?://' and value->>'url' !~* '/storage/v1/(object|render)/')) provider_files from files
 ) select jsonb_build_object('attachments',total,'inline_files',inline_files,'external_files',external_files,
  'provider_files',provider_files+(select count(*) from nodes where node ? 'attachments' and jsonb_typeof(node->'attachments')<>'array')) from inventory
$$;
revoke all on function taskfold_private.project_adoption_attachments(uuid[]) from public,anon,authenticated,service_role;

-- Private snapshot returns hashes/counts only: task bodies, inline files, webhook
-- endpoints, credentials and unread metadata never become a receipt payload.
create function taskfold_private.project_adoption_contents(ids uuid[]) returns jsonb
language plpgsql volatile security invoker set search_path='' set timezone='UTC' as $$
declare item record; hashes jsonb:='{}'; counts jsonb:='{}'; rows jsonb; n bigint; bytes bigint; total bigint:=0; entries bigint:=0;
 attachments bigint; inline_files bigint; external_files bigint; unknown_files bigint; email_rows jsonb:='[]'; hooks jsonb:='[]';begin
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
  execute 'select coalesce(jsonb_agg(jsonb_build_array(id,user_id,project_id,state,revision) order by id),''[]'') from taskfold_private.email_routes where project_id=any($1) and state<>''revoked''' into email_rows using ids;
 end if;
 if to_regclass('taskfold_private.webhook_subscriptions') is not null then
  execute 'select coalesce(jsonb_agg(jsonb_build_array(id,user_id,project_id,scope,state,revision,expires_at) order by id),''[]'') from taskfold_private.webhook_subscriptions where state<>''revoked'' and (project_id=any($1) or scope=''all'' and user_id in(select user_id from public.projects where id=any($1) union select user_id from public.project_collaborators where project_id=any($1) and status=''accepted''))' into hooks using ids;
 end if;
 if octet_length(email_rows::text)+octet_length(hooks::text)>1000000 then raise exception using errcode='54000',message='Too many integration destinations to review safely';end if;
 hashes=hashes||jsonb_build_object('email_routes',encode(extensions.digest(convert_to(email_rows::text,'UTF8'),'sha256'),'hex'),
  'webhook_subscriptions',encode(extensions.digest(convert_to(hooks::text,'UTF8'),'sha256'),'hex'));
 return jsonb_build_object('hashes',hashes,'counts',counts,'content_bytes',total,'attachments',attachments,'inline_files',inline_files,
  'external_files',external_files,'provider_files',unknown_files,'email_routes',jsonb_array_length(email_rows),'webhooks',jsonb_array_length(hooks));
end$$;

create function taskfold_private.project_adoption_people(ids uuid[],team uuid) returns uuid[]
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
  union select user_id from taskfold_private.team_members where team_id=team
 ) p where person is not null
$$;
create function taskfold_private.project_adoption_member_live(a uuid,t uuid) returns boolean
language sql volatile security invoker set search_path='' as $$
 select exists(select 1 from taskfold_private.team_members m join auth.users u on u.id=m.user_id
 where m.team_id=t and m.user_id=a and u.email_confirmed_at is not null and coalesce(u.email,'')<>''
 and (u.banned_until is null or u.banned_until<=clock_timestamp())
 and not exists(select 1 from taskfold_private.account_removal_receipts r where r.account_id=a and r.created_at>clock_timestamp()-interval '7 days'))
$$;
create function taskfold_private.project_adoption_role(a uuid,p uuid,t uuid,visibility text,decisions jsonb) returns text
language sql volatile security invoker set search_path='' as $$
 select case when not taskfold_private.project_adoption_member_live(a,t) then null
  when a=auth.uid() or a=team.owner_id or m.role='admin' then 'manager'
  when d.value->>'role' is not null then d.value->>'role'
  when visibility='team' and m.role='member' then 'editor' end
 from taskfold_private.teams team join taskfold_private.team_members m on m.team_id=team.id and m.user_id=a
 left join lateral(select v value from jsonb_array_elements(decisions) v where v->>'project_id'=p::text and v->>'user_id'=a::text) d on true
 where team.id=t
$$;

create function taskfold_private.project_adoption_review(operation text,b jsonb) returns jsonb
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
  'commit_supported',coalesce((select native_project_adoption_enabled from taskfold_private.team_project_config where singleton),false) and (contents->>'provider_files')::bigint=0 and (contents->>'email_routes')::integer=0 and (contents->>'webhooks')::integer=0,'team_member_count',jsonb_array_length(members));
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
create function public.taskfold_team_project_adoption(operation text,body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.project_adoption_review(operation,body)$$;
revoke all on function taskfold_private.project_adoption_forest(uuid,uuid[]),taskfold_private.project_adoption_contents(uuid[]),taskfold_private.project_adoption_people(uuid[],uuid),taskfold_private.project_adoption_member_live(uuid,uuid),taskfold_private.project_adoption_role(uuid,uuid,uuid,text,jsonb),taskfold_private.project_adoption_review(text,jsonb),public.taskfold_team_project_adoption(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.project_adoption_review(text,jsonb),public.taskfold_team_project_adoption(text,jsonb) to authenticated;

-- Assignment identity is UUID-based, including legacy uppercase JSON spellings.
-- Preserve every other field and every eligible assignment/provenance record.
create function taskfold_private.project_adoption_clear_assignee(items jsonb,person uuid) returns jsonb
language plpgsql immutable security invoker set search_path='' as $$
declare result jsonb:='[]';item jsonb;begin
 for item in select value from jsonb_array_elements(items) loop
  if lower(item->>'assigned_to')=person::text then item=item-'assigned_to';end if;
  if jsonb_typeof(item->'subtasks')='array' then item=jsonb_set(item,'{subtasks}',taskfold_private.project_adoption_clear_assignee(item->'subtasks',person));end if;
  result=result||jsonb_build_array(item);
 end loop;return result;
end$$;
revoke all on function taskfold_private.project_adoption_clear_assignee(jsonb,uuid) from public,anon,authenticated,service_role;

-- Durable, identity-only receipts outlive expired reviews and subsequent edits.
create table taskfold_private.project_adoption_receipts (
 team_id uuid not null references taskfold_private.teams(id) on delete restrict,
 request_id uuid not null,actor_id uuid not null references auth.users(id) on delete cascade,
 fingerprint text not null,project_ids uuid[] not null,root_ids uuid[] not null,
 parent_id uuid,folder_id uuid,visibility text not null,
 assignments_cleared integer not null,invitations_closed integer not null,
 created_at timestamptz not null default clock_timestamp(),primary key(team_id,request_id)
);
create index project_adoption_receipts_actor on taskfold_private.project_adoption_receipts(actor_id);
alter table taskfold_private.project_adoption_receipts enable row level security;
revoke all on taskfold_private.project_adoption_receipts from public,anon,authenticated,service_role;
alter table taskfold_private.team_project_config add column native_project_adoption_enabled boolean not null default false;
create function taskfold_private.project_adoption_receipt_reply(r taskfold_private.project_adoption_receipts,replayed boolean) returns jsonb
language sql volatile security invoker set search_path='' as $$
 select jsonb_build_object('project_adoption_protocol',1,'account',r.actor_id,'team_id',r.team_id,'request_id',r.request_id,
  'project_ids',r.project_ids,'roots',r.root_ids,'parent_id',r.parent_id,'folder_id',r.folder_id,'visibility',r.visibility,
  'assignments_cleared',r.assignments_cleared,'invitations_closed',r.invitations_closed,'applied',true,'replayed',replayed,'automatic_undo',false)
$$;
create function taskfold_private.project_adoption_commit(b jsonb) returns jsonb
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
revoke all on function taskfold_private.project_adoption_receipt_reply(taskfold_private.project_adoption_receipts,boolean),taskfold_private.project_adoption_commit(jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.project_adoption_commit(jsonb) to authenticated;
create or replace function public.taskfold_team_project_adoption(operation text,body jsonb) returns jsonb
language plpgsql volatile security invoker set search_path='' as $$begin
 if operation='adopt' then return taskfold_private.project_adoption_commit(body);end if;
 return taskfold_private.project_adoption_review(operation,body);
end$$;

-- The personal service helper must recheck custody after acquiring its row lock:
-- an earlier statement snapshot/creator match cannot authorize a new team route.
create or replace function taskfold_private.automation_lock_project(_account uuid,_project uuid)
returns void language plpgsql volatile security invoker set search_path='' as $$
declare owner_id uuid;begin
 if taskfold_private.is_team_content_project(_project) then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 select user_id into owner_id from public.projects where id=_project for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
 if taskfold_private.is_team_content_project(_project) then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
 if owner_id=_account then return;end if;
 perform 1 from public.project_collaborators where project_id=_project and user_id=_account and status='accepted' for share;
 if not found then raise exception using errcode='PT404',message='Task or project is unavailable';end if;
 if taskfold_private.is_team_content_project(_project) then raise exception using errcode='PT503',message='Team project access is not enabled';end if;
end$$;

-- Keep team data outside personal webhook capture, including subscriptions
-- enrolled after adoption. No dispatcher/provider is enabled by this guard.
create or replace function taskfold_private.webhook_capture_available(t public.tasks) returns boolean
language sql stable security invoker set search_path='' as $$select not taskfold_private.is_team_content_project(t.project_id) and not taskfold_private.is_team_content_task(t.id) and not exists(select 1 from taskfold_private.team_project_adoption_scope where transaction_id=txid_current() and project_id=t.project_id) and exists(
 select 1 from taskfold_private.webhook_subscriptions h where h.verified_at is not null and h.state in('active','paused') and h.expires_at>clock_timestamp()
 and (case when t.project_id is null then h.user_id=t.user_id else h.user_id in(select user_id from public.projects where id=t.project_id union select user_id from public.project_collaborators where project_id=t.project_id and status='accepted') end)
 and (h.scope='all' or (h.scope='inbox' and t.project_id is null) or (h.scope='project' and h.project_id=t.project_id)))$$;
create or replace function taskfold_private.webhook_enqueue(t public.tasks,kind text,small boolean,new_location public.tasks default null) returns void
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
declare s taskfold_private.webhook_subscriptions;b taskfold_private.webhook_budgets;stamp timestamptz;today date;event_id uuid;body text;bytes integer;issue text;projection jsonb;
begin
 if taskfold_private.is_team_content_project(t.project_id) or taskfold_private.is_team_content_task(t.id) or exists(select 1 from taskfold_private.team_project_adoption_scope where transaction_id=txid_current() and project_id=t.project_id) then return;end if;
 for s in select h.* from taskfold_private.webhook_subscriptions h
  where h.verified_at is not null and h.state in('active','paused') and h.expires_at>clock_timestamp()
  and (case when t.project_id is null then h.user_id=t.user_id else h.user_id in
   (select user_id from public.projects where id=t.project_id union select user_id from public.project_collaborators where project_id=t.project_id and status='accepted') end)
  and (h.scope='all' or (h.scope='inbox' and t.project_id is null) or (h.scope='project' and h.project_id=t.project_id))
  and (case when kind='task.removed' then 'task.updated' else kind end)=any(h.events)
  and not exists(select 1 from taskfold_private.webhook_removal_blocks r where r.user_id=h.user_id)
  and exists(select 1 from auth.users u where u.id=h.user_id and (u.banned_until is null or u.banned_until<=clock_timestamp()))
  order by h.id for key share of h skip locked loop
  if kind='task.removed' and new_location.id is not null and
   (s.scope='all' or (s.scope='inbox' and new_location.project_id is null) or (s.scope='project' and s.project_id=new_location.project_id))
   and ((new_location.project_id is null and new_location.user_id=s.user_id) or public.has_project_access(s.user_id,new_location.project_id)) then continue;end if;
  select * into b from taskfold_private.webhook_budgets where subscription_id=s.id for update;
  if not found then continue;end if;
  stamp=clock_timestamp();today=(stamp at time zone 'UTC')::date;
  if b.capture_day<>today then b.capture_day=today;b.day_events=0;b.day_bytes=0;end if;
  event_id=gen_random_uuid();
  projection=case when small then jsonb_build_object('id',t.id,'task_generation',coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid),'project_id',t.project_id)
   else taskfold_private.automation_task_projection(t)||jsonb_build_object('task_generation',coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid)) end;
  body=jsonb_build_object('version',1,'event_id',event_id,'type',kind,'occurred_at',stamp,'task',projection)::text;bytes=octet_length(body);
  issue=case when bytes>16777216 then 'payload_too_large' when b.day_events>=500 or b.day_bytes::bigint+bytes>33554432 then 'event_quota' when b.pending>=256 or b.retained_bytes::bigint+bytes>33554432 then 'queue_capacity' else null end;
  if issue is not null then
   update taskfold_private.webhook_budgets set capture_day=today,day_events=b.day_events,day_bytes=b.day_bytes,
    missed=least(2147483646,missed)+1,capture_issue=issue,missed_since=coalesce(missed_since,stamp),missed_until=stamp where subscription_id=s.id;
   continue;
  end if;
  insert into taskfold_private.webhook_outbox(id,user_id,subscription_id,task_id,task_generation,access_owner,access_project,event_type,minimal,payload,payload_bytes,payload_sha256,part_count,created_at,expires_at,next_attempt_at)
   values(event_id,s.user_id,s.id,t.id,coalesce(t.task_generation,'00000000-0000-0000-0000-000000000000'::uuid),t.user_id,t.project_id,kind,small,body,bytes,
    encode(extensions.digest(convert_to(body,'UTF8'),'sha256'),'hex'),case when bytes<=250000 then 1 else (bytes+179999)/180000 end,stamp,stamp+interval '24 hours',stamp);
  update taskfold_private.webhook_budgets set capture_day=today,day_events=b.day_events+1,day_bytes=b.day_bytes+bytes,pending=pending+1,retained_bytes=retained_bytes+bytes where subscription_id=s.id;
 end loop;
end$$;

-- A repeatable snapshot cannot observe a newer immutable custody row.
-- Reject its personal writes rather than let an old snapshot bypass cutover.
create or replace function taskfold_private.validate_project_realm_writes() returns trigger
language plpgsql security definer set search_path='' as $$
declare p text;team uuid;item record;v record;current_realm jsonb;
begin
 if current_setting('transaction_isolation')<>'read committed' then raise exception using errcode='25000',message='Use a fresh read-committed transaction before retrying this saved project edit';end if;
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

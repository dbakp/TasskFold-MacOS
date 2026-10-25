-- Source-only team library. No template definition grants task/project authority.
create table taskfold_private.team_template_config (
 singleton boolean primary key default true check(singleton), enabled boolean not null default false
);
insert into taskfold_private.team_template_config default values;
create table taskfold_private.team_template_library_state (
 team_id uuid primary key references taskfold_private.teams(id) on delete cascade,
 revision bigint not null check(revision between 1 and 9007199254740991)
);
-- Identities outlive removed definitions so stale revisions cannot target a reused ID.
create table taskfold_private.team_template_identities (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 id uuid not null, primary key(team_id,id)
);
create table taskfold_private.team_templates (
 team_id uuid not null, id uuid not null, name text not null,
 document jsonb not null, revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 created_by uuid references auth.users(id) on delete set null,
 created_at timestamptz not null default clock_timestamp(), updated_at timestamptz not null default clock_timestamp(),
 primary key(team_id,id), foreign key(team_id,id) references taskfold_private.team_template_identities(team_id,id) on delete cascade,
 check(char_length(btrim(name)) between 1 and 160 and octet_length(name)<=640 and name !~ '[[:cntrl:]]'),
 check(jsonb_typeof(document)='object' and octet_length(document::text)<=2000000 and
  case when jsonb_typeof(document->'version')='number' then (document->>'version')::numeric between 1 and 9007199254740991 and (document->>'version')::numeric=trunc((document->>'version')::numeric) else false end)
);
create index team_templates_author on taskfold_private.team_templates(created_by) where created_by is not null;
create table taskfold_private.team_template_commands (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 request_id uuid not null, actor_id uuid references auth.users(id) on delete set null,
 fingerprint text not null, operation text not null check(operation in('publish','replace','delete')),
 template_id uuid not null, revision bigint not null, created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id)
);
create index team_template_commands_actor on taskfold_private.team_template_commands(actor_id) where actor_id is not null;
do $$declare n text;begin
 foreach n in array array['team_template_config','team_template_library_state','team_template_identities','team_templates','team_template_commands'] loop
  execute format('alter table taskfold_private.%I enable row level security',n);
  execute format('revoke all on taskfold_private.%I from public,anon,authenticated,service_role',n);
 end loop;
end$$;
create function taskfold_private.team_templates_purge() returns trigger
language plpgsql security definer set search_path='' as $$begin
 delete from taskfold_private.team_template_library_state where team_id=new.id;
 delete from taskfold_private.team_template_commands where team_id=new.id;
 delete from taskfold_private.team_template_identities where team_id=new.id;
 return new;
end$$;
create trigger team_templates_purge after update of state on taskfold_private.teams for each row
 when(new.state='deleted' and old.state is distinct from new.state) execute function taskfold_private.team_templates_purge();
revoke all on function taskfold_private.team_templates_purge() from public,anon,authenticated,service_role;

create function taskfold_private.team_templates_manage(op text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set timezone='UTC' set lock_timeout='3s' as $$
<<cmd>>
declare a uuid:=auth.uid();team uuid;id uuid;q uuid;cursor_id uuid;expected bigint;n text;doc jsonb;
 x taskfold_private.teams;item taskfold_private.team_templates;prior taskfold_private.team_template_commands;
 r text;fingerprint text;result jsonb;items jsonb;today date:=(clock_timestamp() at time zone 'UTC')::date;revision bigint;bytes bigint;library_revision bigint;
begin
 perform taskfold_private.team_actor();
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>2100000 then raise exception using errcode='22023',message='Review a bounded template request';end if;
 if op='list' then perform taskfold_private.team_fields(b,array['team_id'],array['cursor','library_revision']);
 elsif op='get' then perform taskfold_private.team_fields(b,array['team_id','template_id']);
 elsif op='publish' then perform taskfold_private.team_fields(b-'document',array['team_id','template_id','request_id','name']);
 elsif op='replace' then perform taskfold_private.team_fields(b-'document',array['team_id','template_id','request_id','revision','name']);
 elsif op='delete' then perform taskfold_private.team_fields(b,array['team_id','template_id','request_id','revision']);
 else raise exception using errcode='22023',message='Choose a supported library action';end if;
 team=taskfold_private.team_uuid(b,'team_id');
 if op='list' and b ? 'cursor' and b->'cursor'<>'null'::jsonb then cursor_id=taskfold_private.team_uuid(b,'cursor');end if;
 if op<>'list' then id=taskfold_private.team_uuid(b,'template_id');end if;
 if op in('publish','replace','delete') then q=taskfold_private.team_uuid(b,'request_id');end if;
 if op in('replace','delete') then
  if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')::numeric not between 1 and 9007199254740991 or (b->>'revision')::numeric<>trunc((b->>'revision')::numeric) then raise exception using errcode='22023',message='Review the current template version';end if;
  expected=(b->>'revision')::bigint;
 end if;
 if op in('publish','replace') then
  n=btrim(b->>'name');doc=b->'document';
  if jsonb_typeof(b->'name') is distinct from 'string' or char_length(n) not between 1 and 160 or octet_length(n)>640 or n ~ '[[:cntrl:]]' or n ~ U&'[\202A-\202E\2066-\2069]'
   or doc is null or jsonb_typeof(doc)<>'object' or octet_length(doc::text)>2000000 or jsonb_typeof(doc->'version') is distinct from 'number' then raise exception using errcode='22023',message='Review the template name and definition';end if;
  if (doc->>'version')::numeric not between 1 and 9007199254740991 or (doc->>'version')::numeric<>trunc((doc->>'version')::numeric) then raise exception using errcode='22023',message='Choose a versioned template definition';end if;
  -- Definitions are versioned storage, not execution authority. Current clients
  -- validate the complete known workflow schema before offering Use/Edit. Future
  -- versions remain opaque and preserved; any future run service must validate anew.
 end if;
 -- Auth locks precede team locks. Membership/state is re-read after waiting.
 if op in('list','get') then select * into x from taskfold_private.teams where teams.id=team for share;
 else select * into x from taskfold_private.teams where teams.id=team for update;end if;
 perform taskfold_private.team_actor();
 select case when x.owner_id=a then 'owner' else m.role end into r from taskfold_private.team_members m where m.team_id=team and m.user_id=a;
 if x.id is null or x.state='deleted' or coalesce(r,'') not in('owner','admin','member') then raise exception using errcode='PT404',message='Team library is unavailable';end if;
 perform 1 from taskfold_private.team_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team library is not enabled';end if;
 perform 1 from taskfold_private.team_template_config where singleton and enabled for share;
 if not found then raise exception using errcode='PT503',message='Team library is not enabled';end if;
 if op in('list','get') then
  select coalesce((select s.revision from taskfold_private.team_template_library_state s where s.team_id=team),0) into library_revision;
  if op='list' and cursor_id is not null and not b ? 'library_revision' then raise exception using errcode='22023',message='Continue with the reviewed library revision';end if;
  if op='list' and b ? 'library_revision' then
   if jsonb_typeof(b->'library_revision') is distinct from 'number' or (b->>'library_revision')::numeric not between 0 and 9007199254740991 or (b->>'library_revision')::numeric<>trunc((b->>'library_revision')::numeric) then raise exception using errcode='22023',message='Use a valid library revision';end if;
   if (b->>'library_revision')::numeric<>library_revision then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: The library changed; refresh its catalog';end if;
  end if;
  if op='get' then
   select * into item from taskfold_private.team_templates where team_id=team and team_templates.id=cmd.id;
   if not found then raise exception using errcode='PT404',message='Template is unavailable';end if;
   return jsonb_build_object('library_protocol',1,'account',a,'team_id',team,'team_state',x.state,'role',r,'can_manage',r in('owner','admin') and x.state='active','item',to_jsonb(item)-array['team_id','created_by']);
  end if;
  select coalesce(jsonb_agg(z.row order by z.id),'[]') into items from(
   select t.id,to_jsonb(t)-array['team_id','created_by','document'] as row from taskfold_private.team_templates t
   where t.team_id=team and (cursor_id is null or t.id>cursor_id) order by t.id limit 51)z;
  if jsonb_array_length(items)>50 then items=items-50;cursor_id=(items->49->>'id')::uuid;else cursor_id=null;end if;
  return jsonb_build_object('library_protocol',1,'account',a,'team_id',team,'team_state',x.state,'role',r,'can_manage',r in('owner','admin') and x.state='active','library_revision',library_revision,'items',items,'next_cursor',cursor_id);
 end if;
 if r not in('owner','admin') then raise exception using errcode='42501',message='A team owner or admin curates the library';end if;
 if x.state<>'active' then raise exception using errcode='PT409',message='Reopen the team before changing its library';end if;
 select encode(extensions.hmac(convert_to(jsonb_build_array(a,op,b)::text,'UTF8'),s.secret,'sha256'),'hex') into fingerprint from taskfold_private.automation_revision_secret s where singleton;
 if fingerprint is null then raise exception using errcode='PT503',message='Team library is unavailable';end if;
 select * into prior from taskfold_private.team_template_commands where team_id=team and request_id=q;
 if found then
  if prior.actor_id is distinct from a or prior.operation<>op or prior.fingerprint<>fingerprint then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: This library request identity is already used';end if;
  return jsonb_build_object('library_protocol',1,'account',a,'team_id',team,'request_id',q,'operation',op,'template_id',prior.template_id,'revision',prior.revision,'deleted',op='delete','replayed',true);
 end if;
 if x.usage_day=today and x.day_operations>=2000 and op<>'delete' then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
 select * into item from taskfold_private.team_templates where team_id=team and team_templates.id=cmd.id for update;
 if op='publish' then
  if exists(select 1 from taskfold_private.team_template_identities where team_id=team and team_template_identities.id=cmd.id) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Choose a fresh template identity';end if;
  if (select count(*) from taskfold_private.team_templates where team_id=team)>=200 then raise exception using errcode='PT429',message='Keep up to 200 templates in this library';end if;
  revision=1;
 else
  if item.id is null or item.revision<>expected or (op<>'delete' and item.revision>=9007199254740991) then raise exception using errcode='PT409',message='TASKFOLD_CONFLICT: Review the current template';end if;
  revision=case when op='delete' then item.revision else item.revision+1 end;
 end if;
 if op<>'delete' then
  select coalesce(sum(octet_length(t.document::text)),0)-coalesce(octet_length(item.document::text),0)+octet_length(doc::text) into bytes from taskfold_private.team_templates t where t.team_id=team;
  if bytes>33554432 then raise exception using errcode='PT429',message='The team template library is full';end if;
 end if;
 if op='publish' then
  insert into taskfold_private.team_template_identities values(team,id);
  insert into taskfold_private.team_templates(team_id,id,name,document,created_by) values(team,id,n,doc,a);
 elsif op='replace' then update taskfold_private.team_templates set name=n,document=doc,revision=cmd.revision,updated_at=clock_timestamp() where team_id=team and team_templates.id=cmd.id;
 else delete from taskfold_private.team_templates where team_id=team and team_templates.id=cmd.id;end if;
 insert into taskfold_private.team_template_library_state(team_id,revision) values(team,1)
 on conflict(team_id) do update set revision=team_template_library_state.revision+1;
 update taskfold_private.teams set usage_day=today,day_operations=case when usage_day=today then least(day_operations+1,2000) else 1 end where teams.id=team;
 insert into taskfold_private.team_template_commands(team_id,request_id,actor_id,fingerprint,operation,template_id,revision) values(team,q,a,fingerprint,op,id,revision);
 return jsonb_build_object('library_protocol',1,'account',a,'team_id',team,'request_id',q,'operation',op,'template_id',id,'revision',revision,'deleted',op='delete','replayed',false);
end$$;
revoke all on function taskfold_private.team_templates_manage(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function taskfold_private.team_templates_manage(text,jsonb) to authenticated;
create function public.taskfold_team_templates(_operation text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_templates_manage(_operation,_body)$$;
revoke all on function public.taskfold_team_templates(text,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.taskfold_team_templates(text,jsonb) to authenticated;

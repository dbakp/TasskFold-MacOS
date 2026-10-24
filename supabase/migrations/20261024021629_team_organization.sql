-- Disabled team foundation. Team records do not grant access to existing projects.
-- Project/task/API/mail/storage authority integration precedes native rollout.
create table taskfold_private.team_config (
 singleton boolean primary key default true check(singleton),
 enabled boolean not null default false
);
insert into taskfold_private.team_config default values;
create table taskfold_private.teams (
 id uuid primary key,
 owner_id uuid references auth.users(id) on delete restrict,
 name text,
 state text not null default 'active' check(state in('active','archived','deleted')),
 revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 usage_day date not null default (clock_timestamp() at time zone 'UTC')::date,
 day_operations integer not null default 0 check(day_operations between 0 and 2000),
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 check((state='deleted' and owner_id is null and name is null) or
       (state<>'deleted' and owner_id is not null and name is not null and char_length(name) between 1 and 100 and octet_length(name)<=400 and name !~ '[[:cntrl:]]'))
);
create index teams_owner on taskfold_private.teams(owner_id) where owner_id is not null;
create table taskfold_private.team_members (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 role text not null check(role in('admin','member','guest')),
 joined_at timestamptz not null default clock_timestamp(),
 primary key(team_id,user_id)
);
create index team_members_user on taskfold_private.team_members(user_id,team_id);
-- Ownership cannot silently lose its accepted member, even through Auth deletion.
alter table taskfold_private.teams add constraint team_owner_is_member
 foreign key(id,owner_id) references taskfold_private.team_members(team_id,user_id)
 deferrable initially deferred;
create table taskfold_private.team_invitations (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 email text not null check(char_length(email) between 3 and 254 and email !~ '[[:cntrl:]]' and position('@' in email)>1),
 role text not null check(role in('admin','member','guest')),
 invited_by uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(),
 expires_at timestamptz not null default (clock_timestamp()+interval '7 days')
);
create unique index team_invitations_team_email on taskfold_private.team_invitations(team_id,email);
create index team_invitations_email on taskfold_private.team_invitations(email,expires_at,id);
create index team_invitations_issuer on taskfold_private.team_invitations(invited_by);
create table taskfold_private.team_transfers (
 team_id uuid primary key references taskfold_private.teams(id) on delete cascade,
 id uuid not null unique default gen_random_uuid(),
 proposed_by uuid not null references auth.users(id) on delete cascade,
 target_id uuid not null,
 expires_at timestamptz not null default (clock_timestamp()+interval '1 day'),
 foreign key(team_id,target_id) references taskfold_private.team_members(team_id,user_id) on delete cascade
);
create index team_transfers_issuer on taskfold_private.team_transfers(proposed_by);
create index team_transfers_target on taskfold_private.team_transfers(team_id,target_id);
create table taskfold_private.team_folders (
 id uuid primary key default gen_random_uuid(),
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 name text not null check(char_length(name) between 1 and 100 and octet_length(name)<=400 and name !~ '[[:cntrl:]]'),
 position integer not null default 0 check(position between 0 and 1000000)
);
create index team_folders_team on taskfold_private.team_folders(team_id,position,id);
create table taskfold_private.team_commands (
 team_id uuid not null references taskfold_private.teams(id) on delete cascade,
 request_id uuid not null,
 actor_id uuid not null references auth.users(id) on delete cascade,
 fingerprint text not null,
 result jsonb not null,
 created_at timestamptz not null default clock_timestamp(),
 primary key(team_id,request_id)
);
create index team_commands_actor on taskfold_private.team_commands(actor_id);
create index team_commands_expiry on taskfold_private.team_commands(team_id,created_at);
create table taskfold_private.team_creation_usage (
 user_id uuid primary key references auth.users(id) on delete cascade,
 usage_day date not null,
 requests integer not null check(requests between 0 and 20)
);

do $$declare n text;begin
 foreach n in array array['team_config','teams','team_members','team_invitations','team_transfers','team_folders','team_commands','team_creation_usage'] loop
  execute format('alter table taskfold_private.%I enable row level security',n);
  execute format('revoke all on taskfold_private.%I from public,anon,authenticated,service_role',n);
 end loop;
end$$;

create function taskfold_private.team_fields(b jsonb, required text[], optional text[] default '{}') returns void
language plpgsql immutable security invoker set search_path='' as $$
begin
 if b is null or jsonb_typeof(b)<>'object' or octet_length(b::text)>16384
 or not b ?& required or exists(select 1 from jsonb_object_keys(b) k where not(k=any(required||optional))) then
  raise exception using errcode='22023',message='Invalid team request';end if;
end$$;
create function taskfold_private.team_uuid(b jsonb,k text) returns uuid
language plpgsql immutable security invoker set search_path='' as $$
begin
 if jsonb_typeof(b->k) is distinct from 'string' or (b->>k) !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 or (b->>k)::uuid='00000000-0000-0000-0000-000000000000'::uuid then
 raise exception using errcode='22023',message='Invalid team identifier';end if;
 return (b->>k)::uuid;
end$$;
create function taskfold_private.team_name(b jsonb) returns text
language plpgsql immutable security invoker set search_path='' as $$
declare n text:=btrim(b->>'name');begin
 if jsonb_typeof(b->'name') is distinct from 'string' or char_length(n) not between 1 and 100 or octet_length(n)>400 or n ~ '[[:cntrl:]]' then
 raise exception using errcode='22023',message='Choose a team or folder name';end if;return n;
end$$;
create function taskfold_private.team_role(t uuid,a uuid) returns text
language sql stable security invoker set search_path='' as $$
 select case when x.owner_id=a then 'owner' else m.role end
 from taskfold_private.teams x join taskfold_private.team_members m on m.team_id=x.id and m.user_id=a
 where x.id=t and x.state<>'deleted'
$$;
create function taskfold_private.team_actor() returns text
language plpgsql volatile security invoker set search_path='' as $$
declare a uuid:=auth.uid(); sid text:=auth.jwt()->>'session_id'; mail text;begin
 if a is null or sid is null or sid !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
  raise exception using errcode='28000',message='Sign in again';end if;
 select lower(btrim(u.email)) into mail from auth.users u join auth.sessions s on s.user_id=u.id
 where u.id=a and s.id=sid::uuid and (s.not_after is null or s.not_after>clock_timestamp())
 and (u.banned_until is null or u.banned_until<=clock_timestamp()) and u.email_confirmed_at is not null and coalesce(u.email,'')<>''
 for share of u,s;
 if not found or exists(select 1 from taskfold_private.account_removal_receipts where account_id=a and created_at>clock_timestamp()-interval '7 days') then
  raise exception using errcode='28000',message='Account access is unavailable';end if;
 return mail;
end$$;

create function taskfold_private.team_manage(action text,b jsonb) returns jsonb
language plpgsql volatile security definer set search_path='' set lock_timeout='3s' as $$
declare a uuid:=auth.uid(); mail text; t uuid; q uuid; expected bigint; issued timestamptz; fingerprint text; prior taskfold_private.team_commands;
 x taskfold_private.teams; r text; target uuid; target_role text; n text; item uuid; inv taskfold_private.team_invitations; transfer taskfold_private.team_transfers;
 result jsonb; today date:=(clock_timestamp() at time zone 'UTC')::date; enabled boolean; count_rows integer;
begin
 mail=taskfold_private.team_actor();
 perform pg_advisory_xact_lock(hashtextextended('team-account:'||a::text,51711));
 mail=taskfold_private.team_actor();
 select c.enabled into enabled from taskfold_private.team_config c where singleton;
 if action='list' then
  perform taskfold_private.team_fields(b,'{}');
  return jsonb_build_object('enabled',enabled,'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',z.id,'name',z.name,'state',z.state,'revision',z.revision,'role',case when z.owner_id=a then 'owner' else m.role end) order by z.created_at,z.id),'[]')
   from taskfold_private.team_members m join taskfold_private.teams z on z.id=m.team_id where m.user_id=a and z.state<>'deleted'));
 elsif action='invitations' then
  perform taskfold_private.team_fields(b,'{}');
  return jsonb_build_object('enabled',enabled,'invitations',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'team_id',z.id,'team_name',z.name,'role',i.role,'expires_at',i.expires_at,'team_revision',z.revision) order by i.created_at,i.id),'[]')
   from taskfold_private.team_invitations i join taskfold_private.teams z on z.id=i.team_id where i.email=mail and i.expires_at>clock_timestamp() and z.state='active'));
 end if;
 if action='get' then perform taskfold_private.team_fields(b,array['team_id']);
 elsif action='create' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','name']);
 elsif action in('rename','folder_create') then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','name']);
 elsif action='folder_rename' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','folder_id','name']);
 elsif action='folder_remove' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','folder_id']);
 elsif action='invite' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','email','role']);
 elsif action in('revoke_invitation','accept_invitation','decline_invitation') then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','invitation_id']);
 elsif action='change_role' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','user_id','role']);
 elsif action in('remove_member','transfer_offer') then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','user_id']);
 elsif action='transfer_accept' then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision','transfer_id']);
 elsif action in('archive','unarchive','delete','leave','transfer_cancel') then perform taskfold_private.team_fields(b,array['team_id','request_id','issued_at','revision']);
 else raise exception using errcode='22023',message='Unsupported team action';end if;
 if not coalesce(enabled,false) and action not in('get','delete','leave','remove_member','revoke_invitation','decline_invitation','transfer_offer','transfer_accept','transfer_cancel') then
  raise exception using errcode='PT503',message='Team setup is not enabled';end if;
 t=taskfold_private.team_uuid(b,'team_id');
 if action<>'get' then
  q=taskfold_private.team_uuid(b,'request_id');
  if jsonb_typeof(b->'issued_at') is distinct from 'string' or (b->>'issued_at') !~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$' then raise exception using errcode='22023',message='Review the team request again';end if;
  begin issued=(b->>'issued_at')::timestamptz;exception when others then raise exception using errcode='22023',message='Review the team request again';end;
  if issued<clock_timestamp()-interval '15 minutes' or issued>clock_timestamp()+interval '1 minute' then raise exception using errcode='PT409',message='Review the team request again';end if;
  fingerprint=encode(extensions.digest(convert_to(jsonb_build_array(action,b)::text,'UTF8'),'sha256'),'hex');
 end if;
 perform pg_advisory_xact_lock(hashtextextended('team:'||t::text,51712));
 -- A queued request cannot retain an expired session/old email while waiting.
 mail=taskfold_private.team_actor();
 today=(clock_timestamp() at time zone 'UTC')::date;
 if action<>'get' and (issued<clock_timestamp()-interval '15 minutes' or issued>clock_timestamp()+interval '1 minute') then raise exception using errcode='PT409',message='Review the team request again';end if;
 select * into x from taskfold_private.teams where id=t for update;
 if action='create' then
  if found then
   if x.owner_id=a and x.state<>'deleted' then
    select * into prior from taskfold_private.team_commands where team_id=t and request_id=q;
    if found and prior.actor_id=a and prior.fingerprint=fingerprint then return prior.result;end if;
   end if;
   raise exception using errcode='PT409',message='Team request is unavailable';
  end if;
  n=taskfold_private.team_name(b);
  if (select count(*) from taskfold_private.teams where owner_id=a and state<>'deleted')>=20 or (select count(*) from taskfold_private.team_members where user_id=a)>=100 then raise exception using errcode='54000',message='Team limit reached';end if;
  insert into taskfold_private.team_creation_usage values(a,today,1) on conflict(user_id) do update set
   requests=case when team_creation_usage.usage_day=excluded.usage_day then team_creation_usage.requests+1 else 1 end,usage_day=excluded.usage_day
   where team_creation_usage.usage_day<>excluded.usage_day or team_creation_usage.requests<20;
  if not found then raise exception using errcode='PT429',message='Try team setup another day';end if;
  insert into taskfold_private.teams(id,owner_id,name,day_operations) values(t,a,n,1) returning * into x;
  insert into taskfold_private.team_members(team_id,user_id,role) values(t,a,'admin');
  result=jsonb_build_object('id',t,'revision',x.revision,'state',x.state);
 else
  if not found then raise exception using errcode='PT404',message='Team is unavailable';end if;
  r=taskfold_private.team_role(t,a);
  if x.state='deleted' then
   select * into prior from taskfold_private.team_commands where team_id=t and request_id=q and actor_id=a;
   if action='delete' and found and prior.fingerprint=fingerprint then return prior.result;end if;
   raise exception using errcode='PT404',message='Team is unavailable';
  end if;
  if r is null and action in('accept_invitation','decline_invitation') then
   item=taskfold_private.team_uuid(b,'invitation_id');
   select * into inv from taskfold_private.team_invitations where id=item and team_id=t and email=mail and expires_at>clock_timestamp() for update;
   if not found then raise exception using errcode='PT404',message='Team invitation is unavailable';end if;
  elsif r is null then raise exception using errcode='PT404',message='Team is unavailable';end if;
  if action='get' then
   result=jsonb_build_object('id',t,'name',x.name,'state',x.state,'revision',x.revision,'role',r);
   if r<>'guest' then
    result=result||jsonb_build_object('folders',(select coalesce(jsonb_agg(jsonb_build_object('id',f.id,'name',f.name,'position',f.position) order by f.position,f.id),'[]') from taskfold_private.team_folders f where f.team_id=t));
   end if;
   if r in('owner','admin') then
    result=result||jsonb_build_object('members',(select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'role',case when m.user_id=x.owner_id then 'owner' else m.role end) order by m.joined_at,m.user_id),'[]') from taskfold_private.team_members m where m.team_id=t),
     'invitations',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'expires_at',i.expires_at) order by i.created_at,i.id),'[]') from taskfold_private.team_invitations i where i.team_id=t and i.expires_at>clock_timestamp()));
   end if;
   if r='owner' or exists(select 1 from taskfold_private.team_transfers where team_id=t and target_id=a) then result=result||jsonb_build_object('transfer',(select jsonb_build_object('id',v.id,'target_id',v.target_id,'expires_at',v.expires_at) from taskfold_private.team_transfers v where v.team_id=t));end if;
   return result;
  end if;
  if action in('delete','archive','unarchive','transfer_offer','transfer_cancel') and r is distinct from 'owner' then raise exception using errcode='42501',message='Only the team owner can do this';end if;
  if action in('rename','folder_create','folder_rename','folder_remove','invite','revoke_invitation','change_role','remove_member') and coalesce(r,'') not in('owner','admin') then raise exception using errcode='42501',message='Team administration is required';end if;
  select * into prior from taskfold_private.team_commands where team_id=t and request_id=q;
  if found then
   if prior.actor_id=a and prior.fingerprint=fingerprint then return prior.result;end if;
   raise exception using errcode='PT409',message='Team request changed';end if;
  if jsonb_typeof(b->'revision') is distinct from 'number' or (b->>'revision')::numeric not between 1 and 9007199254740990 or (b->>'revision')::numeric<>trunc((b->>'revision')::numeric) then raise exception using errcode='22023',message='Invalid team review';end if;
  expected=(b->>'revision')::numeric::bigint;
  if expected<>x.revision then raise exception using errcode='PT409',message='Team changed; review it again';end if;
  if x.state='archived' and action not in('unarchive','delete','leave','remove_member','revoke_invitation','decline_invitation','transfer_offer','transfer_accept','transfer_cancel') then raise exception using errcode='PT409',message='Unarchive this team first';end if;
  if x.usage_day=today and x.day_operations>=2000 and action not in('delete','leave','remove_member','revoke_invitation','decline_invitation','transfer_offer','transfer_accept','transfer_cancel') then raise exception using errcode='PT429',message='Team administration is busy; try another day';end if;
  if action='rename' then update taskfold_private.teams set name=taskfold_private.team_name(b) where id=t;
  elsif action='archive' then update taskfold_private.teams set state='archived' where id=t;
  elsif action='unarchive' then update taskfold_private.teams set state='active' where id=t;
  elsif action='delete' then
   update taskfold_private.teams set state='deleted',name=null,owner_id=null where id=t;
   delete from taskfold_private.team_members where team_id=t;
   delete from taskfold_private.team_invitations where team_id=t;
   delete from taskfold_private.team_transfers where team_id=t;
   delete from taskfold_private.team_folders where team_id=t;
   delete from taskfold_private.team_commands where team_id=t;
  elsif action='invite' then
   if jsonb_typeof(b->'email') is distinct from 'string' or jsonb_typeof(b->'role') is distinct from 'string' then raise exception using errcode='22023',message='Invalid team invitation';end if;
   n=lower(btrim(b->>'email'));target_role=b->>'role';
   if char_length(n) not between 3 and 254 or position('@' in n)<2 or n ~ '[[:cntrl:]]' or target_role not in('admin','member','guest') then raise exception using errcode='22023',message='Invalid team invitation';end if;
   if target_role='admin' and r<>'owner' then raise exception using errcode='42501',message='Only the owner can appoint an admin';end if;
   if n=mail then raise exception using errcode='22023',message='You already belong to this team';end if;
   perform pg_advisory_xact_lock(hashtextextended('team-invite:'||n,51713));
   delete from taskfold_private.team_invitations where team_id=t and expires_at<=clock_timestamp();
   if (select count(*) from taskfold_private.team_invitations where team_id=t)>=100 or (select count(*) from taskfold_private.team_invitations where email=n and expires_at>clock_timestamp())>=100 then raise exception using errcode='54000',message='Invitation limit reached';end if;
   if exists(select 1 from taskfold_private.team_invitations where team_id=t and email=n) then raise exception using errcode='PT409',message='An invitation already exists';end if;
   insert into taskfold_private.team_invitations(team_id,email,role,invited_by) values(t,n,target_role,a) returning id into item;
   result=jsonb_build_object('invitation_id',item);
  elsif action in('revoke_invitation','decline_invitation','accept_invitation') then
   item=taskfold_private.team_uuid(b,'invitation_id');
   select * into inv from taskfold_private.team_invitations where id=item and team_id=t for update;
   if not found or (action in('decline_invitation','accept_invitation') and (inv.email<>mail or inv.expires_at<=clock_timestamp())) then raise exception using errcode='PT404',message='Team invitation is unavailable';end if;
   if action='revoke_invitation' and r='admin' and inv.role='admin' then raise exception using errcode='42501',message='Only the owner can manage admin invitations';end if;
   if action='accept_invitation' then
    target_role=taskfold_private.team_role(t,inv.invited_by);
    if coalesce(target_role,'') not in('owner','admin') or (inv.role='admin' and target_role<>'owner')
     or not exists(select 1 from auth.users where id=inv.invited_by and (banned_until is null or banned_until<=clock_timestamp())) then raise exception using errcode='PT404',message='Team invitation is unavailable';end if;
    if r is not null then raise exception using errcode='PT409',message='You already belong to this team';end if;
    if (select count(*) from taskfold_private.team_members where team_id=t)>=500 or (select count(*) from taskfold_private.team_members where user_id=a)>=100 then raise exception using errcode='54000',message='Team membership limit reached';end if;
    insert into taskfold_private.team_members(team_id,user_id,role) values(t,a,inv.role);
   end if;
   delete from taskfold_private.team_invitations where id=item;
  elsif action in('change_role','remove_member','leave') then
   target=case when action='leave' then a else taskfold_private.team_uuid(b,'user_id') end;
   if target=x.owner_id then raise exception using errcode='PT409',message='Transfer ownership before leaving';end if;
   select m.role into target_role from taskfold_private.team_members m where team_id=t and user_id=target;
   if not found then raise exception using errcode='PT404',message='Team member is unavailable';end if;
   if action<>'leave' and r='admin' and target_role='admin' then raise exception using errcode='42501',message='Only the owner can manage admins';end if;
   if action='change_role' then
    if jsonb_typeof(b->'role') is distinct from 'string' or b->>'role' not in('admin','member','guest') then raise exception using errcode='22023',message='Invalid team role';end if;
    if b->>'role'='admin' and r<>'owner' then raise exception using errcode='42501',message='Only the owner can appoint admins';end if;
    update taskfold_private.team_members set role=b->>'role' where team_id=t and user_id=target;
   else delete from taskfold_private.team_members where team_id=t and user_id=target;end if;
   delete from taskfold_private.team_invitations where team_id=t and invited_by=target;
   delete from taskfold_private.team_transfers where team_id=t and (target_id=target or proposed_by=target);
  elsif action='transfer_offer' then
   target=taskfold_private.team_uuid(b,'user_id');
   if target=a or coalesce(taskfold_private.team_role(t,target),'') not in('admin','member') then raise exception using errcode='22023',message='Choose an accepted team member';end if;
   insert into taskfold_private.team_transfers(team_id,proposed_by,target_id) values(t,a,target) on conflict(team_id) do update set id=gen_random_uuid(),proposed_by=a,target_id=target,expires_at=clock_timestamp()+interval '1 day' returning id into item;
   result=jsonb_build_object('transfer_id',item);
  elsif action='transfer_accept' then
   item=taskfold_private.team_uuid(b,'transfer_id');
   select * into transfer from taskfold_private.team_transfers where team_id=t and id=item and target_id=a and expires_at>clock_timestamp() for update;
   if not found or transfer.proposed_by<>x.owner_id or coalesce(r,'') not in('admin','member') then raise exception using errcode='PT404',message='Ownership review is unavailable';end if;
   if (select count(*) from taskfold_private.teams where owner_id=a and state<>'deleted')>=20 then raise exception using errcode='54000',message='Team ownership limit reached';end if;
   update taskfold_private.team_members set role='admin' where team_id=t and user_id=a;
   update taskfold_private.teams set owner_id=a where id=t;
   delete from taskfold_private.team_invitations where team_id=t;
   delete from taskfold_private.team_transfers where team_id=t;
  elsif action='transfer_cancel' then delete from taskfold_private.team_transfers where team_id=t;
  elsif action='folder_create' then
   if (select count(*) from taskfold_private.team_folders where team_id=t)>=200 then raise exception using errcode='54000',message='Folder limit reached';end if;
   insert into taskfold_private.team_folders(team_id,name,position) values(t,taskfold_private.team_name(b),(select coalesce(max(position),-1)+1 from taskfold_private.team_folders where team_id=t)) returning id into item;
   result=jsonb_build_object('folder_id',item);
  elsif action='folder_rename' then
   item=taskfold_private.team_uuid(b,'folder_id');update taskfold_private.team_folders set name=taskfold_private.team_name(b) where team_id=t and id=item;
   if not found then raise exception using errcode='PT404',message='Folder is unavailable';end if;
  elsif action='folder_remove' then
   item=taskfold_private.team_uuid(b,'folder_id');delete from taskfold_private.team_folders where team_id=t and id=item;
   if not found then raise exception using errcode='PT404',message='Folder is unavailable';end if;
  end if;
  update taskfold_private.teams set revision=revision+1,updated_at=clock_timestamp(),usage_day=today,
   day_operations=case when usage_day=today then least(day_operations+1,2000) else 1 end where id=t returning * into x;
  result=coalesce(result,'{}'::jsonb)||jsonb_build_object('id',t,'revision',x.revision,'state',x.state);
 end if;
 delete from taskfold_private.team_commands where team_id=t and created_at<clock_timestamp()-interval '1 day';
 insert into taskfold_private.team_commands(team_id,request_id,actor_id,fingerprint,result) values(t,q,a,fingerprint,result);
 return result;
end$$;

create function public.taskfold_teams(_action text,_body jsonb) returns jsonb
language sql volatile security invoker set search_path='' as $$select taskfold_private.team_manage(_action,_body)$$;

create function taskfold_private.team_removal_guard() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from taskfold_private.teams where owner_id=new.account_id and state<>'deleted') then
  raise exception using errcode='PT409',message='Transfer or delete owned teams before removing your account';end if;
 return new;
end$$;
create trigger taskfold_team_removal_guard before insert on taskfold_private.account_removal_receipts for each row execute function taskfold_private.team_removal_guard();

revoke all on function taskfold_private.team_fields(jsonb,text[],text[]),taskfold_private.team_uuid(jsonb,text),taskfold_private.team_name(jsonb),taskfold_private.team_role(uuid,uuid),taskfold_private.team_actor(),taskfold_private.team_manage(text,jsonb),taskfold_private.team_removal_guard(),public.taskfold_teams(text,jsonb) from public,anon,authenticated,service_role;
grant usage on schema taskfold_private to authenticated;
grant execute on function taskfold_private.team_manage(text,jsonb),public.taskfold_teams(text,jsonb) to authenticated;

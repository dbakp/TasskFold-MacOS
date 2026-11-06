-- Authenticated shared conversations are separate from legacy/imported task JSON.
-- No existing comment, task or project is rewritten. No push delivery is enabled.
create table public.task_comments (
 id uuid primary key,
 task_id uuid not null references public.tasks(id) on delete cascade,
 task_generation uuid not null,
 project_id uuid not null references public.projects(id) on delete cascade,
 author_id uuid references auth.users(id) on delete set null,
 body text not null check(octet_length(body)<=16000),
 mention_ids uuid[] not null default '{}',
 revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 created_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 deleted_at timestamptz,
 constraint task_comments_body_state check((deleted_at is null and body !~ '^[[:space:]]*$') or (deleted_at is not null and body='' and cardinality(mention_ids)=0)),
 constraint task_comments_mention_bound check(cardinality(mention_ids)<=25 and array_position(mention_ids,null) is null)
);
create index task_comments_task_created on public.task_comments(task_id,created_at,id);
create index task_comments_project on public.task_comments(project_id);
create index task_comments_author on public.task_comments(author_id) where author_id is not null;
alter table public.task_comments enable row level security;
revoke all on public.task_comments from public,anon,authenticated;
grant select on public.task_comments to authenticated;

create table public.task_mentions (
 id uuid primary key default gen_random_uuid(),
 comment_id uuid not null references public.task_comments(id) on delete cascade,
 recipient_id uuid not null references auth.users(id) on delete cascade,
 created_at timestamptz not null default clock_timestamp(),
 read_at timestamptz,
 revision bigint not null default 1 check(revision between 1 and 9007199254740991),
 unique(comment_id,recipient_id)
);
create index task_mentions_recipient_created on public.task_mentions(recipient_id,created_at,id);
alter table public.task_mentions enable row level security;
revoke all on public.task_mentions from public,anon,authenticated;
grant select on public.task_mentions to authenticated;

-- Only hashes and acknowledged identities/revisions are retained, never an old body.
-- Tombstones prevent delayed retries from resurrecting removed comments.
create table taskfold_private.comment_operations (
 actor_id uuid not null references auth.users(id) on delete cascade,
 operation_id uuid not null,
 kind text not null check(kind in ('comment','mention-read')),
 request_hash bytea not null check(octet_length(request_hash)=32),
 comment_id uuid not null references public.task_comments(id) on delete cascade,
 entity_id uuid not null,
 revision bigint not null check(revision between 1 and 9007199254740991),
 primary key(actor_id,operation_id)
);
create index comment_operations_comment on taskfold_private.comment_operations(comment_id);
alter table taskfold_private.comment_operations enable row level security;
revoke all on taskfold_private.comment_operations from public,anon,authenticated;
create policy no_direct_comment_operations on taskfold_private.comment_operations for all to authenticated using(false) with check(false);

-- Explicit access checks remain correct even when invoked by a scoped definer.
-- Project moves hide the old conversation instead of exposing it in a new project.
create function taskfold_private.can_read_shared_task(_task uuid,_generation uuid,_project uuid)
returns boolean language sql stable security invoker set search_path='' as $$
 select (select auth.uid()) is not null and exists(
  select 1 from public.tasks t where t.id=_task and t.task_generation=_generation and t.project_id=_project
   and public.has_project_access((select auth.uid()),_project)
 )
$$;
revoke all on function taskfold_private.can_read_shared_task(uuid,uuid,uuid) from public,anon;
grant execute on function taskfold_private.can_read_shared_task(uuid,uuid,uuid) to authenticated;
create policy task_comments_read on public.task_comments for select to authenticated
 using(taskfold_private.can_read_shared_task(task_id,task_generation,project_id));
create policy task_mentions_read on public.task_mentions for select to authenticated
 using(recipient_id=(select auth.uid()) and exists(
  select 1 from public.task_comments c where c.id=comment_id and c.deleted_at is null
   and taskfold_private.can_read_shared_task(c.task_id,c.task_generation,c.project_id)
 ));

-- Definer is confined to a non-exposed schema because clients must not write
-- author identities, receipt hashes or another person's mention rows directly.
create function taskfold_private.write_shared_comment(
 _operation_id uuid,_comment_id uuid,_task_id uuid,_task_generation uuid,_project_id uuid,
 _expected_revision bigint,_body text,_mentions uuid[],_delete boolean
) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); p public.projects; t public.tasks; c public.task_comments;
 receipt taskfold_private.comment_operations; people uuid[]; fingerprint bytea;
begin
 if actor is null then raise exception 'Sign in to share a comment.' using errcode='42501';end if;
 if _operation_id is null or _comment_id is null or _task_id is null or _task_generation is null or _project_id is null
  or _expected_revision is null or _expected_revision<0 or _expected_revision>9007199254740991
  or _body is null or _mentions is null or _delete is null or cardinality(_mentions)>25 or array_position(_mentions,null) is not null
  or octet_length(_body)>16000 or (_delete and (_body<>'' or cardinality(_mentions)>0 or _expected_revision=0))
  or (not _delete and _body ~ '^[[:space:]]*$') then
  raise exception 'Choose a valid comment of up to 16000 bytes and 25 people.' using errcode='22023';
 end if;
 people:=array(select distinct person from unnest(_mentions) person order by person);
 fingerprint:=pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_array('comment',_comment_id,_task_id,_task_generation,_project_id,_expected_revision,_body,people,_delete)::text,'UTF8'));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text||_operation_id::text,20261021));
 -- Match account-deletion FK order before holding project/task/comment rows.
 perform 1 from auth.users where id=any(array_append(people,actor)) order by id for key share;
 if not exists(select 1 from auth.users where id=actor) then return jsonb_build_object('status','unavailable');end if;
 -- Lock project/membership before task, matching membership-removal cleanup order.
 select * into p from public.projects where id=_project_id for share;
 if not found or not public.has_project_access(actor,_project_id) then return jsonb_build_object('status','unavailable');end if;
 perform 1 from public.project_collaborators where project_id=_project_id and status='accepted'
  and user_id=any(array_append(people,actor)) order by user_id for share;
 if not public.has_project_access(actor,_project_id) then return jsonb_build_object('status','unavailable');end if;
 select * into t from public.tasks where id=_task_id and task_generation=_task_generation and project_id=_project_id for share;
 if not found then return jsonb_build_object('status','unavailable');end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(_comment_id::text,20261022));
 select * into c from public.task_comments where id=_comment_id for update;
 if found and (c.task_id<>_task_id or c.task_generation<>_task_generation or c.project_id<>_project_id) then
  return jsonb_build_object('status','unavailable');
 end if;
 select * into receipt from taskfold_private.comment_operations where actor_id=actor and operation_id=_operation_id;
 if found then
  if receipt.kind<>'comment' or receipt.request_hash<>fingerprint then
   raise exception 'This attempt differs from the acknowledged change. Send a fresh change.' using errcode='22023';
  end if;
  return jsonb_build_object('status','saved','operation_id',_operation_id,'acknowledged_revision',receipt.revision,'current',to_jsonb(c));
 end if;
 if p.is_archived or p.ancestor_archived then return jsonb_build_object('status','archived');end if;
 if exists(select 1 from unnest(people) person where not public.has_project_access(person,_project_id)) then
  return jsonb_build_object('status','recipients_changed');
 end if;
 if c.id is null then
  if _expected_revision<>0 then return jsonb_build_object('status','unavailable');end if;
  insert into public.task_comments(id,task_id,task_generation,project_id,author_id,body,mention_ids)
   values(_comment_id,_task_id,_task_generation,_project_id,actor,_body,people) returning * into c;
 else
  if c.author_id is distinct from actor and not (_delete and p.user_id=actor) then return jsonb_build_object('status','forbidden');end if;
  if c.revision<>_expected_revision then return jsonb_build_object('status','conflict','current',to_jsonb(c));end if;
  if c.deleted_at is not null then
   if not _delete then return jsonb_build_object('status','unavailable');end if;
  else
   if c.revision>=9007199254740991 then raise exception 'This conversation needs an update before editing.' using errcode='22023';end if;
   update public.task_comments set body=case when _delete then '' else _body end,
    mention_ids=case when _delete then '{}'::uuid[] else people end,revision=revision+1,
    updated_at=clock_timestamp(),deleted_at=case when _delete then clock_timestamp() else null end
    where id=_comment_id returning * into c;
  end if;
 end if;
 delete from public.task_mentions where comment_id=c.id and not recipient_id=any(c.mention_ids);
 insert into public.task_mentions(comment_id,recipient_id)
  select c.id,person from unnest(c.mention_ids) person on conflict(comment_id,recipient_id) do nothing;
 insert into taskfold_private.comment_operations(actor_id,operation_id,kind,request_hash,comment_id,entity_id,revision)
  values(actor,_operation_id,'comment',fingerprint,c.id,c.id,c.revision);
 return jsonb_build_object('status','saved','operation_id',_operation_id,'acknowledged_revision',c.revision,'current',to_jsonb(c));
end $$;
revoke all on function taskfold_private.write_shared_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean) from public,anon;
grant execute on function taskfold_private.write_shared_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean) to authenticated;
create function public.taskfold_write_comment(
 _operation_id uuid,_comment_id uuid,_task_id uuid,_task_generation uuid,_project_id uuid,
 _expected_revision bigint,_body text,_mentions uuid[] default '{}',_delete boolean default false
) returns jsonb language sql security invoker set search_path='' as $$
 select taskfold_private.write_shared_comment(_operation_id,_comment_id,_task_id,_task_generation,_project_id,_expected_revision,_body,_mentions,_delete)
$$;
revoke all on function public.taskfold_write_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean) from public,anon;
grant execute on function public.taskfold_write_comment(uuid,uuid,uuid,uuid,uuid,bigint,text,uuid[],boolean) to authenticated;

create function taskfold_private.mark_shared_mention(_operation_id uuid,_mention_id uuid,_expected_revision bigint,_read boolean)
returns jsonb language plpgsql security definer set search_path='' as $$
declare actor uuid:=(select auth.uid()); m public.task_mentions; fingerprint bytea;receipt taskfold_private.comment_operations;
begin
 if actor is null then raise exception 'Sign in to view your mentions.' using errcode='42501';end if;
 if _operation_id is null or _mention_id is null or _expected_revision is null or _expected_revision<1
  or _expected_revision>9007199254740991 or _read is null then raise exception 'Choose a valid mention change.' using errcode='22023';end if;
 fingerprint:=pg_catalog.sha256(pg_catalog.convert_to(jsonb_build_array('mention-read',_mention_id,_expected_revision,_read)::text,'UTF8'));
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(actor::text||_operation_id::text,20261021));
 perform 1 from auth.users where id=actor for key share;
 if not found then return jsonb_build_object('status','unavailable');end if;
 -- Comment before mention matches comment editing/deletion, avoiding FK lock inversion.
 perform 1 from public.task_comments c join public.task_mentions n on n.comment_id=c.id
  where n.id=_mention_id and n.recipient_id=actor and c.deleted_at is null
   and taskfold_private.can_read_shared_task(c.task_id,c.task_generation,c.project_id) for share of c;
 if not found then return jsonb_build_object('status','unavailable');end if;
 select * into m from public.task_mentions n where n.id=_mention_id and n.recipient_id=actor and exists(
  select 1 from public.task_comments c where c.id=n.comment_id and c.deleted_at is null
   and taskfold_private.can_read_shared_task(c.task_id,c.task_generation,c.project_id)
 ) for update;
 if not found then return jsonb_build_object('status','unavailable');end if;
 select * into receipt from taskfold_private.comment_operations where actor_id=actor and operation_id=_operation_id;
 if found then
  if receipt.kind<>'mention-read' or receipt.request_hash<>fingerprint then
   raise exception 'This attempt differs from the acknowledged change. Send a fresh change.' using errcode='22023';
  end if;
  return jsonb_build_object('status','saved','operation_id',_operation_id,'acknowledged_revision',receipt.revision,'current',to_jsonb(m));
 end if;
 if m.revision<>_expected_revision then return jsonb_build_object('status','conflict','current',to_jsonb(m));end if;
 if (m.read_at is not null)<>_read then
  if m.revision>=9007199254740991 then raise exception 'This mention needs an update before editing.' using errcode='22023';end if;
  update public.task_mentions set read_at=case when _read then clock_timestamp() else null end,revision=revision+1
   where id=m.id returning * into m;
 end if;
 insert into taskfold_private.comment_operations(actor_id,operation_id,kind,request_hash,comment_id,entity_id,revision)
  values(actor,_operation_id,'mention-read',fingerprint,m.comment_id,m.id,m.revision);
 return jsonb_build_object('status','saved','operation_id',_operation_id,'acknowledged_revision',m.revision,'current',to_jsonb(m));
end $$;
revoke all on function taskfold_private.mark_shared_mention(uuid,uuid,bigint,boolean) from public,anon;
grant execute on function taskfold_private.mark_shared_mention(uuid,uuid,bigint,boolean) to authenticated;
create function public.taskfold_mark_mention(_operation_id uuid,_mention_id uuid,_expected_revision bigint,_read boolean)
returns jsonb language sql security invoker set search_path='' as $$
 select taskfold_private.mark_shared_mention(_operation_id,_mention_id,_expected_revision,_read)
$$;
revoke all on function public.taskfold_mark_mention(uuid,uuid,bigint,boolean) from public,anon;
grant execute on function public.taskfold_mark_mention(uuid,uuid,bigint,boolean) to authenticated;

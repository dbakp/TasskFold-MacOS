-- A complete native drag is one transaction. Exact retries never replay an older order.
create table taskfold_private.organization_order_actions (
 user_id uuid not null references auth.users(id) on delete cascade,
 action_id uuid not null,
 command jsonb not null,
 created_at timestamptz not null default now(),
 primary key(user_id,action_id)
);
alter table taskfold_private.organization_order_actions enable row level security;
create policy account_owner on taskfold_private.organization_order_actions for select to authenticated
 using(user_id=(select auth.uid()));
create policy account_insert on taskfold_private.organization_order_actions for insert to authenticated
 with check(user_id=(select auth.uid()));
revoke all on taskfold_private.organization_order_actions from public,anon,authenticated;
grant select,insert on taskfold_private.organization_order_actions to authenticated;
grant all on taskfold_private.organization_order_actions to service_role;

create function public.taskfold_order_organization(_table text,_ids text[],_project text,_action uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare owner uuid:=auth.uid(); payload jsonb; previous jsonb; inserted integer;
 scoped text; locked record; available text[]; complete text[]; result jsonb;
begin
 if owner is null then raise exception 'Sign in before rearranging items.'; end if;
 if _table is null or _table not in ('projects','sections','saved_views','favorites')
  or _action is null or _ids is null or cardinality(_ids) not between 1 and 10000
  or exists(select 1 from unnest(_ids) id where id is null or length(id) not between 1 and 512)
  or cardinality(_ids)<>(select count(distinct id) from unnest(_ids) id)
  or (_table='sections' and (_project is null or _project=''))
  or (_table<>'sections' and _project is not null) then
  raise exception 'Invalid complete ordering command.';
 end if;
 if _table='sections' then perform _project::uuid; end if;
 payload:=jsonb_build_object('table',_table,'ids',to_jsonb(_ids),'project',_project);
 insert into taskfold_private.organization_order_actions(user_id,action_id,command)
  values(owner,_action,payload) on conflict(user_id,action_id) do nothing;
 get diagnostics inserted=row_count;
 if inserted=0 then
  select command into previous from taskfold_private.organization_order_actions where user_id=owner and action_id=_action;
  if previous is distinct from payload then raise exception 'Ordering retry identity was reused for a different move.'; end if;
 else
  scoped:=case when _table='sections' then 'project_id::text=$1' else 'true' end;
  -- RLS stays active. Lock every visible row in deterministic ID order before changing any index.
  for locked in execute format('select id from public.%I where %s order by id for update',_table,scoped) using _project loop end loop;
  execute format('select coalesce(array_agg(id::text order by order_index,id),array[]::text[]) from public.%I where %s',_table,scoped)
   into available using _project;
  -- A deleted item stays deleted. Newly visible additions retain relative order after the requested list.
  select coalesce(array_agg(id order by position),array[]::text[]) into complete
   from unnest(_ids) with ordinality as requested(id,position) where id=any(available);
  complete:=complete || array(select id from unnest(available) id where not(id=any(_ids)));
  execute format('update public.%I as target set order_index=ordered.position::integer-1 from unnest($1::text[]) with ordinality as ordered(id,position) where target.id::text=ordered.id and target.order_index is distinct from ordered.position::integer-1',_table)
   using complete;
 end if;
 -- Return the whole readable table, including sections outside this drag's project.
 execute format('select coalesce(jsonb_agg(to_jsonb(item)),''[]''::jsonb) from public.%I item',_table) into result;
 return result;
end $$;
revoke all on function public.taskfold_order_organization(text,text[],text,uuid) from public,anon;
grant execute on function public.taskfold_order_organization(text,text[],text,uuid) to authenticated,service_role;

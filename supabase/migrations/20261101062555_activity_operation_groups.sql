-- Display-only correlation for rows committed in the same server transaction.
-- Old rows stay ungrouped. No RPCs, grants, values or timestamp heuristics.
lock table auth.users in share row exclusive mode;
lock table public.tasks in share row exclusive mode;
alter table public.task_activity add column operation_context jsonb check(operation_context is null or (
 jsonb_typeof(operation_context)='object' and operation_context ?& array['version','origin','id'] and operation_context->'version'='1'::jsonb
 and operation_context->>'origin'='server_transaction'
 and jsonb_typeof(operation_context->'id')='string'
 and operation_context->>'id'~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 and operation_context-array['version','origin','id']='{}'::jsonb));
alter table public.task_node_activity add column operation_context jsonb check(operation_context is null or (
 jsonb_typeof(operation_context)='object' and operation_context ?& array['version','origin','id'] and operation_context->'version'='1'::jsonb
 and operation_context->>'origin'='server_transaction'
 and jsonb_typeof(operation_context->'id')='string'
 and operation_context->>'id'~'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
 and operation_context-array['version','origin','id']='{}'::jsonb));
create function taskfold_private.tag_activity_operation()
returns trigger language plpgsql security invoker set search_path='' as $$
begin
 if tg_table_schema<>'public' or tg_table_name not in('task_activity','task_node_activity') then raise exception 'Invalid activity source';end if;
 new.operation_context:=null;
 if auth.uid() is not null and new.actor_id=auth.uid() then
  -- This UUID is correlation, never authority or a credential. Database name,
  -- server incarnation and the epoch-extended transaction ID namespace it across
  -- restarts/restores. Epoch extraction is independent of session timezone.
  new.operation_context:=jsonb_build_object('version',1,'origin','server_transaction','id',
   md5(jsonb_build_array(current_database(),extract(epoch from pg_postmaster_start_time())::text,txid_current()::text)::text)::uuid);
 end if;
 return new;
end $$;
create trigger task_activity_operation before insert on public.task_activity for each row execute function taskfold_private.tag_activity_operation();
create trigger task_node_activity_operation before insert on public.task_node_activity for each row execute function taskfold_private.tag_activity_operation();
revoke all on function taskfold_private.tag_activity_operation() from public,anon,authenticated,service_role;

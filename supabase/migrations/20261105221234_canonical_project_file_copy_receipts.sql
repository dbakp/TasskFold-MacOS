-- Applied atomically: the Supabase CLI does not wrap migrations in a transaction.
begin;

-- Keep reused file-ledger receipts compatible with their immutable intent.
-- Reference aliases remain intact through replace_project_file_reference.
do $$declare d text;anchor text:=$anchor$'name',j.label,'size',j.byte_count$anchor$;begin
 d:=pg_get_functiondef('taskfold_private.finish_project_adoption_files(uuid,uuid[],jsonb,jsonb)'::regprocedure);
 if cardinality(string_to_array(d,anchor))<>2 then raise exception 'Current prepared file attachment required';end if;
 execute replace(d,anchor,$replacement$'name',(select u.intent->>'name' from taskfold_private.task_file_uploads u where u.operation_id=j.operation_id),'size',j.byte_count$replacement$);
end$$;
notify pgrst,'reload schema';

commit;

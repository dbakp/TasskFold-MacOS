begin;
do $$
declare key_id uuid; old_key jsonb; a uuid='f084cafe-0000-4000-8000-000000000001'; b uuid='f084cafe-0000-4000-8000-000000000002'; r text;
begin
 foreach r in array array['anon','authenticated'] loop
  if has_table_privilege(r,'taskfold_private.account_removal_proof_keys','select')
   or has_function_privilege(r,'public.taskfold_account_removal_proof_key(uuid)','execute')
   or has_function_privilege(r,'public.taskfold_account_removal_absent(uuid)','execute')
   or has_function_privilege(r,'taskfold_private.account_removal_proof_key(uuid)','execute')
   or has_function_privilege(r,'taskfold_private.account_removal_absent(uuid)','execute') then raise exception 'Client can access private proof material/status'; end if;
 end loop;
 old_key=public.taskfold_account_removal_proof_key(null);key_id=(old_key->>'id')::uuid;
 if octet_length(decode(old_key->>'key','base64'))<>32 then raise exception 'Invalid signing material';end if;
 update taskfold_private.account_removal_proof_keys set active=false where id=key_id;
 insert into taskfold_private.account_removal_proof_keys(secret) values(extensions.gen_random_bytes(32));
 if public.taskfold_account_removal_proof_key(key_id)<>old_key or public.taskfold_account_removal_proof_key(null)=old_key then raise exception 'Rotation discarded retained proof key';end if;
 update taskfold_private.account_removal_proof_keys set revoked_at=clock_timestamp() where id=key_id;
 if public.taskfold_account_removal_proof_key(key_id) is not null then raise exception 'Revoked key remains usable';end if;
 if public.taskfold_account_removal_absent(null) or not public.taskfold_account_removal_absent(a) then raise exception 'Invalid absent account result';end if;
 insert into auth.users(id) values(a);
 if public.taskfold_account_removal_absent(a) then raise exception 'Existing account confirmed absent';end if;
 delete from auth.users where id=a;
 insert into storage.objects(bucket_id,name,owner_id) values('custom','outside-path',a::text);
 if public.taskfold_account_removal_absent(a) then raise exception 'Canonical file ownership ignored';end if;
 delete from storage.objects;
 insert into storage.objects(bucket_id,name) values('avatars',a::text||'/legacy');
 if public.taskfold_account_removal_absent(a) then raise exception 'Legacy file ignored';end if;
 update storage.objects set owner_id=b::text;
 if not public.taskfold_account_removal_absent(a) then raise exception 'Foreign canonical owner overridden';end if;
 delete from storage.objects;
 insert into storage.objects(bucket_id,name,owner) values('task-attachments','different-path',a);
 if public.taskfold_account_removal_absent(a) then raise exception 'Canonical UUID owner ignored';end if;
end$$;
set local role service_role;
do $$begin
 if public.taskfold_account_removal_proof_key(null) is null then raise exception 'Service cannot obtain active key';end if;
 if public.taskfold_account_removal_absent('f084cafe-0000-4000-8000-000000000001') then raise exception 'Service ignored residual file';end if;
end$$;
reset role;
rollback;

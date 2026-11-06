-- Administrator-only, read-only manifests for files left after Auth removal.
-- Normal deletion/status proofs gain no new authority. Never delete Storage metadata here.
create function taskfold_private.account_removal_repair_manifest(_account uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare files jsonb;
begin
 if _account is null then raise exception 'Choose a removed account' using errcode='22023'; end if;
 if exists(select 1 from auth.users where id=_account) then
  raise exception 'An existing account cannot use residual-file repair' using errcode='28000';
 end if;
 select coalesce(jsonb_agg(row order by bucket,name,id),'[]'::jsonb) into files from (
  select o.id,o.bucket_id as bucket,o.name,
   encode(extensions.digest(to_jsonb(o)::text,'sha256'),'hex') as stamp
  from storage.objects o
  where coalesce(o.owner_id,o.owner::text)=_account::text
   or (o.owner_id is null and o.owner is null and o.bucket_id in ('avatars','task-attachments')
       and starts_with(o.name,_account::text||'/'))
  order by o.bucket_id,o.name,o.id limit 101
 ) row;
 return jsonb_build_object('account',_account,'files',(
  select coalesce(jsonb_agg(value order by n),'[]'::jsonb)
  from jsonb_array_elements(files) with ordinality a(value,n) where n<=100
 ),'more',jsonb_array_length(files)>100);
end $$;
revoke all on function taskfold_private.account_removal_repair_manifest(uuid) from public,anon,authenticated;
grant execute on function taskfold_private.account_removal_repair_manifest(uuid) to service_role;

create function public.taskfold_account_removal_repair_manifest(_account uuid) returns jsonb
language sql security invoker set search_path='' as $$
 select taskfold_private.account_removal_repair_manifest(_account)
$$;
revoke all on function public.taskfold_account_removal_repair_manifest(uuid) from public,anon,authenticated;
grant execute on function public.taskfold_account_removal_repair_manifest(uuid) to service_role;

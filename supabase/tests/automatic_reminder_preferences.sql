-- Actual client roles, disposable accounts, transactional rollback; no providers.
begin;
do $$ begin
 if exists(select 1 from auth.users where id::text like 'f0722000-%') then raise exception 'Automatic fixture namespace already in use'; end if;
 if has_function_privilege('anon','public.taskfold_set_automatic_reminder(integer)','EXECUTE') then raise exception 'Anonymous automatic RPC grant'; end if;
 if (select prosecdef from pg_proc where oid='public.taskfold_set_automatic_reminder(integer)'::regprocedure) then raise exception 'RPC bypasses owner RLS'; end if;
end $$;
insert into auth.users(id,email) values('f0722000-0000-4000-8000-000000000001','taskfold-automatic@example.invalid'),('f0722000-0000-4000-8000-000000000002','taskfold-automatic-other@example.invalid');
set local request.jwt.claim.sub='f0722000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare invalid jsonb; result jsonb; amount integer; begin
 result:=public.taskfold_set_automatic_reminder(15);
 if result->>'user_id'<>auth.uid()::text or result->>'id'<>'current' or result->'settings'->>'snooze_minutes'<>'60' or result->'settings'->>'automatic_before_minutes'<>'15' then raise exception 'Initial automatic RPC receipt mismatch'; end if;
 update public.reminder_preferences set settings=jsonb_set(settings,'{extension}','{"keep":true}') where id='current';
 perform public.taskfold_set_reminder_snooze(5);
 perform public.taskfold_set_automatic_reminder(30);
 if (select settings from public.reminder_preferences where id='current')<>'{"version":1,"snooze_minutes":5,"automatic_before_minutes":30,"extension":{"keep":true}}'::jsonb then raise exception 'Semantic commands overwrote another preference or metadata'; end if;
 foreach amount in array array[-1,0,1,10080] loop
  perform public.taskfold_set_automatic_reminder(amount);
  if (select (settings->>'automatic_before_minutes')::integer from public.reminder_preferences where id='current')<>amount then raise exception 'Boundary choice mismatch'; end if;
 end loop;
 foreach invalid in array array['null'::jsonb,'true'::jsonb,'"15"'::jsonb,'15.5'::jsonb,'-2'::jsonb,'10081'::jsonb] loop
  begin update public.reminder_preferences set settings=jsonb_set(settings,'{automatic_before_minutes}',invalid) where id='current'; raise exception 'Invalid automatic preference accepted'; exception when check_violation then null; end;
 end loop;
 foreach amount in array array[-2,10081,null::integer] loop
  begin perform public.taskfold_set_automatic_reminder(amount); raise exception 'Invalid RPC choice accepted'; exception when others then if sqlerrm<>'Choose no automatic reminder or an offset from 0 to 10080 minutes.' then raise; end if; end;
 end loop;
 update public.reminder_preferences set settings='{"version":1.00,"snooze_minutes":15.00,"automatic_before_minutes":0.00}' where id='current';
 perform public.taskfold_set_automatic_reminder(15);
 update public.reminder_preferences set settings='{"version":2,"automatic_before_minutes":"opaque","future":{"keep":true}}' where id='current';
 begin perform public.taskfold_set_automatic_reminder(0); raise exception 'Future document downgraded'; exception when others then if sqlerrm<>'This reminder preference needs a newer app.' then raise; end if; end;
end $$;
reset role;
set local request.jwt.claim.sub='f0722000-0000-4000-8000-000000000002';
set local role authenticated;
do $$ begin
 if exists(select 1 from public.reminder_preferences) then raise exception 'Foreign preference readable'; end if;
 perform public.taskfold_set_automatic_reminder(-1);
 if (select count(*) from public.reminder_preferences)<>1 then raise exception 'Account isolation failed'; end if;
 update public.reminder_preferences set settings='{"version":1,"snooze_minutes":5,"automatic_before_minutes":15}' where user_id='f0722000-0000-4000-8000-000000000001';
 delete from public.reminder_preferences where user_id='f0722000-0000-4000-8000-000000000001';
end $$;
reset role;
do $$ begin
 if (select settings->>'version' from public.reminder_preferences where user_id='f0722000-0000-4000-8000-000000000001')<>'2' then raise exception 'Outsider overwrote future preference'; end if;
end $$;
rollback;

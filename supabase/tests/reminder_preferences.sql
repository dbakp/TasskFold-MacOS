-- Disposable owner/outsider accounts, actual client roles; no notification/provider calls.
begin;
do $$ begin
 if exists(select 1 from auth.users where id::text like 'f0721000-%') then raise exception 'Snooze fixture namespace already in use'; end if;
 if has_table_privilege('anon','public.reminder_preferences','SELECT') or has_table_privilege('anon','public.reminder_preferences','INSERT') then raise exception 'Anonymous preference grant'; end if;
 if has_function_privilege('anon','public.taskfold_set_reminder_snooze(integer)','EXECUTE') then raise exception 'Anonymous snooze RPC grant'; end if;
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and tablename='reminder_preferences') then raise exception 'Snooze preferences absent from Realtime'; end if;
end $$;
insert into auth.users(id,email) values('f0721000-0000-4000-8000-000000000001','taskfold-snooze@example.invalid'),('f0721000-0000-4000-8000-000000000002','taskfold-snooze-other@example.invalid');
set local request.jwt.claim.sub='f0721000-0000-4000-8000-000000000001';
set local role authenticated;
do $$ declare invalid jsonb; begin
 insert into public.reminder_preferences(id,settings) values('current','{"version":1,"snooze_minutes":15,"extension":{"keep":true}}');
 if (select settings->>'snooze_minutes' from public.reminder_preferences where id='current')<>'15' then raise exception 'Owner preference not readable'; end if;
 update public.reminder_preferences set settings=jsonb_set(settings,'{snooze_minutes}','30') where id='current';
 if (select settings->'extension' from public.reminder_preferences where id='current')<>'{"keep":true}'::jsonb then raise exception 'Snooze update lost extension'; end if;
 -- Retried composite upsert addresses only this owner's singleton.
 insert into public.reminder_preferences(user_id,id,settings) values(auth.uid(),'current','{"version":1,"snooze_minutes":30,"extension":{"keep":true}}') on conflict(user_id,id) do update set settings=excluded.settings;
 if (select count(*) from public.reminder_preferences)<>1 then raise exception 'Snooze retry duplicated row'; end if;
 perform public.taskfold_set_reminder_snooze(15);
 if (select settings from public.reminder_preferences where id='current')<>'{"version":1,"snooze_minutes":15,"extension":{"keep":true}}'::jsonb then raise exception 'Atomic delay change lost current metadata'; end if;
 begin perform public.taskfold_set_reminder_snooze(null); raise exception 'Null snooze choice accepted'; exception when others then if sqlerrm<>'Choose a snooze delay from 1 to 1440 minutes.' then raise; end if; end;
 foreach invalid in array array['null'::jsonb,'[]'::jsonb,'{}'::jsonb,'{"version":true,"snooze_minutes":15}'::jsonb,'{"version":1,"snooze_minutes":true}'::jsonb,'{"version":1,"snooze_minutes":"15"}'::jsonb,'{"version":1,"snooze_minutes":0}'::jsonb,'{"version":1,"snooze_minutes":1441}'::jsonb,'{"version":1,"snooze_minutes":15.5}'::jsonb,'{"version":1.5,"snooze_minutes":15}'::jsonb,'{"version":0,"snooze_minutes":15}'::jsonb] loop
  begin update public.reminder_preferences set settings=invalid where id='current'; raise exception 'Invalid preference accepted: %',invalid; exception when check_violation then null; end;
 end loop;
 begin update public.reminder_preferences set id='other' where id='current'; raise exception 'Multiple preference identity accepted'; exception when check_violation then null; end;
 begin insert into public.reminder_preferences(user_id,id) values('f0721000-0000-4000-8000-000000000002','current'); raise exception 'Foreign preference inserted'; exception when insufficient_privilege then null; end;
 begin update public.reminder_preferences set user_id='f0721000-0000-4000-8000-000000000002'; raise exception 'Preference transferred'; exception when others then if sqlerrm<>'Organization ownership cannot be changed' and sqlstate<>'42501' then raise; end if; end;
 -- JSON numbers accept integral decimal spellings; the semantic RPC preserves them.
 update public.reminder_preferences set settings='{"version":1.00,"snooze_minutes":30,"extension":{"keep":true}}' where id='current';
 perform public.taskfold_set_reminder_snooze(120);
 if (select settings->>'snooze_minutes' from public.reminder_preferences where id='current')<>'120' then raise exception 'Integral decimal version rejected'; end if;
 if not taskfold_private.valid_reminder_preferences(jsonb_build_object('version',2,'extension',repeat('/',5000))) then raise exception 'Valid 5KB opaque metadata rejected'; end if;
 if taskfold_private.valid_reminder_preferences(jsonb_build_object('version',2,'extension',repeat('a',8192))) then raise exception 'Oversized metadata accepted'; end if;
 -- Future frames remain stored; native editing must remain unavailable.
 update public.reminder_preferences set settings='{"version":2,"future":{"delay":"preserved"}}' where id='current';
 if (select settings->>'version' from public.reminder_preferences where id='current')<>'2' then raise exception 'Future preference was rewritten'; end if;
 begin perform public.taskfold_set_reminder_snooze(60); raise exception 'Old queued delay downgraded future preference'; exception when others then if sqlerrm<>'This reminder preference needs a newer app.' then raise; end if; end;
end $$;
reset role;
set local request.jwt.claim.sub='f0721000-0000-4000-8000-000000000002';
set local role authenticated;
do $$ begin
 if exists(select 1 from public.reminder_preferences) then raise exception 'Foreign preference readable'; end if;
 update public.reminder_preferences set settings='{"version":1,"snooze_minutes":5}' where user_id='f0721000-0000-4000-8000-000000000001';
 delete from public.reminder_preferences where user_id='f0721000-0000-4000-8000-000000000001';
 insert into public.reminder_preferences(id,settings) values('current','{"version":1,"snooze_minutes":5}');
 if (select count(*) from public.reminder_preferences)<>1 then raise exception 'Owner isolation failed'; end if;
end $$;
reset role;
do $$ begin
 if (select settings->>'version' from public.reminder_preferences where user_id='f0721000-0000-4000-8000-000000000001')<>'2' then raise exception 'Outsider overwrote/deleted preference'; end if;
 delete from auth.users where id='f0721000-0000-4000-8000-000000000002';
 if exists(select 1 from public.reminder_preferences where user_id='f0721000-0000-4000-8000-000000000002') then raise exception 'Deleted account retained preference'; end if;
end $$;
rollback;

-- Execute in BEGIN/ROLLBACK after collaboration.sql. Display metadata is never authorization.
update auth.users set raw_user_meta_data='{"full_name":"Google Owner","picture":"https://example.invalid/google.png"}', raw_app_meta_data='{"provider":"google"}' where id='f01dcafe-0000-4000-8000-000000000001';
update public.profiles set display_name='', avatar_url=null where user_id='f01dcafe-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','f01dcafe-0000-4000-8000-000000000001',true);
set local role authenticated;
do $$ declare person record; begin
 select * into person from public.taskfold_project_members('f01dcafe-0000-4000-8000-000000000010') where user_id=auth.uid();
 if person.display_name <> 'Google Owner' or person.avatar_url <> 'https://example.invalid/google.png' then raise exception 'Google identity fallback failed'; end if;
end $$;
update public.profiles set display_name='Custom Owner', avatar_url='https://example.invalid/custom.png' where user_id=auth.uid();
do $$ declare person record; begin
 select * into person from public.taskfold_project_members('f01dcafe-0000-4000-8000-000000000010') where user_id=auth.uid();
 if person.display_name <> 'Custom Owner' or person.avatar_url <> 'https://example.invalid/custom.png' then raise exception 'Custom identity precedence failed'; end if;
end $$;
update public.profiles set avatar_url=null where user_id=auth.uid();
do $$ begin
 if not exists(select 1 from public.taskfold_project_members('f01dcafe-0000-4000-8000-000000000010') where avatar_url='https://example.invalid/google.png') then raise exception 'Photo removal did not restore Google fallback'; end if;
end $$;
reset role;

begin;
insert into auth.users(id,email) values
 ('f1721000-0000-4000-8000-000000000001','template-review-owner@example.invalid'),
 ('f1721000-0000-4000-8000-000000000002','template-review-outsider@example.invalid');
set local role authenticated;
select set_config('request.jwt.claim.sub','f1721000-0000-4000-8000-000000000001',true);
insert into public.project_templates(id,name,document) values ('f1722000-0000-4000-8000-000000000001','Original','{"version":1}');
do $$ declare base jsonb; saved jsonb; begin
 select to_jsonb(t) into base from public.project_templates t where id='f1722000-0000-4000-8000-000000000001';
 saved=public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{"name":"Remote rename"}');
 saved=public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{"document":{"version":1,"test":"local definition"}}');
 if saved->>'name'<>'Remote rename' or saved->'document'->>'test'<>'local definition' then raise exception 'Independent name/definition merge failed';end if;
 -- A repeated acknowledgement is idempotent.
 perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{"document":{"version":1,"test":"local definition"}}');
 begin
  perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{"document":{"version":1,"test":"overlap"}}');raise exception 'Overlap was not refused';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise;end if;end;
 begin
  perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{}',true);raise exception 'Stale deletion was not refused';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise;end if;end;
 begin
  perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',saved,'{"user_id":"f1721000-0000-4000-8000-000000000002"}');raise exception 'Ownership change allowed';
 exception when raise_exception then if sqlerrm='Ownership change allowed' then raise;end if;end;
 saved=public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',saved,'{"name":"Reviewed rename"}');
 if saved->>'name'<>'Reviewed rename' then raise exception 'Reviewed retry failed';end if;
end $$;
select set_config('request.jwt.claim.sub','f1721000-0000-4000-8000-000000000002',true);
do $$ begin
 if exists(select 1 from public.project_templates where id='f1722000-0000-4000-8000-000000000001') then raise exception 'Outsider read';end if;
 begin
  perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001','{}','{"name":"Intruder"}');raise exception 'Outsider write';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise;end if;end;
end $$;
select set_config('request.jwt.claim.sub','f1721000-0000-4000-8000-000000000001',true);
do $$ declare base jsonb;begin
 select to_jsonb(t) into base from public.project_templates t where id='f1722000-0000-4000-8000-000000000001';
 perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{}',true);
 perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{}',true);
 begin
  perform public.taskfold_edit_template('f1722000-0000-4000-8000-000000000001',base,'{"name":"Resurrect"}');raise exception 'Deleted template resurrected';
 exception when raise_exception then if sqlerrm not like 'TASKFOLD_CONFLICT:%' then raise;end if;end;
end $$;
reset role;
select not has_function_privilege('anon','public.taskfold_edit_template(uuid,jsonb,jsonb,boolean)','execute') as anonymous_denied,
 not (select prosecdef from pg_proc where oid='public.taskfold_edit_template(uuid,jsonb,jsonb,boolean)'::regprocedure) as security_invoker;
rollback;
